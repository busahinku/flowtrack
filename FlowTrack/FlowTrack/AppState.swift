import Foundation
import SwiftUI

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

    private var aiTimer: Timer?
    private var refreshTimer: Timer?
    let settings = AppSettings.shared

    // AI category cache: bundleID → category (prevents same app getting different categories)
    private var aiCategoryCache: [String: Category] = [:]

    private init() {
        loadPersistedAIData()
        startTimers()
        Task {
            await reCategorizeWithRules()
            await refreshData()
        }
    }

    private func startTimers() {
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
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

    func refreshData() async {
        do {
            timeSlots = try Database.shared.sessionsForDate(selectedDate)
            categoryStats = try Database.shared.categoryStatsForDate(selectedDate)
        } catch {
            print("[AppState] Refresh error: \(error)")
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
                print("[AppState] Re-categorized \(updates.count) activities with rules")
            }
        } catch {
            print("[AppState] Re-categorize error: \(error)")
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
        await refreshData()
    }

    /// Timer-based AI batch — smaller limits
    func runAIBatch() async {
        guard !isRunningAI else { return }
        isRunningAI = true
        defer { isRunningAI = false }

        await reCategorizeWithRules()
        await categorizeBatch(limit: settings.aiBatchSize)
        await generateAllSessionContent(maxTitles: 8, maxSummaries: 5)
        await refreshData()
    }

    func generateAllSessionContent(maxTitles: Int = 50, maxSummaries: Int = 20) async {
        let slotsWithoutTitles = timeSlots.filter { !$0.isIdle && sessionTitles[$0.id] == nil }
        let slotsWithoutSummaries = timeSlots.filter { !$0.isIdle && sessionSummaries[$0.id] == nil && settings.aiSummariesEnabled }

        var titleCount = 0
        for slot in slotsWithoutTitles {
            guard titleCount < maxTitles else { break }
            do {
                let title = try await withFallback { provider in
                    try await provider.generateTitle(activities: slot.activities, category: slot.category)
                }
                sessionTitles[slot.id] = title
                try? Database.shared.saveSessionAI(sessionId: slot.id, title: title, summary: sessionSummaries[slot.id])
                titleCount += 1
            } catch {
                print("[AI] Title generation failed for \(slot.id): \(error)")
            }
        }

        var summaryCount = 0
        for slot in slotsWithoutSummaries {
            guard summaryCount < maxSummaries else { break }
            do {
                let summary = try await withFallback { provider in
                    try await provider.summarize(activities: slot.activities)
                }
                sessionSummaries[slot.id] = summary
                try? Database.shared.saveSessionAI(sessionId: slot.id, title: sessionTitles[slot.id], summary: summary)
                summaryCount += 1
            } catch {
                print("[AI] Summary generation failed for \(slot.id): \(error)")
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
                    print("[AI] Batch categorization failed, falling back to individual: \(error)")
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
                            print("[AI] Individual categorization failed for \(record.appName): \(error)")
                        }
                    }
                }
            }

            if !allUpdates.isEmpty {
                try Database.shared.updateCategoriesBatch(allUpdates)
                print("[AI] Categorized \(allUpdates.count) activities")
            }
        } catch {
            print("[AI] Batch error: \(error)")
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
                    print("[AI] Skipping \(providerType.rawValue): no API key")
                    continue
                }
            }

            let provider = AIProviderFactory.create(for: providerType)
            for attempt in 1...2 {
                do {
                    return try await operation(provider)
                } catch {
                    print("[AI] \(providerType.rawValue) attempt \(attempt) failed: \(error.localizedDescription)")
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
            print("[AppState] Failed to load persisted AI data: \(error)")
        }
    }
}
