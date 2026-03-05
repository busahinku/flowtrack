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
        didSet {
            // Rebuild context when date changes
            _cachedContext = nil
            _cachedContextDate = nil
        }
    }

    private var _cachedContext: String?
    private var _cachedContextDate: Date?

    private init() {}

    // MARK: - Send Message

    func send(_ text: String) async {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        let userMsg = ChatMessage(role: .user, content: text)
        messages.append(userMsg)
        isThinking = true

        do {
            let systemPrompt = try await buildSystemPrompt(for: contextDate)
            let history = messages
                .filter { $0.role == .user || $0.role == .assistant }
                .suffix(50) // cap at 50 turns to prevent unbounded token growth
                .map { ChatTurn(role: $0.role == .user ? "user" : "assistant", content: $0.content) }

            let reply = try await AppState.shared.withFallback { provider in
                try await provider.chat(messages: history, systemPrompt: systemPrompt)
            }

            messages.append(ChatMessage(role: .assistant, content: reply))
        } catch {
            chatLogger.error("Chat error: \(error.localizedDescription)")
            messages.append(ChatMessage(role: .error, content: error.localizedDescription))
        }

        isThinking = false
    }

    func clearMessages() {
        messages = []
    }

    // MARK: - Context Building

    private func buildSystemPrompt(for date: Date) async throws -> String {
        // Cache per date (avoid rebuilding on every message for same day)
        if let cached = _cachedContext,
           let cachedDate = _cachedContextDate,
           Calendar.current.isDate(cachedDate, inSameDayAs: date) {
            return cached
        }

        let dateStr = Self.formatDate(date)
        let isToday = Calendar.current.isDateInToday(date)
        let isFuture = date > Calendar.current.startOfDay(for: Date().addingTimeInterval(86400))

        var prompt = """
        You are FlowTrack AI, a personal productivity coach with full access to the user's computer activity data.
        You give honest, specific, and actionable insights about focus, productivity, and habits.
        Be direct and conversational. Use bullet points for lists. Keep responses focused and practical.

        ## Date: \(dateStr)\(isToday ? " (Today)" : "")
        """

        if isFuture {
            prompt += """

            ## Note
            This is a future date — no activity data exists yet.
            You can help with planning, scheduling, and setting productivity goals.
            Refer to past patterns if available.

            """
        } else {
            let context = try buildActivityContext(for: date)
            prompt += "\n\n" + context
        }

        prompt += """

        ## Instructions
        - Reference specific apps, times, and durations from the data when answering
        - Identify patterns: productive peaks, distraction triggers, energy dips
        - Be an honest coach — acknowledge both good and bad patterns
        - For planning questions, suggest concrete time blocks based on past behavior
        - Today's date is \(Self.formatDate(Date()))
        """

        _cachedContext = prompt
        _cachedContextDate = date
        return prompt
    }

    private func buildActivityContext(for date: Date) throws -> String {
        let sessions = try Database.shared.sessionsForDate(date)
        let stats = try Database.shared.categoryStatsForDate(date)

        guard !sessions.isEmpty else {
            return "## Activity Data\nNo activity recorded for this date."
        }

        let totalActive = sessions.filter { !$0.isIdle }.reduce(0.0) { $0 + $1.duration }
        let totalAll = sessions.reduce(0.0) { $0 + $1.duration }
        let focusStats = stats.filter { $0.category.isProductive }
        let focusTime = focusStats.reduce(0.0) { $0 + $1.totalSeconds }
        let focusPct = totalActive > 0 ? Int(focusTime / totalActive * 100) : 0
        let distractStats = stats.filter { $0.category.rawValue == "Distraction" }
        let distractTime = distractStats.reduce(0.0) { $0 + $1.totalSeconds }

        var lines: [String] = []

        // Overview
        lines.append("## Activity Overview")
        lines.append("- Total tracked time: \(Self.formatDur(totalAll))")
        lines.append("- Active (non-idle): \(Self.formatDur(totalActive))")
        lines.append("- Focus (productive): \(Self.formatDur(focusTime)) (\(focusPct)%)")
        if distractTime > 0 {
            lines.append("- Distraction time: \(Self.formatDur(distractTime)) (\(Int(distractTime / totalActive * 100))%)")
        }

        // Category breakdown
        if !stats.isEmpty {
            lines.append("\n## Time by Category")
            for stat in stats.prefix(8) {
                let pct = Int(stat.percentage)
                lines.append("- \(stat.category.rawValue): \(Self.formatDur(stat.totalSeconds)) (\(pct)%)")
            }
        }

        // Sessions timeline
        lines.append("\n## Session Timeline")
        let appState = AppState.shared
        let activeSessions = sessions.filter { !$0.isIdle }.prefix(30)
        for slot in activeSessions {
            let start = Self.formatTime(slot.startTime)
            let end = Self.formatTime(slot.endTime)
            let dur = Self.formatDur(slot.duration)
            let title = appState.sessionTitles[slot.id]
            let topApps = slot.activities.prefix(3).map { a in
                var s = a.appName
                if let url = a.url { s += " (\(AIPromptBuilder.domainOnly(from: url)))" }
                return s
            }.joined(separator: ", ")
            var line = "\(start)–\(end) | \(slot.category.rawValue) (\(dur))"
            if let t = title { line += " | \"\(t)\"" }
            line += " | Apps: \(topApps)"
            if let summary = appState.sessionSummaries[slot.id] {
                line += "\n  → \(summary)"
            }
            lines.append(line)
        }

        // Top apps
        var appDurations: [String: TimeInterval] = [:]
        for slot in sessions where !slot.isIdle {
            for activity in slot.activities {
                appDurations[activity.appName, default: 0] += activity.duration
            }
        }
        let topApps = appDurations.sorted { $0.value > $1.value }.prefix(10)
        if !topApps.isEmpty {
            lines.append("\n## Top Apps")
            for (app, dur) in topApps {
                lines.append("- \(app): \(Self.formatDur(dur))")
            }
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Formatting Helpers

    private static func formatDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .full
        return f.string(from: date)
    }

    private static func formatTime(_ date: Date) -> String {
        let f = DateFormatter()
        f.timeStyle = .short
        return f.string(from: date)
    }

    private static func formatDur(_ seconds: TimeInterval) -> String {
        let h = Int(seconds) / 3600
        let m = (Int(seconds) % 3600) / 60
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }
}

// MARK: - Quick Suggestions

extension ChatEngine {
    static let suggestions: [(label: String, icon: String, prompt: String)] = [
        ("Summarize my day", "doc.text", "Give me a detailed summary of my day — what I worked on, how focused I was, and key highlights."),
        ("Focus analysis", "brain", "Analyze my focus patterns today. When was I most productive? What pulled me into distraction? Be specific."),
        ("Distraction report", "exclamationmark.triangle", "What were my biggest distractions today? How much time did I lose and what triggered them?"),
        ("Productivity score", "chart.line.uptrend.xyaxis", "Give me a productivity score out of 10 for today with a breakdown of why. Be honest."),
        ("Plan tomorrow", "calendar.badge.plus", "Based on my patterns, help me plan an optimal schedule for tomorrow with focus blocks and breaks."),
        ("Context switching", "arrow.left.arrow.right", "How often did I context-switch today? Is it affecting my deep work? What should I change?"),
        ("Wins & regrets", "trophy", "What went well today that I should repeat? What do I regret and how can I fix it tomorrow?"),
        ("Best work hours", "clock", "Based on my data, what are my peak productive hours? When should I schedule deep work?"),
    ]
}
