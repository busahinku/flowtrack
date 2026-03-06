import Foundation
import GRDB
import OSLog

private let dbLogger = Logger(subsystem: "com.flowtrack", category: "Database")

final class Database: Sendable {
    static let shared: Database = {
        do {
            return try Database()
        } catch {
            fatalError("FlowTrack: Database init failed — \(error.localizedDescription)\nCheck ~/Library/Application Support/FlowTrack/")
        }
    }()

    let dbQueue: DatabaseQueue

    private init() throws {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let folder = appSupport.appendingPathComponent("FlowTrack")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let dbPath = folder.appendingPathComponent("flowtrack.sqlite").path
        var config = Configuration()
        config.foreignKeysEnabled = true
        dbQueue = try DatabaseQueue(path: dbPath, configuration: config)
        try migrate()
    }

    private func migrate() throws {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1_create_activities") { db in
            try db.create(table: "activities", ifNotExists: true) { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("timestamp", .datetime).notNull()
                t.column("appName", .text).notNull()
                t.column("bundleID", .text).notNull().defaults(to: "")
                t.column("windowTitle", .text).notNull().defaults(to: "")
                t.column("url", .text)
                t.column("category", .text).notNull().defaults(to: "Uncategorized")
                t.column("isIdle", .boolean).notNull().defaults(to: false)
                t.column("duration", .double).notNull().defaults(to: 0)
            }
        }

        migrator.registerMigration("v2_session_ai") { db in
            try db.create(table: "session_ai", ifNotExists: true) { t in
                t.column("sessionId", .text).primaryKey()
                t.column("title", .text)
                t.column("summary", .text)
                t.column("updatedAt", .datetime).notNull()
            }
        }

        migrator.registerMigration("v3_indexes") { db in
            try db.create(index: "activities_timestamp_idx", on: "activities", columns: ["timestamp"])
            try db.create(index: "activities_category_idx", on: "activities", columns: ["category"])
            try db.create(index: "activities_bundleid_idx", on: "activities", columns: ["bundleID"])
        }

        migrator.registerMigration("v4_merge_productivity_into_work") { db in
            try db.execute(sql: "UPDATE activities SET category = 'Work' WHERE category = 'Productivity'")
        }

        migrator.registerMigration("v5_journal_entries") { db in
            try db.create(table: "journal_entries", ifNotExists: true) { t in
                t.column("date", .text).primaryKey()   // "YYYY-MM-DD"
                t.column("ciphertext", .blob).notNull()
                t.column("nonce", .blob).notNull()
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
            }
        }

        try migrator.migrate(dbQueue)
    }

    // MARK: - Save Activity
    func saveActivity(_ record: ActivityRecord) throws {
        try dbQueue.write { db in
            _ = try record.inserted(db)
        }
    }

    // MARK: - Activity Count (cheap check for cache invalidation)
    func activityCount(for date: Date) throws -> Int {
        let (start, end) = dayBounds(for: date)
        return try dbQueue.read { db in
            try ActivityRecord
                .filter(ActivityRecord.Columns.timestamp >= start && ActivityRecord.Columns.timestamp < end)
                .fetchCount(db)
        }
    }

    // MARK: - Day Bounds
    func dayBounds(for date: Date) -> (start: Date, end: Date) {
        let cal = Calendar.current
        let start = cal.startOfDay(for: date)
        let end = cal.date(byAdding: .day, value: 1, to: start)!
        return (start, end)
    }

    // MARK: - Activities for Date
    func activitiesForDate(_ date: Date) throws -> [ActivityRecord] {
        let (start, end) = dayBounds(for: date)
        return try dbQueue.read { db in
            try ActivityRecord
                .filter(ActivityRecord.Columns.timestamp >= start && ActivityRecord.Columns.timestamp < end)
                .filter(ActivityRecord.Columns.isIdle == false)
                .order(ActivityRecord.Columns.timestamp)
                .fetchAll(db)
        }
    }

    // MARK: - Activities for Range
    func activitiesForRange(from: Date, to: Date) throws -> [ActivityRecord] {
        return try dbQueue.read { db in
            try ActivityRecord
                .filter(ActivityRecord.Columns.timestamp >= from && ActivityRecord.Columns.timestamp < to)
                .filter(ActivityRecord.Columns.isIdle == false)
                .order(ActivityRecord.Columns.timestamp)
                .fetchAll(db)
        }
    }

    // MARK: - Session Building (shared logic)
    // Three-phase pipeline:
    //   1. Split on idle gaps (> gapThreshold) into raw chunks
    //   2. Within each chunk, split on sustained category changes (>= minCategoryDuration)
    //      — quick app switches (< 60s) are absorbed into the surrounding session
    //   3. Merge adjacent same-category sessions back together
    private func buildSessions(from activities: [ActivityRecord], gapThreshold: TimeInterval = 300) -> [TimeSlot] {
        guard !activities.isEmpty else { return [] }
        let minCategoryDuration: TimeInterval = 60 // seconds

        // Phase 1: Group activities by idle gaps
        var gapGroups: [[ActivityRecord]] = []
        var currentGroup: [ActivityRecord] = [activities[0]]

        for i in 1..<activities.count {
            let prevEnd = activities[i - 1].timestamp.addingTimeInterval(activities[i - 1].duration)
            let gap = activities[i].timestamp.timeIntervalSince(prevEnd)
            if gap > gapThreshold {
                gapGroups.append(currentGroup)
                currentGroup = [activities[i]]
            } else {
                currentGroup.append(activities[i])
            }
        }
        gapGroups.append(currentGroup)

        // Phase 2: Within each gap group, split on sustained category changes
        var sessions: [TimeSlot] = []
        for group in gapGroups {
            sessions.append(contentsOf: splitOnSustainedCategory(group, minDuration: minCategoryDuration))
        }

        // Phase 3: Merge adjacent same-category sessions
        return mergeAdjacentSameCategory(sessions)
    }

    /// Splits a group of activities into sessions based on sustained category runs.
    /// Runs shorter than `minDuration` are absorbed into the previous session.
    private func splitOnSustainedCategory(_ activities: [ActivityRecord], minDuration: TimeInterval) -> [TimeSlot] {
        guard !activities.isEmpty else { return [] }

        // Build consecutive runs of the same category
        var runs: [(category: Category, activities: [ActivityRecord], duration: TimeInterval)] = []
        var curCat = activities[0].category
        var curActs: [ActivityRecord] = [activities[0]]
        var curDur: TimeInterval = activities[0].duration

        for i in 1..<activities.count {
            let a = activities[i]
            if a.category == curCat {
                curActs.append(a)
                curDur += a.duration
            } else {
                runs.append((curCat, curActs, curDur))
                curCat = a.category
                curActs = [a]
                curDur = a.duration
            }
        }
        runs.append((curCat, curActs, curDur))

        // Merge short runs (< minDuration) into the previous run
        var merged: [(category: Category, activities: [ActivityRecord], duration: TimeInterval)] = []
        for run in runs {
            if run.duration < minDuration && !merged.isEmpty {
                // Absorb into previous — keeps previous category (dominant recalculated later)
                merged[merged.count - 1].activities += run.activities
                merged[merged.count - 1].duration += run.duration
            } else {
                merged.append(run)
            }
        }

        // Convert each merged run into a TimeSlot
        return merged.map { run in
            let start = run.activities.first!.timestamp
            let last = run.activities.last!
            let end = last.timestamp.addingTimeInterval(last.duration)
            let category = dominantCategory(in: run.activities)
            let summaries = buildSummaries(from: run.activities)
            return TimeSlot(
                id: "\(Int(start.timeIntervalSince1970))-\(Int(end.timeIntervalSince1970))",
                startTime: start,
                endTime: end,
                category: category,
                activities: summaries,
                isIdle: false
            )
        }
    }

    /// Returns the category with the highest total activity duration in a set of records.
    private func dominantCategory(in activities: [ActivityRecord]) -> Category {
        var totals: [String: TimeInterval] = [:]
        for a in activities {
            totals[a.category.rawValue, default: 0] += a.duration
        }
        let best = totals.max { $0.value < $1.value }
        return Category(rawValue: best?.key ?? Category.work.rawValue)
    }

    /// Combines consecutive TimeSlots that share the same category into one.
    private func mergeAdjacentSameCategory(_ slots: [TimeSlot]) -> [TimeSlot] {
        guard !slots.isEmpty else { return [] }
        var merged: [TimeSlot] = []
        var current = slots[0]

        for i in 1..<slots.count {
            let next = slots[i]
            if next.category == current.category && next.isIdle == current.isIdle {
                // Combine: extend end time, merge activities — O(n) with index dictionary
                var indexByName: [String: Int] = Dictionary(
                    uniqueKeysWithValues: current.activities.enumerated().map { ($0.element.appName, $0.offset) }
                )
                var allActivities = current.activities
                for a in next.activities {
                    if let idx = indexByName[a.appName] {
                        // Merge duration
                        allActivities[idx] = ActivitySummary(
                            appName: a.appName, bundleID: a.bundleID,
                            title: allActivities[idx].title, url: allActivities[idx].url ?? a.url,
                            duration: allActivities[idx].duration + a.duration,
                            timestamps: allActivities[idx].timestamps + a.timestamps
                        )
                    } else {
                        indexByName[a.appName] = allActivities.count
                        allActivities.append(a)
                    }
                }
                current = TimeSlot(
                    id: "\(Int(current.startTime.timeIntervalSince1970))-\(Int(next.endTime.timeIntervalSince1970))",
                    startTime: current.startTime,
                    endTime: next.endTime,
                    category: current.category,
                    activities: allActivities,
                    isIdle: current.isIdle
                )
            } else {
                merged.append(current)
                current = next
            }
        }
        merged.append(current)
        return merged
    }

    // MARK: - Sessions for Date
    func sessionsForDate(_ date: Date, gapThreshold: TimeInterval = 300) throws -> [TimeSlot] {
        let activities = try activitiesForDate(date)
        return buildSessions(from: activities, gapThreshold: gapThreshold)
    }

    // MARK: - Sessions for Range
    func sessionsForRange(from: Date, to: Date, gapThreshold: TimeInterval = 300) throws -> [TimeSlot] {
        let activities = try activitiesForRange(from: from, to: to)
        return buildSessions(from: activities, gapThreshold: gapThreshold)
    }

    private func buildSummaries(from records: [ActivityRecord]) -> [ActivitySummary] {
        var grouped: [String: (appName: String, bundleID: String, titles: [String], urls: Set<String>, duration: TimeInterval, timestamps: [Date])] = [:]

        for r in records {
            let key = r.appName
            var entry = grouped[key] ?? (appName: r.appName, bundleID: r.bundleID, titles: [], urls: Set(), duration: 0, timestamps: [])
            if !r.windowTitle.isEmpty && !entry.titles.contains(r.windowTitle) {
                entry.titles.append(r.windowTitle)
            }
            if let url = r.url { entry.urls.insert(url) }
            entry.duration += r.duration
            entry.timestamps.append(r.timestamp)
            grouped[key] = entry
        }

        return grouped.values.map { e in
            ActivitySummary(
                appName: e.appName,
                bundleID: e.bundleID,
                title: e.titles.first ?? e.appName,
                url: e.urls.first,
                duration: e.duration,
                timestamps: e.timestamps.sorted()
            )
        }.sorted { $0.duration > $1.duration }
    }

    // MARK: - Category Stats
    func categoryStatsForDate(_ date: Date) throws -> [CategoryStat] {
        let activities = try activitiesForDate(date)
        return computeCategoryStats(from: activities)
    }

    func categoryStatsForRange(from: Date, to: Date) throws -> [CategoryStat] {
        let activities = try activitiesForRange(from: from, to: to)
        return computeCategoryStats(from: activities)
    }

    private func computeCategoryStats(from activities: [ActivityRecord]) -> [CategoryStat] {
        var catDurations: [String: (duration: Double, apps: Set<String>)] = [:]
        var total: Double = 0

        for a in activities where !a.isIdle {
            let key = a.category.rawValue
            var entry = catDurations[key] ?? (duration: 0, apps: Set())
            entry.duration += a.duration
            entry.apps.insert(a.appName)
            catDurations[key] = entry
            total += a.duration
        }

        guard total > 0 else { return [] }

        return catDurations.map { (key, val) in
            CategoryStat(
                category: Category(rawValue: key),
                totalSeconds: val.duration,
                percentage: val.duration / total * 100,
                appCount: val.apps.count
            )
        }.sorted { $0.totalSeconds > $1.totalSeconds }
    }

    // MARK: - Hourly Stats
    func hourlyStatsForDate(_ date: Date) throws -> [HourStat] {
        let activities = try activitiesForDate(date)
        return computeHourlyStats(from: activities)
    }

    func hourlyStatsForRange(from: Date, to: Date) throws -> [HourStat] {
        let activities = try activitiesForRange(from: from, to: to)
        return computeHourlyStats(from: activities)
    }

    private func computeHourlyStats(from activities: [ActivityRecord]) -> [HourStat] {
        var hourCats: [Int: [String: Double]] = [:]
        let cal = Calendar.current

        for a in activities where !a.isIdle {
            let startHour = cal.component(.hour, from: a.timestamp)
            let endTime = a.timestamp.addingTimeInterval(a.duration)
            let endHour = cal.component(.hour, from: endTime)

            if startHour == endHour || a.duration <= 0 {
                // Simple case: all duration in one hour
                var cats = hourCats[startHour] ?? [:]
                cats[a.category.rawValue, default: 0] += a.duration / 60.0
                hourCats[startHour] = cats
            } else {
                // Spans hour boundary: split proportionally
                let nextHourBoundary = cal.date(bySettingHour: startHour + 1, minute: 0, second: 0, of: a.timestamp)
                    ?? a.timestamp.addingTimeInterval(a.duration)
                let firstPortion = nextHourBoundary.timeIntervalSince(a.timestamp)
                let secondPortion = a.duration - firstPortion

                var cats1 = hourCats[startHour] ?? [:]
                cats1[a.category.rawValue, default: 0] += firstPortion / 60.0
                hourCats[startHour] = cats1

                if secondPortion > 0 {
                    var cats2 = hourCats[endHour] ?? [:]
                    cats2[a.category.rawValue, default: 0] += secondPortion / 60.0
                    hourCats[endHour] = cats2
                }
            }
        }

        var stats: [HourStat] = []
        for (hour, cats) in hourCats {
            for (cat, mins) in cats {
                stats.append(HourStat(hour: hour, category: Category(rawValue: cat), minutes: mins))
            }
        }
        return stats
    }

    // MARK: - Heatmap
    func heatmapForWeek(containing date: Date) throws -> [Date: Double] {
        let cal = Calendar.current
        let weekday = cal.component(.weekday, from: date)
        let daysFromMonday = (weekday + 5) % 7  // Sun→6, Mon→0, Tue→1, ..., Sat→5
        let startOfWeek = cal.date(byAdding: .day, value: -daysFromMonday, to: cal.startOfDay(for: date))!
        let endOfWeek = cal.date(byAdding: .day, value: 7, to: startOfWeek)!

        // Single range query instead of 7 separate queries
        let activities = try activitiesForRange(from: startOfWeek, to: endOfWeek)
        var result: [Date: Double] = [:]
        for i in 0..<7 {
            let day = cal.date(byAdding: .day, value: i, to: startOfWeek)!
            result[cal.startOfDay(for: day)] = 0
        }
        for activity in activities where activity.category.isProductive {
            let day = cal.startOfDay(for: activity.timestamp)
            result[day, default: 0] += activity.duration
        }
        return result
    }

    // MARK: - Focus Score
    func focusScore(for date: Date) throws -> Double {
        let activities = try activitiesForDate(date)
        let total = activities.reduce(0) { $0 + $1.duration }
        guard total > 0 else { return 0 }
        let productive = activities.filter { $0.category.isProductive }.reduce(0) { $0 + $1.duration }
        return productive / total * 100
    }

    // MARK: - Uncategorized
    func uncategorizedActivities(limit: Int = 50) throws -> [ActivityRecord] {
        try dbQueue.read { db in
            try ActivityRecord
                .filter(ActivityRecord.Columns.category == Category.uncategorized.rawValue)
                .filter(ActivityRecord.Columns.isIdle == false)
                .order(ActivityRecord.Columns.timestamp.desc)
                .limit(limit)
                .fetchAll(db)
        }
    }

    /// Fetch browser activities (Safari, Chrome, Firefox, Arc, Edge) that have a URL.
    /// These may have been mis-categorized by poisoned learned rules.
    func browserActivitiesWithURL(limit: Int = 3000) throws -> [ActivityRecord] {
        let browserBundleIDs = [
            "com.apple.Safari", "com.google.Chrome", "org.mozilla.firefox",
            "company.thebrowser.Browser", "com.microsoft.edgemac", "com.operasoftware.Opera",
            "com.brave.Browser", "com.vivaldi.Vivaldi", "com.duckduckgo.macos.browser"
        ]
        let placeholders = browserBundleIDs.map { _ in "?" }.joined(separator: ", ")
        return try dbQueue.read { db in
            let sql = """
                SELECT * FROM activities
                WHERE bundleID IN (\(placeholders))
                AND url IS NOT NULL AND url != ''
                AND isIdle = 0
                ORDER BY timestamp DESC
                LIMIT ?
            """
            var args: [DatabaseValue] = browserBundleIDs.map { $0.databaseValue }
            args.append(limit.databaseValue)
            return try ActivityRecord.fetchAll(db, sql: sql, arguments: StatementArguments(args))
        }
    }

    func updateCategory(for id: Int64, to category: Category) throws {
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE activities SET category = ? WHERE id = ?", arguments: [category.rawValue, id])
        }
    }

    func updateCategoriesBatch(_ updates: [(id: Int64, category: Category)]) throws {
        try dbQueue.write { db in
            for update in updates {
                try db.execute(sql: "UPDATE activities SET category = ? WHERE id = ?",
                             arguments: [update.category.rawValue, update.id])
            }
        }
    }

    // MARK: - Session AI Persistence
    func saveSessionAI(sessionId: String, title: String?, summary: String?) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                INSERT OR REPLACE INTO session_ai (sessionId, title, summary, updatedAt)
                VALUES (?, ?, ?, ?)
                """,
                arguments: [sessionId, title, summary, Date()]
            )
        }
    }

    func loadAllSessionAI(limit: Int = 500) throws -> [(sessionId: String, title: String?, summary: String?)] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT sessionId, title, summary FROM session_ai ORDER BY updatedAt DESC LIMIT ?", arguments: [limit])
            return rows.map { row in
                (sessionId: row["sessionId"] as String,
                 title: row["title"] as String?,
                 summary: row["summary"] as String?)
            }
        }
    }

    // MARK: - Category Remapping
    func remapCategory(from oldCategory: String, to newCategory: String) {
        try? dbQueue.write { db in
            try db.execute(sql: "UPDATE activities SET category = ? WHERE category = ?", arguments: [newCategory, oldCategory])
        }
    }

    // MARK: - Data Management
    func clearSessionAI() throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM session_ai")
        }
        try dbQueue.writeWithoutTransaction { db in
            try db.execute(sql: "VACUUM")
        }
    }

    func clearAllData() throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM activities")
            try db.execute(sql: "DELETE FROM session_ai")
        }
        try dbQueue.writeWithoutTransaction { db in
            try db.execute(sql: "VACUUM")
        }
    }

    // MARK: - Auto Cleanup
    /// Deletes data older than `days` when DB exceeds `maxSizeMB`
    func autoCleanupIfNeeded(maxSizeMB: Int = 3072, keepDays: Int = 90) {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dbPath = appSupport.appendingPathComponent("FlowTrack/flowtrack.sqlite").path
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: dbPath),
              let size = attrs[.size] as? Int64 else { return }
        let sizeMB = size / (1024 * 1024)
        guard sizeMB > maxSizeMB else { return }
        let cutoff = Calendar.current.date(byAdding: .day, value: -keepDays, to: Date())!
        try? dbQueue.write { db in
            try db.execute(sql: "DELETE FROM activities WHERE timestamp < ?", arguments: [cutoff])
        }
        try? dbQueue.writeWithoutTransaction { db in
            try db.execute(sql: "VACUUM")
        }
        dbLogger.info("Auto-cleanup: removed data older than \(keepDays) days (DB was \(sizeMB) MB)")
    }

    /// Scheduled data retention — call on startup, runs at most once per week.
    func pruneOldActivitiesIfScheduled() {
        let retentionDays = AppSettings.shared.retentionDays
        guard retentionDays > 0 else { return }
        let lastPruneKey = "lastPruneDate"
        let lastPrune = UserDefaults.standard.object(forKey: lastPruneKey) as? Date ?? .distantPast
        guard Date().timeIntervalSince(lastPrune) > 7 * 86400 else { return } // once per week

        // Use a regular GCD background thread — avoids blocking Swift's cooperative thread pool.
        DispatchQueue.global(qos: .background).async {
            let cutoff = Calendar.current.date(byAdding: .day, value: -retentionDays, to: Date()) ?? Date()
            try? self.dbQueue.write { db in
                try db.execute(sql: "DELETE FROM activities WHERE timestamp < ?", arguments: [cutoff])
                // Prune orphaned AI sessions: keep only those updated after the cutoff
                try db.execute(sql: "DELETE FROM session_ai WHERE updatedAt < ?", arguments: [cutoff])
            }
            UserDefaults.standard.set(Date(), forKey: lastPruneKey)
            dbLogger.info("Scheduled retention: pruned data older than \(retentionDays) days")
        }
    }

    // MARK: - Streak & Weekly Insights

    /// Count of consecutive days (ending today) where productive time >= 50% of active time.
    func focusStreakDays() throws -> Int {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let lookback = cal.date(byAdding: .day, value: -365, to: today)!
        let tomorrow = cal.date(byAdding: .day, value: 1, to: today)!

        // Single query: fetch all non-idle activities in the lookback window
        let activities = try dbQueue.read { db in
            try ActivityRecord
                .filter(ActivityRecord.Columns.timestamp >= lookback && ActivityRecord.Columns.timestamp < tomorrow)
                .filter(ActivityRecord.Columns.isIdle == false)
                .order(ActivityRecord.Columns.timestamp)
                .fetchAll(db)
        }

        // Group by day and compute per-day productive ratio
        var dayTotals: [Date: (total: Double, productive: Double)] = [:]
        for a in activities {
            let day = cal.startOfDay(for: a.timestamp)
            var entry = dayTotals[day] ?? (total: 0, productive: 0)
            entry.total += a.duration
            if a.category.isProductive { entry.productive += a.duration }
            dayTotals[day] = entry
        }

        // Count streak backwards from today
        var streak = 0
        var checkDate = today
        for _ in 0..<365 {
            guard let entry = dayTotals[checkDate], entry.total > 60 else { break }
            guard entry.productive / entry.total >= 0.5 else { break }
            streak += 1
            checkDate = cal.date(byAdding: .day, value: -1, to: checkDate)!
        }
        return streak
    }

    /// App switch count per day (stored as a simple daily metric).
    func appSwitchesForDate(_ date: Date) throws -> Int {
        let start = Calendar.current.startOfDay(for: date)
        let end = Calendar.current.date(byAdding: .day, value: 1, to: start)!
        return try dbQueue.read { db in
            let count = try Int.fetchOne(db, sql: "SELECT COUNT(DISTINCT appName) FROM activities WHERE timestamp >= ? AND timestamp < ? AND isIdle = 0", arguments: [start, end]) ?? 0
            return count
        }
    }
}
