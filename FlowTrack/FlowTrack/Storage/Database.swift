import Foundation
import GRDB

final class Database: Sendable {
    static let shared: Database = {
        try! Database()
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

        try migrator.migrate(dbQueue)
    }

    // MARK: - Save Activity
    func saveActivity(_ record: ActivityRecord) throws {
        try dbQueue.write { db in
            var r = record
            try r.insert(db)
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

    // MARK: - Sessions for Date (dynamic grouping)
    func sessionsForDate(_ date: Date, gapThreshold: TimeInterval = 300) throws -> [TimeSlot] {
        let activities = try activitiesForDate(date)
        guard !activities.isEmpty else { return [] }

        var sessions: [TimeSlot] = []
        var currentActivities: [ActivityRecord] = []
        var currentCategory: Category?
        var sessionStart: Date?

        for record in activities {
            if let cat = currentCategory, let start = sessionStart {
                let gap = record.timestamp.timeIntervalSince(currentActivities.last?.timestamp ?? start)
                if record.category.rawValue != cat.rawValue || gap > gapThreshold {
                    // End current session
                    let endTime = currentActivities.last.map { $0.timestamp.addingTimeInterval($0.duration) } ?? record.timestamp
                    let summaries = buildSummaries(from: currentActivities)
                    let slot = TimeSlot(
                        id: "\(start.timeIntervalSince1970)-\(endTime.timeIntervalSince1970)",
                        startTime: start,
                        endTime: endTime,
                        category: cat,
                        activities: summaries,
                        isIdle: cat == .idle
                    )
                    sessions.append(slot)
                    currentActivities = []
                    sessionStart = record.timestamp
                    currentCategory = record.category
                }
            } else {
                sessionStart = record.timestamp
                currentCategory = record.category
            }
            currentActivities.append(record)
        }

        // Final session
        if let cat = currentCategory, let start = sessionStart, !currentActivities.isEmpty {
            let endTime = currentActivities.last.map { $0.timestamp.addingTimeInterval($0.duration) } ?? start
            let summaries = buildSummaries(from: currentActivities)
            let slot = TimeSlot(
                id: "\(start.timeIntervalSince1970)-\(endTime.timeIntervalSince1970)",
                startTime: start,
                endTime: endTime,
                category: cat,
                activities: summaries,
                isIdle: cat == .idle
            )
            sessions.append(slot)
        }

        return sessions
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
            let hour = cal.component(.hour, from: a.timestamp)
            var cats = hourCats[hour] ?? [:]
            cats[a.category.rawValue, default: 0] += a.duration / 60.0
            hourCats[hour] = cats
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
        let startOfWeek = cal.date(byAdding: .day, value: -(weekday - 1), to: cal.startOfDay(for: date))!
        var result: [Date: Double] = [:]

        for i in 0..<7 {
            let day = cal.date(byAdding: .day, value: i, to: startOfWeek)!
            let activities = try activitiesForDate(day)
            let productive = activities.filter { $0.category.isProductive }
            result[cal.startOfDay(for: day)] = productive.reduce(0) { $0 + $1.duration }
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

    func loadAllSessionAI() throws -> [(sessionId: String, title: String?, summary: String?)] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT sessionId, title, summary FROM session_ai")
            return rows.map { row in
                (sessionId: row["sessionId"] as String,
                 title: row["title"] as String?,
                 summary: row["summary"] as String?)
            }
        }
    }

    // MARK: - Data Management
    func clearSessionAI() throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM session_ai")
        }
    }

    func clearAllData() throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM activities")
            try db.execute(sql: "DELETE FROM session_ai")
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
            try db.execute(sql: "VACUUM")
        }
        print("[Database] Auto-cleanup: removed data older than \(keepDays) days (DB was \(sizeMB) MB)")
    }
}
