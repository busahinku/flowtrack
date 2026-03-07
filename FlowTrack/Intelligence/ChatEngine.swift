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
            You are FlowTrack AI, a personal productivity coach embedded in the FlowTrack app.
            You have access to the user's activity tracking data for the date shown.

            FlowTrack features you can discuss and help with:
            - Timeline: Visual hour-by-hour activity log with session cards
            - Statistics: Charts for category breakdown, top apps, productivity trends
            - Focus Shield (App Blocker): Create "block cards" grouping sites/apps to block during focus time
            - Timer: Session, countdown, or stopwatch modes — can attach to tasks
            - Tasks (Todos): Task list with status (active/done), priority, and due dates
            - Journal: Private encrypted daily journal with markdown support
            - Settings: AI provider config, categories, themes, tracking preferences

            Data collected: app names, website domains, window titles (optional), session durations.
            Window contents, file names, personal data, and full URLs are NEVER collected — privacy first.

            Be direct, specific, and actionable. Use bullet points. Keep responses under 400 words unless asked.
            Only mention categories that have data. Use only: Work and Distraction (not Creative/Personal/Entertainment).
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
            // Add tasks context if available
            if let todoContext = buildTodoContext(for: date), !todoContext.isEmpty {
                parts.append(todoContext)
            }
        }

        let prompt = parts.joined(separator: "\n\n")
        _cachedContext = prompt
        _cachedContextDate = date
        _cachedContextBuiltAt = Date()
        return prompt
    }

    private func buildTodoContext(for date: Date) -> String? {
        let todos = TodoStore.shared.todos
        guard !todos.isEmpty else { return nil }
        let active = todos.filter { $0.status == .pending || $0.status == .inProgress }
        let done = todos.filter { $0.status == .done }
        var lines: [String] = ["\n## Tasks"]
        if !active.isEmpty {
            let activeTitles = active.prefix(6).map { "- \($0.title) (\($0.priority == .high ? "high" : $0.priority == .medium ? "medium" : "low"))" }.joined(separator: "\n")
            lines.append("Active (\(active.count)): \n\(activeTitles)")
        }
        if !done.isEmpty {
            lines.append("Completed today: \(done.count)")
        }
        return lines.joined(separator: "\n")
    }

    private func buildActivityContext(for date: Date) throws -> String {
        let sessions = try Database.shared.sessionsForDate(date)
        let stats    = try Database.shared.categoryStatsForDate(date)

        guard !sessions.isEmpty else {
            return "Activity: No data recorded for this date."
        }

        let active       = sessions.filter { !$0.isIdle }
        // Use activeDuration (sum of activity durations) — excludes idle gaps within sessions
        let totalActive  = active.reduce(0.0) { $0 + $1.activeDuration }
        let focusTime    = stats.filter { $0.category.isProductive }.reduce(0.0) { $0 + $1.totalSeconds }
        let distractTime = stats.filter { $0.category.rawValue == "Distraction" }.reduce(0.0) { $0 + $1.totalSeconds }
        let focusPct     = totalActive > 0 ? Int(focusTime / totalActive * 100) : 0

        var lines: [String] = []

        // --- Overview (compact) ---
        lines.append("## Overview")
        lines.append("Active time: \(Self.dur(totalActive)) | Work: \(Self.dur(focusTime)) (\(focusPct)%)\(distractTime > 0 ? " | Distraction: \(Self.dur(distractTime)) (\(Int(distractTime / max(1,totalActive) * 100))%)" : "")")

        // --- Category breakdown (non-idle, non-uncategorized with data) ---
        let meaningfulStats = stats.filter { $0.category != .idle && $0.totalSeconds > 60 }
        if !meaningfulStats.isEmpty {
            lines.append("\n## Time by Category")
            for s in meaningfulStats.prefix(6) {
                lines.append("\(s.category.rawValue): \(Self.dur(s.totalSeconds)) (\(Int(s.percentage))%)")
            }
        }

        // --- Session timeline ---
        // Only sessions ≥ 3 min active time; capped at 25 to save tokens
        let significant = active.filter { $0.activeDuration >= 180 }.prefix(25)
        if !significant.isEmpty {
            lines.append("\n## Sessions")
            for slot in significant {
                let t     = Self.timeFormatter.string(from: slot.startTime)
                let e     = Self.timeFormatter.string(from: slot.endTime)
                let dur   = Self.dur(slot.activeDuration)
                let title = slot.title
                // Only domain-stripped URLs, max 3 apps per session
                let topApps = slot.activities.prefix(3).map { a -> String in
                    if let url = a.url { return "\(a.appName)(\(AIPromptBuilder.domainOnly(from: url)))" }
                    return a.appName
                }.joined(separator: ",")
                var line = "\(t)–\(e) \(slot.category.rawValue) \(dur)"
                if let ti = title { line += " \"\(ti)\"" }
                line += " [\(topApps)]"
                if let sum = slot.summary {
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
        ("Summarize my day",      "doc.text",                 "Give me a summary of my day — what I worked on, focus quality, and key highlights."),
        ("Productivity score",    "chart.line.uptrend.xyaxis","Give me a productivity score out of 10 with honest, specific reasoning based on my actual data."),
        ("Distraction report",    "exclamationmark.triangle", "What were my biggest distractions today? How much time did I lose and what can I do about it?"),
        ("Focus analysis",        "brain",                    "Analyze my focus patterns today. When was I most productive? What disrupted deep work?"),
        ("What to block?",        "shield.lefthalf.filled",   "Based on my activity data, which websites or apps should I add to my Focus Shield to protect my focus time?"),
        ("Task recommendations",  "checkmark.circle",         "Based on how I spent my time today, what tasks should I prioritize tomorrow?"),
        ("Best work hours",       "clock",                    "Based on my session data, when are my peak productive hours? When should I schedule deep work?"),
        ("Plan tomorrow",         "calendar.badge.plus",      "Help me plan an optimal schedule for tomorrow with focus blocks and structured break times."),
        ("Context switching",     "arrow.left.arrow.right",   "How often did I context-switch today? Is it hurting my deep work and how can I improve?"),
        ("Journal prompt",        "pencil.line",              "Based on my activity today, give me 3 thoughtful journal prompts to reflect on my progress and mindset."),
    ]
}
