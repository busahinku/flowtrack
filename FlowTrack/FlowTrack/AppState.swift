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

    private init() {
        loadPersistedAIData()
        startTimers()
        Task { await refreshData() }
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

    // MARK: - AI Processing

    /// Manual AI run — processes ALL unprocessed sessions
    func runAINow() async {
        guard !isRunningAI else { return }
        isRunningAI = true
        defer { isRunningAI = false }

        await generateAllSessionContent(maxTitles: 50, maxSummaries: 20)
        await categorizeBatch(limit: 500)
        await refreshData()
    }

    /// Timer-based AI batch — smaller limits
    func runAIBatch() async {
        guard !isRunningAI else { return }
        isRunningAI = true
        defer { isRunningAI = false }

        await generateAllSessionContent(maxTitles: 8, maxSummaries: 5)
        await categorizeBatch(limit: settings.aiBatchSize)
        await refreshData()
    }

    func generateAllSessionContent(maxTitles: Int = 50, maxSummaries: Int = 20) async {
        // Process ALL sessions that don't have titles yet
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
            var updates: [(id: Int64, category: Category)] = []
            let batchSize = 30
            for batch in stride(from: 0, to: uncategorized.count, by: batchSize) {
                let end = min(batch + batchSize, uncategorized.count)
                for record in uncategorized[batch..<end] {
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
                        updates.append((id: id, category: category))
                    } catch {
                        print("[AI] Categorization failed for \(record.appName): \(error)")
                    }
                }
            }
            if !updates.isEmpty {
                try Database.shared.updateCategoriesBatch(updates)
            }
        } catch {
            print("[AI] Batch error: \(error)")
        }
    }

    // MARK: - AI Fallback Chain

    func withFallback<T>(_ operation: (any AIProvider) async throws -> T) async throws -> T {
        let chain = providerChain()
        var lastError: Error?

        for providerType in chain {
            let provider = AIProviderFactory.create(for: providerType)
            for attempt in 1...2 {
                do {
                    return try await operation(provider)
                } catch {
                    print("[AI] \(providerType.rawValue) attempt \(attempt) failed: \(error.localizedDescription)")
                    lastError = error
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
        let topApps = slot.activities.prefix(3).map(\.appName)
        return topApps.joined(separator: ", ")
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
