import Foundation
import OSLog

private let chatLogger = Logger(subsystem: "com.flowtrack", category: "Chat")

// MARK: - Chat Message

struct ChatMessage: Identifiable, Sendable {
    let id: UUID
    let role: ChatMessageRole
    let content: String
    let timestamp: Date

    init(role: ChatMessageRole, content: String) {
        self.id = UUID()
        self.role = role
        self.content = content
        self.timestamp = Date()
    }
}

enum ChatMessageRole: Sendable {
    case user
    case assistant
    case error
}

// MARK: - ChatEngine

@MainActor @Observable
final class ChatEngine {
    static let shared = ChatEngine()

    var messages: [ChatMessage] = []
    var isThinking = false
    var contextDate: Date = Date() {
        didSet { invalidateContextCache() }
    }

    // Context cache: valid for 5 min for today, indefinitely for past days
    private var _cachedContext: String?
    private var _cachedContextDate: Date?
    private var _cachedContextBuiltAt: Date?

    private static let contextCacheTTL: TimeInterval = 300  // 5 min for today's data

    private init() {}

    // MARK: - Public API

    /// Full send (used internally). ChatView uses fetchReply directly for streaming.
    func send(_ text: String) async {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        messages.append(ChatMessage(role: .user, content: text))
        isThinking = true
        do {
            let reply = try await fetchReply(for: text)
            messages.append(ChatMessage(role: .assistant, content: reply))
        } catch {
            chatLogger.error("Chat error: \(error.localizedDescription, privacy: .private)")
            messages.append(ChatMessage(role: .error, content: error.localizedDescription))
        }
        isThinking = false
    }

    /// Fetch AI reply. User message must already be appended to `messages` before calling.
    func fetchReply(for _: String) async throws -> String {
        let systemPrompt = try await buildSystemPrompt(for: contextDate)

        // Cap history at 20 turns (10 exchanges) — balances context quality vs cost.
        // Each turn averages ~350 tokens; 20 turns ≈ 7,000 tokens of history.
        let history: [ChatTurn] = messages
            .filter { $0.role == .user || $0.role == .assistant }
            .suffix(20)
            .map { ChatTurn(role: $0.role == .user ? "user" : "assistant", content: $0.content) }

        return try await AppState.shared.withFallback { provider in
            try await provider.chat(messages: history, systemPrompt: systemPrompt)
        }
    }

    func clearMessages() {
        messages = []
    }

    // MARK: - Context Cache

    private func invalidateContextCache() {
        _cachedContext = nil
        _cachedContextDate = nil
        _cachedContextBuiltAt = nil
    }

    private func isCacheValid(for date: Date) -> Bool {
        guard let cached = _cachedContext,
              !cached.isEmpty,
              let cachedDate = _cachedContextDate,
              let builtAt = _cachedContextBuiltAt,
              Calendar.current.isDate(cachedDate, inSameDayAs: date) else { return false }

        // Past days: cache forever (data won't change)
        if !Calendar.current.isDateInToday(date) { return true }

        // Today: expire every 5 minutes so live data stays fresh
        return Date().timeIntervalSince(builtAt) < Self.contextCacheTTL
    }

    // MARK: - Context Building

    private func buildSystemPrompt(for date: Date) async throws -> String {
        if isCacheValid(for: date), let cached = _cachedContext { return cached }

        let dateStr = Self.dateFormatter.string(from: date)
        let isToday = Calendar.current.isDateInToday(date)
        let isFuture = date > Calendar.current.startOfDay(for: Calendar.current.date(byAdding: .day, value: 1, to: Date())!)

        // Core persona — kept concise to save tokens
        var parts: [String] = [
            """
            You are FlowTrack AI, a personal productivity coach with access to the user's activity tracking data.
            Data includes: app names, website domains, session durations, and AI-generated summaries.
            Window contents, file names, and full URLs are never collected — privacy is respected by design.
            Be direct, specific, and actionable. Use bullet points. Keep responses under 400 words unless asked for more.
            Date: \(dateStr)\(isToday ? " (Today)" : "")
            """
        ]

        if isFuture {
            parts.append("""
            No activity data exists yet for this future date.
            Help with planning, focus blocks, and goal-setting based on the user's typical patterns.
            """)
        } else {
            parts.append(try buildActivityContext(for: date))
        }

        let prompt = parts.joined(separator: "\n\n")
        _cachedContext = prompt
        _cachedContextDate = date
        _cachedContextBuiltAt = Date()
        return prompt
    }

    private func buildActivityContext(for date: Date) throws -> String {
        let sessions = try Database.shared.sessionsForDate(date)
        let stats    = try Database.shared.categoryStatsForDate(date)

        guard !sessions.isEmpty else {
            return "Activity: No data recorded for this date."
        }

        let active       = sessions.filter { !$0.isIdle }
        let totalActive  = active.reduce(0.0) { $0 + $1.duration }
        let totalAll     = sessions.reduce(0.0) { $0 + $1.duration }
        let focusTime    = stats.filter { $0.category.isProductive }.reduce(0.0) { $0 + $1.totalSeconds }
        let distractTime = stats.filter { $0.category.rawValue == "Distraction" }.reduce(0.0) { $0 + $1.totalSeconds }
        let focusPct     = totalActive > 0 ? Int(focusTime / totalActive * 100) : 0

        var lines: [String] = []

        // --- Overview (compact) ---
        lines.append("## Overview")
        lines.append("Tracked: \(Self.dur(totalAll)) | Active: \(Self.dur(totalActive)) | Focus: \(Self.dur(focusTime)) (\(focusPct)%)\(distractTime > 0 ? " | Distraction: \(Self.dur(distractTime)) (\(Int(distractTime / max(1,totalActive) * 100))%)" : "")")

        // --- Category breakdown ---
        if !stats.isEmpty {
            lines.append("\n## Time by Category")
            for s in stats.prefix(8) {
                lines.append("\(s.category.rawValue): \(Self.dur(s.totalSeconds)) (\(Int(s.percentage))%)")
            }
        }

        // --- Session timeline ---
        // Only sessions ≥ 3 min to reduce noise; capped at 25 to save tokens
        let appState = AppState.shared
        let significant = active.filter { $0.duration >= 180 }.prefix(25)
        if !significant.isEmpty {
            lines.append("\n## Sessions")
            for slot in significant {
                let t     = Self.timeFormatter.string(from: slot.startTime)
                let e     = Self.timeFormatter.string(from: slot.endTime)
                let dur   = Self.dur(slot.duration)
                let title = appState.sessionTitles[slot.id]
                // Only domain-stripped URLs, max 3 apps per session
                let topApps = slot.activities.prefix(3).map { a -> String in
                    if let url = a.url { return "\(a.appName)(\(AIPromptBuilder.domainOnly(from: url)))" }
                    return a.appName
                }.joined(separator: ",")
                var line = "\(t)–\(e) \(slot.category.rawValue) \(dur)"
                if let ti = title { line += " \"\(ti)\"" }
                line += " [\(topApps)]"
                if let sum = appState.sessionSummaries[slot.id] {
                    line += " → \(sum)"
                }
                lines.append(line)
            }
        }

        // --- Top apps (max 8, no raw titles) ---
        var appDur: [String: TimeInterval] = [:]
        for slot in active {
            for a in slot.activities { appDur[a.appName, default: 0] += a.duration }
        }
        let topApps = appDur.sorted { $0.value > $1.value }.prefix(8)
        if !topApps.isEmpty {
            lines.append("\n## Top Apps")
            for (app, dur) in topApps {
                lines.append("\(app): \(Self.dur(dur))")
            }
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Static Formatters (created once)

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .full; return f
    }()

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter(); f.timeStyle = .short; return f
    }()

    private static func dur(_ s: TimeInterval) -> String {
        let h = Int(s) / 3600, m = (Int(s) % 3600) / 60
        return h > 0 ? "\(h)h\(m)m" : "\(m)m"
    }
}

// MARK: - Quick Suggestions

extension ChatEngine {
    static let suggestions: [(label: String, icon: String, prompt: String)] = [
        ("Summarize my day",     "doc.text",                    "Give me a summary of my day — what I worked on, focus quality, and key highlights."),
        ("Focus analysis",       "brain",                       "Analyze my focus patterns. When was I most productive? What triggered distraction?"),
        ("Distraction report",   "exclamationmark.triangle",    "What were my biggest distractions? How much time did I lose and what caused them?"),
        ("Productivity score",   "chart.line.uptrend.xyaxis",   "Give me a productivity score out of 10 with honest reasoning."),
        ("Plan tomorrow",        "calendar.badge.plus",         "Help me plan an optimal schedule for tomorrow with focus blocks and breaks."),
        ("Context switching",    "arrow.left.arrow.right",      "How often did I context-switch? Is it hurting my deep work?"),
        ("Wins & regrets",       "trophy",                      "What went well today? What do I regret and how can I fix it tomorrow?"),
        ("Best work hours",      "clock",                       "When are my peak productive hours? When should I schedule deep work?"),
    ]
}
