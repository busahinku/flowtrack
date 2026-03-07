import Foundation
import OSLog

private nonisolated let studyLog = Logger(subsystem: "com.flowtrack", category: "StudyTracker")

// MARK: - StudyTrackerEngine

/// Auto-starts a stopwatch **only** when the current activity matches an
/// Auto Catch–enabled todo. Stops within 10 seconds of distraction.
///
/// Two-tier matching (runs every ~5 s via ActivityTracker):
/// 1. **Keyword match (instant):** checks window title, URL, and app name
///    against each todo's `autoCatchKeywords`.
/// 2. **AI match (debounced 10 s):** asks the configured AI provider which
///    todo best fits the current context. Only fires when keywords miss.
///
/// YouTube override: if the URL contains "youtube" and a keyword matches the
/// window title, the activity is treated as productive even though
/// `DefaultRules.json` categorises YouTube as Distraction.
@MainActor @Observable
final class StudyTrackerEngine {
    static let shared = StudyTrackerEngine()

    // MARK: - Observable State

    /// Whether this engine auto-started the current stopwatch session.
    private(set) var isAutoTracking = false
    /// The todo linked by matching (nil = not yet matched or no match).
    private(set) var matchedTodoId: String? = nil

    // MARK: - Tuning

    /// Seconds of consecutive matched activity before auto-starting (keyword match).
    private let keywordStartGrace: TimeInterval = 3
    /// Seconds of consecutive matched activity before auto-starting (AI match).
    private let aiStartGrace: TimeInterval = 5
    /// Seconds of non-matching activity before auto-stopping the stopwatch.
    private let stopGrace: TimeInterval = 10
    /// Minimum seconds between successive AI todo-matching calls.
    private let aiCooldown: TimeInterval = 10

    // MARK: - Internal State

    private var matchedSince: Date? = nil
    private var unmatchedSince: Date? = nil
    private var pendingStartTask: Task<Void, Never>? = nil
    private var pendingStopTask: Task<Void, Never>? = nil
    private var aiMatchTask: Task<Void, Never>? = nil
    private var lastAIMatchAt: Date? = nil
    /// Context key for the last AI call — avoids re-calling for identical context.
    private var lastAIContext: String = ""
    /// The todo ID found by the latest keyword or AI match (before timer starts).
    private var pendingMatchTodoId: String? = nil

    private init() {}

    // MARK: - Public API

    /// Called by ActivityTracker after every category resolution (~every 5 seconds).
    func checkActivity(category: Category, appName: String, windowTitle: String, url: String? = nil) {
        guard category != .idle else { return }

        let autoCatchTodos = TodoStore.shared.todos.filter { $0.autoCatch && $0.status != .done }
        guard !autoCatchTodos.isEmpty else {
            // No auto-catch todos → behave as if unmatched
            handleUnmatched()
            return
        }

        // ── Tier 1: instant keyword match ────────────────────────────
        if let matched = keywordMatch(appName: appName, windowTitle: windowTitle, url: url, todos: autoCatchTodos) {
            handleMatched(todo: matched, grace: keywordStartGrace, appName: appName, windowTitle: windowTitle)
            return
        }

        // ── Tier 2: AI match (debounced) ─────────────────────────────
        let contextKey = "\(appName)|\(windowTitle.prefix(80))"
        let cooldownElapsed = lastAIMatchAt.map { Date().timeIntervalSince($0) > aiCooldown } ?? true

        if cooldownElapsed && contextKey != lastAIContext {
            scheduleAIMatch(appName: appName, windowTitle: windowTitle, url: url, todos: autoCatchTodos)
        }

        // While waiting for AI, if we're currently tracking and the context looks like it might
        // still be relevant (same app), give it the benefit of the doubt — don't stop yet.
        if isAutoTracking {
            // Cancel any pending stop — we're still potentially on-task.
            // The stop will be scheduled only if AI confirms no match.
            if aiMatchTask != nil {
                cancelPendingStop()
            } else {
                // AI already finished and didn't match → treat as unmatched
                handleUnmatched()
            }
        }
    }

    // MARK: - Matching

    /// Instant keyword match: checks window title, URL, and app name against todo keywords.
    private func keywordMatch(appName: String, windowTitle: String, url: String?, todos: [TodoItem]) -> TodoItem? {
        let title = windowTitle.lowercased()
        let app = appName.lowercased()
        let urlLower = url?.lowercased() ?? ""

        for todo in todos {
            let keywords = todo.parsedKeywords
            guard !keywords.isEmpty else { continue }
            for keyword in keywords {
                if title.contains(keyword) || app.contains(keyword) || urlLower.contains(keyword) {
                    return todo
                }
            }
            // Also match the todo title itself against the window title
            let todoTitleLower = todo.title.lowercased()
            let titleWords = todoTitleLower.split(separator: " ").filter { $0.count > 3 }
            let matchCount = titleWords.filter { title.contains($0) || urlLower.contains($0) }.count
            if titleWords.count > 0 && matchCount >= max(1, titleWords.count / 2) {
                return todo
            }
        }
        return nil
    }

    // MARK: - State Transitions

    private func handleMatched(todo: TodoItem, grace: TimeInterval, appName: String, windowTitle: String) {
        // Cancel any pending stop
        cancelPendingStop()
        unmatchedSince = nil

        if isAutoTracking {
            // Already tracking — update linked todo if different
            if matchedTodoId != todo.id {
                matchedTodoId = todo.id
                TimerStore.shared.setTodo(todo.id)
                studyLog.info("Study tracker: switched to todo \"\(todo.title)\"")
            }
            return
        }

        // Not yet tracking — schedule auto-start after grace
        let newMatchId = todo.id
        if pendingMatchTodoId == newMatchId && pendingStartTask != nil {
            // Already scheduling a start for this todo
            return
        }

        pendingMatchTodoId = newMatchId
        cancelPendingStart()
        matchedSince = Date()

        let capturedTodo = todo
        let capturedApp = appName
        let capturedTitle = windowTitle
        pendingStartTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(grace)) } catch { return }
            guard let self, self.matchedSince != nil else { return }
            self.startAutoTracking(todo: capturedTodo, appName: capturedApp, windowTitle: capturedTitle)
        }
    }

    private func handleUnmatched() {
        // Cancel any pending start
        cancelPendingStart()
        matchedSince = nil
        pendingMatchTodoId = nil

        if isAutoTracking && unmatchedSince == nil {
            unmatchedSince = Date()
            schedulePendingStop()
        }
    }

    private func cancelPendingStart() {
        pendingStartTask?.cancel()
        pendingStartTask = nil
    }

    private func cancelPendingStop() {
        pendingStopTask?.cancel()
        pendingStopTask = nil
    }

    // MARK: - Scheduling

    private func schedulePendingStop() {
        pendingStopTask?.cancel()
        pendingStopTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(self?.stopGrace ?? 10)) } catch { return }
            guard let self, self.unmatchedSince != nil else { return }
            self.stopAutoTracking()
        }
    }

    private func scheduleAIMatch(appName: String, windowTitle: String, url: String?, todos: [TodoItem]) {
        aiMatchTask?.cancel()
        lastAIContext = "\(appName)|\(windowTitle.prefix(80))"
        lastAIMatchAt = Date()

        let capturedApp = appName
        let capturedTitle = windowTitle
        let capturedTodos = todos

        aiMatchTask = Task { [weak self] in
            let matchedTodo = await self?.matchTodoWithAI(
                appName: capturedApp, windowTitle: capturedTitle, todos: capturedTodos
            )
            guard !Task.isCancelled, let self else { return }
            self.aiMatchTask = nil

            if let todo = matchedTodo {
                self.handleMatched(todo: todo, grace: self.aiStartGrace, appName: capturedApp, windowTitle: capturedTitle)
            } else if self.isAutoTracking {
                self.handleUnmatched()
            }
        }
    }

    // MARK: - Start / Stop

    private func startAutoTracking(todo: TodoItem, appName: String, windowTitle: String) {
        let timer = TimerStore.shared
        // Never interrupt a manually running timer.
        guard !timer.isRunning else {
            cancelPendingStart()
            matchedSince = nil
            pendingMatchTodoId = nil
            return
        }

        isAutoTracking = true
        matchedTodoId = todo.id
        pendingStartTask = nil
        pendingMatchTodoId = nil
        unmatchedSince = nil

        timer.switchMode(.stopwatch)
        timer.setTodo(todo.id)
        timer.start()
        studyLog.info("Study tracker: auto-started for \"\(todo.title)\" [\(appName) — \(windowTitle.prefix(60))]")
    }

    private func stopAutoTracking() {
        guard isAutoTracking else { return }

        aiMatchTask?.cancel()
        aiMatchTask = nil
        isAutoTracking = false
        matchedTodoId = nil
        unmatchedSince = nil
        pendingStopTask = nil
        matchedSince = nil
        pendingMatchTodoId = nil
        lastAIContext = ""
        lastAIMatchAt = nil

        let timer = TimerStore.shared
        if timer.isRunning && timer.mode == .stopwatch {
            timer.pause()
            studyLog.info("Study tracker: auto-stopped (no matching activity for \(Int(self.stopGrace))s)")
        }
    }

    // MARK: - AI Todo Matching

    /// Runs in background — asks AI which auto-catch todo best matches the current activity.
    private nonisolated func matchTodoWithAI(appName: String, windowTitle: String, todos: [TodoItem]) async -> TodoItem? {
        let todoList = todos.enumerated()
            .map { "\($0.offset + 1). \($0.element.title)\($0.element.autoCatchKeywords.isEmpty ? "" : " (keywords: \($0.element.autoCatchKeywords))")" }
            .joined(separator: "\n")

        let prompt = """
        A user is working in: \(appName) — "\(windowTitle.prefix(120))"

        Their auto-catch tasks:
        \(todoList)

        Which task number (1–\(todos.count)) best matches what they are doing right now?
        Reply with ONLY the task number. If nothing clearly matches, reply 0.
        """

        do {
            let result = try await AppState.shared.withFallback { provider in
                try await provider.chat(
                    messages: [ChatTurn(role: "user", content: prompt)],
                    systemPrompt: "You match user activities to tasks. Reply with a single integer only."
                )
            }

            let numStr = result
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .components(separatedBy: .whitespaces).first ?? "0"

            if let idx = Int(numStr), idx > 0, idx <= todos.count {
                let todo = todos[idx - 1]
                studyLog.info("Study tracker AI: matched \"\(todo.title)\"")
                return todo
            }
        } catch {
            studyLog.debug("Study tracker AI match failed: \(error.localizedDescription)")
        }
        return nil
    }
}
