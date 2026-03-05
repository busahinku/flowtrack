import Foundation
import SwiftUI
import OSLog

private let appStateLogger = Logger(subsystem: "com.flowtrack", category: "AppState")

@MainActor @Observable
final class AppState {
    static let shared = AppState()

    var timeSlots: [TimeSlot] = []
    var categoryStats: [CategoryStat] = []
    var selectedDate: Date = Date()
    var isRunningAI = false
    var aiNextRunTime: Date?
    var sessionTitles: [String: String] = [:]
    var sessionSummaries: [String: String] = [:]
    /// Consecutive productive days (≥50% focus) ending today
    var streakDays: Int = 0
    /// Today's app switch count (context-switching metric)
    var todaySwitchCount: Int { ActivityTracker.shared.todaySwitchCount }
    /// True when user has been in a productive app for >20 min continuously
    var isInDeepWork: Bool = false

    private var aiTimer: Timer?
    private var refreshTimer: Timer?
    let settings = AppSettings.shared

    // AI category cache: bundleID → category (prevents same app getting different categories)
    // Capped at 500 entries to bound memory usage
    private var aiCategoryCache: [String: Category] = [:]

    // Session rebuild cache — skip expensive rebuild when nothing changed
    private var cachedSessionDate: Date?
    private var cachedActivityCount: Int = -1

    private init() {
        loadPersistedAIData()
        startTimers()
        Task {
            await reCategorizeWithRules()
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
    }

    func refreshData(force: Bool = false) async {
        do {
            let count = try Database.shared.activityCount(for: selectedDate)
            let dateChanged = cachedSessionDate.map {
                !Calendar.current.isDate($0, inSameDayAs: selectedDate)
            } ?? true

            guard force || count != cachedActivityCount || dateChanged else { return }

            timeSlots = try Database.shared.sessionsForDate(selectedDate)
            categoryStats = try Database.shared.categoryStatsForDate(selectedDate)
            cachedActivityCount = count
            cachedSessionDate = selectedDate

            // Detect deep work sessions
            updateDeepWorkState()

            // Refresh streak (cheap query, run async)
            Task(priority: .background) {
                if let days = try? Database.shared.focusStreakDays() {
                    await MainActor.run { self.streakDays = days }
                }
            }

            // Memory caps: keep only last 200 entries in AI caches
            enforceAICacheLimit()
        } catch {
            appStateLogger.error("Refresh error: \(error.localizedDescription)")
        }
    }

    private func enforceAICacheLimit() {
        let limit = 200
        if sessionTitles.count > limit {
            let keys = Array(sessionTitles.keys.prefix(sessionTitles.count - limit))
            keys.forEach { sessionTitles.removeValue(forKey: $0) }
        }
        if sessionSummaries.count > limit {
            let keys = Array(sessionSummaries.keys.prefix(sessionSummaries.count - limit))
            keys.forEach { sessionSummaries.removeValue(forKey: $0) }
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
                appStateLogger.info("Re-categorized \(updates.count) activities with rules")
            }
        } catch {
            appStateLogger.error("Re-categorize error: \(error.localizedDescription)")
        }
    }

    // MARK: - AI Processing

    /// Manual AI run — processes ALL unprocessed sessions
    func runAINow() async {
        guard !isRunningAI else { return }
        isRunningAI = true
        defer { isRunningAI = false }

        // First try rules (fast, free)
        await reCategorizeWithRules()
        // Then AI for the rest
        await categorizeBatch(limit: 500)
        await generateAllSessionContent(maxTitles: 50, maxSummaries: 20)
        await refreshData(force: true)
    }

    /// Timer-based AI batch — smaller limits
    func runAIBatch() async {
        guard !isRunningAI else { return }
        isRunningAI = true
        defer { isRunningAI = false }

        await reCategorizeWithRules()
        await categorizeBatch(limit: settings.aiBatchSize)
        await generateAllSessionContent(maxTitles: 8, maxSummaries: 5)
        await refreshData(force: true)
    }

    func generateAllSessionContent(maxTitles: Int = 50, maxSummaries: Int = 20) async {
        let slotsWithoutTitles = Array(timeSlots.filter { !$0.isIdle && sessionTitles[$0.id] == nil }.prefix(maxTitles))
        let slotsWithoutSummaries = Array(timeSlots.filter { !$0.isIdle && sessionSummaries[$0.id] == nil && settings.aiSummariesEnabled }.prefix(maxSummaries))

        // Parallel title generation
        await withTaskGroup(of: (String, String)?.self) { group in
            for slot in slotsWithoutTitles {
                group.addTask {
                    do {
                        let title = try await self.withFallback { provider in
                            try await provider.generateTitle(activities: slot.activities, category: slot.category)
                        }
                        return (slot.id, title)
                    } catch {
                        appStateLogger.error("Title generation failed for \(slot.id): \(error.localizedDescription)")
                        return nil
                    }
                }
            }
            for await result in group {
                if let (id, title) = result {
                    sessionTitles[id] = title
                    try? Database.shared.saveSessionAI(sessionId: id, title: title, summary: sessionSummaries[id])
                }
            }
        }

        // Parallel summary generation
        await withTaskGroup(of: (String, String)?.self) { group in
            for slot in slotsWithoutSummaries {
                group.addTask {
                    do {
                        let summary = try await self.withFallback { provider in
                            try await provider.summarize(activities: slot.activities)
                        }
                        return (slot.id, summary)
                    } catch {
                        appStateLogger.error("Summary generation failed for \(slot.id): \(error.localizedDescription)")
                        return nil
                    }
                }
            }
            for await result in group {
                if let (id, summary) = result {
                    sessionSummaries[id] = summary
                    try? Database.shared.saveSessionAI(sessionId: id, title: sessionTitles[id], summary: summary)
                }
            }
        }
    }

    private func categorizeBatch(limit: Int) async {
        do {
            let uncategorized = try Database.shared.uncategorizedActivities(limit: limit)
            guard !uncategorized.isEmpty else { return }

            var allUpdates: [(id: Int64, category: Category)] = []

            // First: apply cached AI categories (instant, no API calls)
            var needsAI: [ActivityRecord] = []
            for record in uncategorized {
                guard let id = record.id else { continue }
                if let cached = aiCategoryCache[record.bundleID.lowercased()] {
                    allUpdates.append((id: id, category: cached))
                } else {
                    needsAI.append(record)
                }
            }

            // Then: batch AI categorize the rest
            let batchSize = 10
            for batchStart in stride(from: 0, to: needsAI.count, by: batchSize) {
                let end = min(batchStart + batchSize, needsAI.count)
                let batchRecords = Array(needsAI[batchStart..<end])

                let items = batchRecords.enumerated().map { (idx, record) in
                    BatchCategorizeItem(
                        index: idx,
                        appName: record.appName,
                        bundleID: record.bundleID,
                        windowTitle: record.windowTitle,
                        url: record.url
                    )
                }

                do {
                    let results = try await withFallback { provider in
                        try await provider.categorizeBatch(items: items)
                    }

                    for (idx, record) in batchRecords.enumerated() {
                        guard let id = record.id else { continue }
                        if let category = results[idx] {
                            allUpdates.append((id: id, category: category))
                            // Cache and learn
                            learnCategory(category, for: record)
                        }
                    }
                } catch {
                    appStateLogger.warning("Batch categorization failed, falling back to individual: \(error.localizedDescription)")
                    for record in batchRecords {
                        guard let id = record.id else { continue }
                        do {
                            let category = try await withFallback { provider in
                                try await provider.categorize(
                                    appName: record.appName,
                                    bundleID: record.bundleID,
                                    windowTitle: record.windowTitle,
                                    url: record.url
                                )
                            }
                            allUpdates.append((id: id, category: category))
                            learnCategory(category, for: record)
                        } catch {
                            appStateLogger.warning("Individual categorization failed for \(record.appName): \(error.localizedDescription)")
                        }
                    }
                }
            }

            if !allUpdates.isEmpty {
                try Database.shared.updateCategoriesBatch(allUpdates)
                appStateLogger.info("Categorized \(allUpdates.count) activities")
            }
        } catch {
            appStateLogger.error("Batch error: \(error.localizedDescription)")
        }
    }

    /// Cache AI result and teach the rule engine
    private func learnCategory(_ category: Category, for record: ActivityRecord) {
        guard category != .uncategorized, category != .idle else { return }
        let bid = record.bundleID.lowercased()
        // Only cache for non-browser apps (browsers should be categorized per URL)
        let browserBIDs = ["safari", "chrome", "firefox", "arc", "brave", "edge", "opera", "vivaldi", "browser"]
        let isBrowser = browserBIDs.contains(where: { bid.contains($0) })
        if !isBrowser {
            // Evict cache if it grows too large
            if aiCategoryCache.count >= 500 { aiCategoryCache.removeAll() }
            aiCategoryCache[bid] = category
            RuleEngine.shared.learnFromAI(appName: record.appName, bundleID: record.bundleID, category: category)
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
                    appStateLogger.debug("Skipping \(providerType.rawValue, privacy: .public): no API key")
                    continue
                }
            }

            let provider = AIProviderFactory.create(for: providerType)
            for attempt in 1...2 {
                do {
                    return try await operation(provider)
                } catch {
                    appStateLogger.warning("\(providerType.rawValue) attempt \(attempt) failed: \(error.localizedDescription)")
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
        if let title = sessionTitles[slot.id] { return title }
        // Better fallback: show category + top app
        if let topApp = slot.activities.first {
            if slot.activities.count > 1 {
                return "\(topApp.appName) + \(slot.activities.count - 1) more"
            }
            return topApp.appName
        }
        return slot.category.rawValue
    }

    // MARK: - Persistence

    private func loadPersistedAIData() {
        do {
            let data = try Database.shared.loadAllSessionAI()
            for item in data {
                if let title = item.title { sessionTitles[item.sessionId] = title }
                if let summary = item.summary { sessionSummaries[item.sessionId] = summary }
            }
        } catch {
            appStateLogger.error("Failed to load persisted AI data: \(error.localizedDescription)")
        }
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
                appStateLogger.info("Deep work session detected")
            }
        }
    }
}
