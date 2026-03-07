import Foundation
import SwiftUI
import OSLog


@MainActor @Observable
final class AppState {
    static let shared = AppState()

    nonisolated private let log = Logger(subsystem: "com.flowtrack", category: "AppState")

    var timeSlots: [TimeSlot] = []
    var categoryStats: [CategoryStat] = []
    var selectedDate: Date = Date()
    var isRunningAI = false
    var aiNextRunTime: Date?
    /// Consecutive productive days (≥50% focus) ending today
    var streakDays: Int = 0
    /// Today's app switch count (context-switching metric)
    var todaySwitchCount: Int { ActivityTracker.shared.todaySwitchCount }
    /// True when user has been in a productive app for >20 min continuously
    var isInDeepWork: Bool = false
    /// Set to navigate the main window to a specific tab; cleared after consumption
    var requestedTab: DashboardTab? = nil

    private var aiTimer: Timer?
    private var refreshTimer: Timer?
    let settings = AppSettings.shared

    // Session rebuild cache — skip expensive rebuild when nothing changed
    private var cachedSessionDate: Date?
    private var cachedActivityCount: Int = -1

    // Streak cache — only recompute when the date changes
    private var cachedStreakDate: Date?
    private var cachedStreakValue: Int = 0

    private init() {
        startTimers()
        Task {
            await reCategorizeWithRules()
            await reCategorizePoisonedBrowserActivities()
            await refreshData()
            Database.shared.pruneOldActivitiesIfScheduled()
        }
    }

    private func startTimers() {
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.refreshData()
            }
        }
        refreshTimer?.tolerance = 12
        resetAITimer()
    }

    func resetAITimer() {
        aiTimer?.invalidate()
        let interval = TimeInterval(settings.aiBatchIntervalMinutes * 60)
        aiNextRunTime = Date().addingTimeInterval(interval)
        aiTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.runAIBatch()
                self?.aiNextRunTime = Date().addingTimeInterval(interval)
            }
        }
        aiTimer?.tolerance = max(30, interval * 0.05)
    }

    func refreshData(force: Bool = false) async {
        do {
            let count = try Database.shared.activityCount(for: selectedDate)
            let dateChanged = cachedSessionDate.map {
                !Calendar.current.isDate($0, inSameDayAs: selectedDate)
            } ?? true

            guard force || count != cachedActivityCount || dateChanged else { return }

            // Run heavy DB reads on a background thread to avoid blocking the main actor.
            let date = selectedDate
            let (slots, stats) = try await Task(priority: .userInitiated) {
                let s = try Database.shared.timelineSlotsForDate(date)
                let c = try Database.shared.categoryStatsForDate(date)
                return (s, c)
            }.value

            timeSlots = slots
            categoryStats = stats
            cachedActivityCount = count
            cachedSessionDate = selectedDate

            // Detect deep work sessions
            updateDeepWorkState()

            // Refresh streak — only recompute when the calendar day changes
            let today = Calendar.current.startOfDay(for: Date())
            if cachedStreakDate != today {
                Task(priority: .background) {
                    if let days = try? Database.shared.focusStreakDays() {
                        await MainActor.run {
                            self.streakDays = days
                            self.cachedStreakDate = today
                            self.cachedStreakValue = days
                            AchievementEngine.shared.checkStreakAchievements(streak: days)
                        }
                    }
                }
            } else {
                streakDays = cachedStreakValue
            }
        } catch {
            log.error("Refresh error: \(error.localizedDescription)")
        }
    }

    // MARK: - Re-categorize with Rules

    /// Re-runs the rule engine on all Uncategorized activities.
    /// This catches records that were saved before new rules or learned rules existed.
    func reCategorizeWithRules() async {
        do {
            let uncategorized = try Database.shared.uncategorizedActivities(limit: 5000)
            guard !uncategorized.isEmpty else { return }

            var updates: [(id: Int64, category: Category)] = []
            for record in uncategorized {
                guard let id = record.id else { continue }
                if let cat = RuleEngine.shared.categorize(
                    appName: record.appName,
                    bundleID: record.bundleID,
                    windowTitle: record.windowTitle,
                    url: record.url
                ) {
                    updates.append((id: id, category: cat))
                }
            }

            if !updates.isEmpty {
                try Database.shared.updateCategoriesBatch(updates)
                log.info("Re-categorized \(updates.count) activities with rules")
            }
        } catch {
            log.error("Re-categorize error: \(error.localizedDescription)")
        }
    }

    /// Re-categorize browser activities that have a URL using domain rules.
    /// This fixes historically poisoned records where learned bundleID rules forced Work on all browser activity.
    func reCategorizePoisonedBrowserActivities() async {
        do {
            let browserActivities = try Database.shared.browserActivitiesWithURL(limit: 3000)
            guard !browserActivities.isEmpty else { return }

            var updates: [(id: Int64, category: Category)] = []
            for record in browserActivities {
                guard let id = record.id, let url = record.url else { continue }
                // Only update if domain rules give a confident answer
                if let cat = RuleEngine.shared.categorize(
                    appName: record.appName,
                    bundleID: record.bundleID,
                    windowTitle: record.windowTitle,
                    url: url
                ), cat != Category.uncategorized {
                    if cat != record.category {
                        updates.append((id: id, category: cat))
                    }
                }
            }

            if !updates.isEmpty {
                try Database.shared.updateCategoriesBatch(updates)
                log.info("Fixed \(updates.count) previously mis-categorized browser activities")
            }
        } catch {
            log.error("Browser re-categorize error: \(error.localizedDescription)")
        }
    }

    // MARK: - AI Processing

    /// Manual AI run — processes ALL unprocessed windows for the selected day,
    /// including the current in-progress window up to the current time.
    func runAINow() async {
        guard !isRunningAI else { return }
        isRunningAI = true
        defer { isRunningAI = false }

        // Clear fallback segments (nil titles from previous failed runs) so they get re-analyzed
        if let cleared = try? Database.shared.clearFallbackSegments(for: selectedDate), cleared > 0 {
            log.info("Cleared \(cleared) fallback windows for re-analysis")
        }

        await reCategorizeWithRules()
        await analyzeUnprocessedWindows(limit: 200)
        await analyzeCurrentWindowNow()
        await refreshData(force: true)
    }

    /// Analyze the currently in-progress 30-min window up to now.
    /// Called only on manual "Run AI" so the user always gets a card for their ongoing work.
    private func analyzeCurrentWindowNow() async {
        let now = Date()
        let windowId = Database.windowId(for: now)
        guard let bounds = Database.windowBounds(for: windowId) else { return }

        do {
            let activities = try Database.shared.activitiesForWindow(windowId: windowId)
            let nonIdle = activities.filter { !$0.isIdle }
            guard nonIdle.count >= 2 else { return }

            let results = try await withFallback { provider in
                try await provider.analyzeActivityWindow(
                    activities: nonIdle,
                    windowStart: bounds.start,
                    windowEnd: now   // partial window — up to current time
                )
            }

            let encoder = JSONEncoder()
            let segments = results.enumerated().map { idx, result -> WindowSegment in
                let appsJSON = (try? String(data: encoder.encode(result.apps), encoding: .utf8)) ?? "[]"
                return WindowSegment(
                    id: "\(windowId)-\(idx)",
                    windowId: windowId,
                    segmentStart: result.segmentStart,
                    segmentEnd: result.segmentEnd,
                    category: result.category,
                    title: result.title,
                    summary: result.summary,
                    isIdle: result.isIdle,
                    apps: appsJSON,
                    processedAt: Date()
                )
            }
            try Database.shared.saveWindowSegments(segments, windowId: windowId)
            log.info("Saved \(segments.count) segments for current window \(windowId)")
        } catch {
            log.error("Current window analysis failed: \(error.localizedDescription)")
        }
    }

    /// Timer-based AI batch — processes recent unprocessed windows
    func runAIBatch() async {
        guard !isRunningAI else { return }
        isRunningAI = true
        defer { isRunningAI = false }

        await reCategorizeWithRules()
        await analyzeUnprocessedWindows(limit: 16)
        await refreshData(force: true)
    }

    /// Core window analysis: find completed 30-min windows without segments, analyze via AI
    private func analyzeUnprocessedWindows(limit: Int) async {
        let analysisDate = selectedDate  // capture once — user may navigate while batch runs
        do {
            let windowIds = try Database.shared.unprocessedWindowIds(for: analysisDate, limit: limit)
            guard !windowIds.isEmpty else { return }

            log.info("Analyzing \(windowIds.count) unprocessed windows")

            for windowId in windowIds {
                let activities = try Database.shared.activitiesForWindow(windowId: windowId)
                let nonIdle = activities.filter { !$0.isIdle }
                guard !nonIdle.isEmpty else { continue }

                guard let bounds = Database.windowBounds(for: windowId) else { continue }

                do {
                    let results = try await withFallback { provider in
                        try await provider.analyzeActivityWindow(
                            activities: nonIdle,
                            windowStart: bounds.start,
                            windowEnd: bounds.end
                        )
                    }

                    // Convert WindowSegmentResult → WindowSegment for storage
                    let encoder = JSONEncoder()
                    let segments = results.enumerated().map { idx, result -> WindowSegment in
                        let appsJSON = (try? String(data: encoder.encode(result.apps), encoding: .utf8)) ?? "[]"
                        return WindowSegment(
                            id: "\(windowId)-\(idx)",
                            windowId: windowId,
                            segmentStart: result.segmentStart,
                            segmentEnd: result.segmentEnd,
                            category: result.category,
                            title: result.title,
                            summary: result.summary,
                            isIdle: result.isIdle,
                            apps: appsJSON,
                            processedAt: Date()
                        )
                    }

                    try Database.shared.saveWindowSegments(segments, windowId: windowId)
                    log.info("Saved \(segments.count) segments for window \(windowId)")
                } catch {
                    log.error("Window analysis failed for \(windowId): \(error.localizedDescription)")
                    // On AI failure, create a fallback segment with rule-engine dominant category
                    let fallbackResults = AIPromptBuilder.fallbackSegment(
                        windowStart: bounds.start, windowEnd: bounds.end, activities: nonIdle
                    )
                    let encoder = JSONEncoder()
                    let segments = fallbackResults.enumerated().map { idx, result -> WindowSegment in
                        let appsJSON = (try? String(data: encoder.encode(result.apps), encoding: .utf8)) ?? "[]"
                        return WindowSegment(
                            id: "\(windowId)-\(idx)",
                            windowId: windowId,
                            segmentStart: result.segmentStart,
                            segmentEnd: result.segmentEnd,
                            category: result.category,
                            title: nil,
                            summary: nil,
                            isIdle: result.isIdle,
                            apps: appsJSON,
                            processedAt: Date()
                        )
                    }
                    try? Database.shared.saveWindowSegments(segments, windowId: windowId)
                }
            }
        } catch {
            log.error("Window analysis error: \(error.localizedDescription)")
        }
    }

    // MARK: - AI Fallback Chain

    func withFallback<T>(_ operation: (any AIProvider) async throws -> T) async throws -> T {
        let chain = providerChain()
        guard !chain.isEmpty else {
            throw AIError.invalidResponse("No AI providers configured")
        }
        var lastError: Error?

        for providerType in chain {
            // Skip providers that need API keys but don't have them
            if providerType.needsAPIKey {
                let key = SecureStore.shared.loadKey(for: providerType.rawValue)
                if key == nil || key?.isEmpty == true {
                    log.debug("Skipping \(providerType.rawValue, privacy: .public): no API key")
                    continue
                }
            }

            let provider = AIProviderFactory.create(for: providerType)
            for attempt in 1...2 {
                do {
                    return try await operation(provider)
                } catch {
                    log.warning("\(providerType.rawValue) attempt \(attempt) failed: \(error.localizedDescription)")
                    lastError = error
                    // Don't retry on noAPIKey or cliNotFound
                    if case AIError.noAPIKey = error { break }
                    if case AIError.cliNotFound = error { break }
                }
            }
        }
        throw lastError ?? AIError.invalidResponse("All providers failed")
    }

    private func providerChain() -> [AIProviderType] {
        var chain: [AIProviderType] = [settings.aiProvider]
        if let secondary = settings.secondaryProvider, secondary != settings.aiProvider {
            chain.append(secondary)
        }
        if let tertiary = settings.tertiaryProvider,
           tertiary != settings.aiProvider,
           tertiary != settings.secondaryProvider {
            chain.append(tertiary)
        }
        return chain
    }

    // MARK: - Session Helpers

    func sessionTitle(for slot: TimeSlot) -> String {
        if let title = slot.title { return title }
        // Fallback: show category + top app
        if let topApp = slot.activities.first {
            if slot.activities.count > 1 {
                return "\(topApp.appName) + \(slot.activities.count - 1) more"
            }
            return topApp.appName
        }
        return slot.category.rawValue
    }

    // MARK: - Deep Work Detection

    /// Updates isInDeepWork based on today's session data.
    /// A "deep work" session is a single productive TimeSlot lasting ≥20 min.
    private func updateDeepWorkState() {
        let deepWorkThreshold: TimeInterval = 20 * 60
        let hasDeepWork = timeSlots.contains {
            !$0.isIdle && $0.category.isProductive && $0.duration >= deepWorkThreshold
        }
        if hasDeepWork != isInDeepWork {
            isInDeepWork = hasDeepWork
            if hasDeepWork {
                log.info("Deep work session detected")
            }
        }
    }
}
