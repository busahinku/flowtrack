import Foundation
import OSLog

private nonisolated let studyLog = Logger(subsystem: "com.flowtrack", category: "StudyTracker")

// MARK: - StudyTrackerEngine

/// Auto-starts a stopwatch **only** when the current activity matches an
/// Auto Catch–enabled todo. Stops within 20 seconds of distraction.
///
/// Two-tier matching (runs every ~5 s via ActivityTracker):
/// 1. **Keyword match (instant):** checks window title, URL, and app name
///    against each todo's `autoCatchKeywords`.
/// 2. **AI match (debounced 10 s):** asks the configured AI provider which
///    todo best fits the current context. Only fires when keywords miss.
///
/// YouTube override: if the URL contains "youtube" and a keyword matches the
/// window title, the activity is as productive even
/// `DefaultRules.json` categorises YouTube as Distraction.
@MainActor @Observable
final class StudyTrackerEngine {
    static let shared = StudyTrackerEngine()

    private enum MatchSource {
        case keyword
        case ai
    }

    // MARK: - Observable State

    /// Whether this engine auto-started the current stopwatch session.
    private(set) var isAutoTracking = false
    /// The todo linked by matching (nil = not yet matched or no match).
    private(set) var matchedTodoId: String? = nil

    // MARK: - Tuning

    /// Seconds of consecutive matched activity before auto-starting (keyword match).
    private let keywordStartGrace: TimeInterval = 3
    /// Seconds of consecutive matched activity before auto-starting (AI match).
    private let aiStartGrace: TimeInterval = 2
    /// Seconds of non-matching activity before auto-stopping the stopwatch.
    private let stopGrace: TimeInterval = 10
    /// Minimum seconds between successive AI todo-matching calls.
    private let aiCooldown: TimeInterval = 3

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
    /// The todo ID from the last auto-tracking session — enables instant restart on return.
    private var lastTrackedTodoId: String? = nil

    private init() {}

    // MARK: - Public API

    func handleTrackingStarted() {
        cancelPendingStart()
        cancelPendingStop()
        aiMatchTask?.cancel()
        aiMatchTask = nil
        matchedSince = nil
        unmatchedSince = nil
        pendingMatchTodoId = nil
        lastAIContext = ""
        lastAIMatchAt = nil
    }

    func handleTrackingStopped() {
        cancelPendingStart()
        cancelPendingStop()
        aiMatchTask?.cancel()
        aiMatchTask = nil
        matchedSince = nil
        unmatchedSince = nil
        pendingMatchTodoId = nil
        lastAIContext = ""
        lastAIMatchAt = nil
        lastTrackedTodoId = nil

        guard isAutoTracking else {
            matchedTodoId = nil
            return
        }

        isAutoTracking = false
        matchedTodoId = nil

        let timer = TimerStore.shared
        if timer.isRunning && timer.mode == .stopwatch {
            timer.pause()
            studyLog.info("Study tracker: stopped because activity tracking was paused")
        }
    }

    /// Called by ActivityTracker after every category resolution (~every 5 seconds).
    func checkActivity(category: Category, appName: String, windowTitle: String, url: String? = nil) {
        guard category != .idle else { return }

        let autoCatchTodos = TodoStore.shared.todos.filter { $0.autoCatch && $0.status != .done }
        guard !autoCatchTodos.isEmpty else {
            handleUnmatched()
            return
        }

        // YouTube exception: allow through the distraction gate if keywords match
        let isYouTube = url?.lowercased().contains("youtube") == true
        if category == .distraction && !isYouTube {
            handleUnmatched()
            return
        }

        // ── Tier 1: instant keyword match ────────────────────────────
        if let matched = keywordMatch(appName: appName, windowTitle: windowTitle, url: url, todos: autoCatchTodos) {
            handleMatched(todo: matched, grace: keywordStartGrace, source: .keyword, appName: appName, windowTitle: windowTitle, url: url)
            return
        }

        // If an auto-tracked timer is already running, only direct keyword matches may keep
        // it alive or switch it. AI fallback is allowed to START tracking, but not to keep
        // or retarget an existing auto-started timer to a guessed todo.
        if isAutoTracking {
            aiMatchTask?.cancel()
            aiMatchTask = nil
            handleUnmatched()
            return
        }

        // ── Tier 2: AI match (debounced) ─────────────────────────────
        let contextKey = "\(appName)|\(windowTitle.prefix(80))|\((url ?? "").prefix(120))"
        let cooldownElapsed = lastAIMatchAt.map { Date().timeIntervalSince($0) > aiCooldown } ?? true

        if cooldownElapsed && contextKey != lastAIContext {
            scheduleAIMatch(appName: appName, windowTitle: windowTitle, url: url, todos: autoCatchTodos)
        }

        // While waiting for AI, if we're currently tracking and keywords didn't match,
        // schedule a stop. The AI result will cancel the stop if it finds a match.
        if isAutoTracking {
            handleUnmatched()
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
                // Skip keywords shorter than 3 chars — prevents "go", "ai", "js" matching everything
                guard keyword.count >= 3 else { continue }
                if title.contains(keyword) || app.contains(keyword) || urlLower.contains(keyword) {
                    return todo
                }
            }
            // Also match the todo title itself against the window title
            let todoTitleLower = todo.title.lowercased()
            let titleWords = todoTitleLower.split(separator: " ").filter { $0.count > 3 }
            let matchCount = titleWords.filter { title.contains($0) || urlLower.contains($0) }.count
            // Require at least 2 filterable words and at least 2 matches (or half, whichever is larger)
            if titleWords.count >= 2 && matchCount >= max(2, (titleWords.count + 1) / 2) {
                return todo
            }
        }
        return nil
    }

    // MARK: - State Transitions

    private func handleMatched(todo: TodoItem, grace: TimeInterval, source: MatchSource, appName: String, windowTitle: String, url: String?) {
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

        // Instant restart: if returning to the same todo that was just stopped,
        // skip the grace period entirely and resume immediately.
        if todo.id == lastTrackedTodoId {
            startAutoTracking(todo: todo, appName: appName, windowTitle: windowTitle)
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
        let capturedURL = url
        let capturedContextKey = contextKey(appName: appName, windowTitle: windowTitle, url: url)
        pendingStartTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(grace)) } catch { return }
            guard let self, self.matchedSince != nil else { return }

            // Re-verify before auto-starting so quick tab hops do not start the timer.
            let currentApp = ActivityTracker.shared.currentApp
            let currentTitle = ActivityTracker.shared.currentTitle
            let currentURL = ActivityTracker.shared.currentURL
            let recheckURL = currentURL ?? capturedURL

            let stillMatches: Bool
            switch source {
            case .keyword:
                let activeTodos = TodoStore.shared.todos.filter { $0.autoCatch && $0.status != .done }
                stillMatches = self.keywordMatch(appName: currentApp, windowTitle: currentTitle, url: recheckURL, todos: activeTodos)?.id == capturedTodo.id
            case .ai:
                stillMatches = self.contextKey(appName: currentApp, windowTitle: currentTitle, url: recheckURL) == capturedContextKey
            }

            guard stillMatches else {
                self.cancelPendingStart()
                self.matchedSince = nil
                self.pendingMatchTodoId = nil
                return
            }

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
        lastAIContext = contextKey(appName: appName, windowTitle: windowTitle, url: url)
        lastAIMatchAt = Date()

        let capturedApp = appName
        let capturedTitle = windowTitle
        let capturedTodos = todos

        aiMatchTask = Task { [weak self] in
            let matchedTodo = await self?.matchTodoWithAI(
                appName: capturedApp, windowTitle: capturedTitle, url: url, todos: capturedTodos
            )
            guard !Task.isCancelled, let self else { return }
            self.aiMatchTask = nil

            guard !self.isAutoTracking else { return }

            if let todo = matchedTodo {
                self.handleMatched(todo: todo, grace: self.aiStartGrace, source: .ai, appName: capturedApp, windowTitle: capturedTitle, url: url)
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
        lastTrackedTodoId = todo.id
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
    private nonisolated func matchTodoWithAI(appName: String, windowTitle: String, url: String?, todos: [TodoItem]) async -> TodoItem? {
        let todoList = todos.enumerated()
            .map {
                let todo = $0.element
                let notes = todo.notes.trimmingCharacters(in: .whitespacesAndNewlines)
                let keywordPart = todo.autoCatchKeywords.isEmpty ? "" : " | keywords: \(todo.autoCatchKeywords)"
                let notesPart = notes.isEmpty ? "" : " | notes: \(notes.prefix(120))"
                return "\($0.offset + 1). \(todo.title)\(keywordPart)\(notesPart)"
            }
            .joined(separator: "\n")

        let prompt = """
        A user is working in: \(appName) — "\(windowTitle.prefix(120))"
        URL: \(url ?? "none")

        Their auto-catch tasks:
        \(todoList)

        Which task number (1–\(todos.count)) best matches what they are doing right now?
        Use semantic meaning, not just exact keyword overlap.
        Prefer task title first, then keywords, then notes.
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

    private func contextKey(appName: String, windowTitle: String, url: String?) -> String {
        "\(appName)|\(windowTitle.prefix(80))|\((url ?? "").prefix(120))"
    }
}
