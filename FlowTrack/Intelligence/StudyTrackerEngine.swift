import Foundation
import OSLog

private nonisolated let studyLog = Logger(subsystem: "com.flowtrack", category: "StudyTracker")

// MARK: - StudyTrackerEngine

/// Always-on engine that automatically starts a stopwatch when the user begins
/// productive (non-distraction) work, and stops it when they drift to distractions.
///
/// Design goals (7/24 background, battery-friendly):
/// - No polling. Only reacts to activity events already fired by ActivityTracker (~5s).
/// - AI todo-matching is debounced: fires at most once per `matchCooldown` seconds,
///   only when the app context meaningfully changes, and is cancelled if context changes again.
/// - Only one AI task can be in-flight at a time.
/// - Respects manual timer control: never interrupts a running timer.
@MainActor @Observable
final class StudyTrackerEngine {
    static let shared = StudyTrackerEngine()

    // MARK: - Observable State

    /// Whether this engine auto-started the current stopwatch session.
    private(set) var isAutoTracking = false
    /// The todo linked by AI matching (nil = not yet matched or no match).
    private(set) var matchedTodoId: String? = nil

    // MARK: - Tuning

    /// Seconds of consecutive productive work before auto-starting the stopwatch.
    private let startGrace: TimeInterval = 12
    /// Seconds of consecutive distraction before stopping the stopwatch.
    private let stopGrace: TimeInterval = 45
    /// Minimum seconds between successive AI todo-matching calls.
    private let matchCooldown: TimeInterval = 120

    // MARK: - Internal State

    private var productiveSince: Date? = nil
    private var distractionSince: Date? = nil
    private var pendingStartTask: Task<Void, Never>? = nil
    private var pendingStopTask: Task<Void, Never>? = nil
    /// The in-flight AI matching task — cancelled if context changes.
    private var aiMatchTask: Task<Void, Never>? = nil
    /// Timestamp of the last AI match call (rate-limiting).
    private var lastMatchAt: Date? = nil
    /// App name at last match call — only re-match when app changes.
    private var lastMatchedApp: String = ""

    private init() {}

    // MARK: - Public API

    /// Called by ActivityTracker after every category resolution (~every 5 seconds).
    /// Must be cheap: no I/O, no blocking work.
    func checkActivity(category: Category, appName: String, windowTitle: String, url: String? = nil) {
        guard category != .idle else { return }

        if category == .distraction {
            // Cancel any pending auto-start
            pendingStartTask?.cancel()
            pendingStartTask = nil
            productiveSince = nil

            // Schedule stop if we are currently auto-tracking
            if isAutoTracking && distractionSince == nil {
                distractionSince = Date()
                schedulePendingStop()
            }
        } else {
            // Productive activity — cancel any pending stop
            pendingStopTask?.cancel()
            pendingStopTask = nil
            distractionSince = nil

            if !isAutoTracking {
                // Not yet tracking — schedule auto-start after grace period
                if pendingStartTask == nil {
                    productiveSince = Date()
                    schedulePendingStart(appName: appName, windowTitle: windowTitle)
                }
            } else {
                // Already tracking — only re-run AI matching if:
                // 1. App changed (meaningful context shift), AND
                // 2. Cooldown has elapsed, AND
                // 3. No match has been found yet for this session
                if matchedTodoId == nil,
                   appName != lastMatchedApp,
                   lastMatchAt.map({ Date().timeIntervalSince($0) > matchCooldown }) ?? true {
                    scheduleAIMatch(appName: appName, windowTitle: windowTitle)
                }
            }
        }
    }

    // MARK: - Scheduling

    private func schedulePendingStart(appName: String, windowTitle: String) {
        let capturedApp = appName
        let capturedTitle = windowTitle
        pendingStartTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(self?.startGrace ?? 12)) } catch { return }
            guard let self, self.productiveSince != nil else { return }
            self.startAutoTracking(appName: capturedApp, windowTitle: capturedTitle)
        }
    }

    private func schedulePendingStop() {
        pendingStopTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(self?.stopGrace ?? 45)) } catch { return }
            guard let self, self.distractionSince != nil else { return }
            self.stopAutoTracking()
        }
    }

    private func scheduleAIMatch(appName: String, windowTitle: String) {
        aiMatchTask?.cancel()
        lastMatchedApp = appName
        lastMatchAt = Date()
        let capturedApp = appName
        let capturedTitle = windowTitle
        aiMatchTask = Task { [weak self] in
            await self?.matchTodo(appName: capturedApp, windowTitle: capturedTitle)
        }
    }

    // MARK: - Start / Stop

    private func startAutoTracking(appName: String, windowTitle: String) {
        let timer = TimerStore.shared
        // Never interrupt a manually running timer.
        guard !timer.isRunning else {
            pendingStartTask = nil
            productiveSince = nil
            return
        }

        isAutoTracking = true
        matchedTodoId = nil
        pendingStartTask = nil
        lastMatchedApp = ""
        lastMatchAt = nil

        timer.switchMode(.stopwatch)
        timer.start()
        studyLog.info("Study tracker: auto-started stopwatch [\(appName)]")

        // Kick off initial AI match
        scheduleAIMatch(appName: appName, windowTitle: windowTitle)
    }

    private func stopAutoTracking() {
        guard isAutoTracking else { return }

        aiMatchTask?.cancel()
        aiMatchTask = nil
        isAutoTracking = false
        matchedTodoId = nil
        distractionSince = nil
        pendingStopTask = nil
        lastMatchedApp = ""
        lastMatchAt = nil

        let timer = TimerStore.shared
        if timer.isRunning && timer.mode == .stopwatch {
            timer.pause()
            studyLog.info("Study tracker: auto-stopped stopwatch (distraction)")
        }
    }

    // MARK: - AI Todo Matching

    /// Runs in background — at most one call in-flight, rate-limited by `matchCooldown`.
    private func matchTodo(appName: String, windowTitle: String) async {
        let todos = TodoStore.shared.todos.filter { $0.status != .done }
        guard !todos.isEmpty else { return }

        let todoList = todos.enumerated()
            .map { "\($0.offset + 1). \($0.element.title)" }
            .joined(separator: "\n")

        let prompt = """
        A user is working in: \(appName) — "\(windowTitle.prefix(120))"

        Their pending tasks:
        \(todoList)

        Which task number (1–\(todos.count)) best matches what they are doing?
        Reply with ONLY the task number. If nothing matches, reply 0.
        """

        do {
            let result = try await AppState.shared.withFallback { provider in
                try await provider.chat(
                    messages: [ChatTurn(role: "user", content: prompt)],
                    systemPrompt: "You match user activities to their task list. Reply with a single integer only."
                )
            }

            guard !Task.isCancelled else { return }

            let numStr = result
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .components(separatedBy: .whitespaces).first ?? "0"

            if let idx = Int(numStr), idx > 0, idx <= todos.count {
                let todo = todos[idx - 1]
                matchedTodoId = todo.id
                TimerStore.shared.setTodo(todo.id)
                studyLog.info("Study tracker: matched todo \"\(todo.title)\"")
            }
        } catch {
            studyLog.debug("Todo matching failed: \(error.localizedDescription)")
        }

        aiMatchTask = nil
    }
}
