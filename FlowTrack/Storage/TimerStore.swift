import Foundation
import AppKit

// MARK: - TimerStore
@MainActor @Observable
final class TimerStore {
    static let shared = TimerStore()

    var mode: TimerMode = .pomodoro
    var phase: PomodoroPhase = .work
    var isRunning = false
    var elapsedSeconds: Int = 0          // used for stopwatch (counts up)
    var remainingSeconds: Int = 0        // used for pomodoro / countdown (counts down)
    var completedPomodoros: Int = 0      // work sessions completed today
    var selectedTodoId: String?
    var laps: [LapRecord] = []
    var lapStartTime: Date?

    private var timerTask: Task<Void, Never>?
    private var sessionStart: Date?
    private var settings: AppSettings { AppSettings.shared }
    /// ID of the todo that was auto-set to .inProgress when the timer started
    private var autoActivatedTodoId: String? = nil

    private init() {
        let s = AppSettings.shared
        self.mode = s.defaultTimerMode
        switch s.defaultTimerMode {
        case .pomodoro:  remainingSeconds = s.pomodoroWorkMinutes * 60
        case .countdown: remainingSeconds = s.countdownMinutes * 60
        case .stopwatch: remainingSeconds = 0
        }
    }

    // MARK: - Computed

    var displaySeconds: Int {
        switch mode {
        case .stopwatch: return elapsedSeconds
        case .countdown, .pomodoro: return remainingSeconds
        }
    }

    var totalSeconds: Int {
        switch mode {
        case .stopwatch: return 0  // unbounded
        case .countdown: return settings.countdownMinutes * 60
        case .pomodoro:
            switch phase {
            case .work:       return settings.pomodoroWorkMinutes * 60
            case .shortBreak: return settings.pomodoroBreakMinutes * 60
            case .longBreak:  return settings.pomodoroLongBreakMinutes * 60
            }
        }
    }

    var progress: Double {
        guard mode != .stopwatch, totalSeconds > 0 else { return 0 }
        return Double(totalSeconds - remainingSeconds) / Double(totalSeconds)
    }

    var formattedTime: String {
        let s = displaySeconds
        let h = s / 3600
        let m = (s % 3600) / 60
        let sec = s % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, sec) }
        return String(format: "%02d:%02d", m, sec)
    }

    var currentLapSeconds: Int {
        guard let start = lapStartTime else { return 0 }
        return Int(Date().timeIntervalSince(start))
    }

    var menuBarTitle: String {
        isRunning ? "⏱ \(formattedTime)" : ""
    }

    // MARK: - Todo selection (use this for auto-lap on task change)

    func setTodo(_ id: String?) {
        guard id != selectedTodoId else { return }
        if isRunning { addLap(); revertAutoActivated() }
        selectedTodoId = id
    }

    // MARK: - Laps

    func addLap() {
        guard let start = lapStartTime else { return }
        let now = Date()
        let lap = LapRecord(
            index: laps.count + 1,
            duration: now.timeIntervalSince(start),
            startedAt: start,
            endedAt: now,
            todoId: selectedTodoId
        )
        laps.append(lap)
        lapStartTime = now
    }

    // MARK: - Controls

    func start() {
        guard !isRunning else { return }
        isRunning = true
        sessionStart = Date()
        lapStartTime = Date()
        // Auto-activate linked todo if it's pending
        if let id = selectedTodoId,
           let todo = TodoStore.shared.todos.first(where: { $0.id == id }),
           todo.status == .pending {
            autoActivatedTodoId = id
            TodoStore.shared.setStatus(.inProgress, for: id)
        }
        timerTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                tick()
            }
        }
    }

    func pause() {
        isRunning = false
        timerTask?.cancel()
        timerTask = nil
        // Save partial session if meaningful (≥5 seconds)
        if let start = sessionStart {
            let duration = Date().timeIntervalSince(start)
            if duration >= 5 {
                saveSession(duration: duration)
            }
        }
        sessionStart = nil
        revertAutoActivated()
    }

    func reset() {
        pause()
        elapsedSeconds = 0
        remainingSeconds = initialRemaining()
        if mode == .pomodoro { phase = .work }
        laps = []
        lapStartTime = nil
    }

    /// Skip the current Pomodoro phase without saving a session or reverting the linked todo.
    func skipPhase() {
        guard mode == .pomodoro else { return }
        timerTask?.cancel()
        timerTask = nil
        isRunning = false
        sessionStart = nil
        if phase == .work {
            completedPomodoros += 1
            phase = completedPomodoros % settings.pomodoroSessionsBeforeLong == 0 ? .longBreak : .shortBreak
        } else {
            phase = .work
        }
        remainingSeconds = initialRemaining()
    }

    func switchMode(_ newMode: TimerMode) {        if isRunning { pause() }
        mode = newMode
        phase = .work
        elapsedSeconds = 0
        remainingSeconds = initialRemaining()
        completedPomodoros = 0
        laps = []
        lapStartTime = nil
    }

    // MARK: - Private

    private func revertAutoActivated() {
        guard let id = autoActivatedTodoId else { return }
        autoActivatedTodoId = nil
        // Only revert if still inProgress (user may have manually changed it)
        if let todo = TodoStore.shared.todos.first(where: { $0.id == id }),
           todo.status == .inProgress {
            TodoStore.shared.setStatus(.pending, for: id)
        }
    }

    private func tick() {
        switch mode {
        case .stopwatch:
            elapsedSeconds += 1

        case .countdown:
            if remainingSeconds > 0 {
                remainingSeconds -= 1
            } else {
                // Countdown finished
                let duration = Double(settings.countdownMinutes * 60)
                saveSession(duration: duration)
                sessionStart = nil
                isRunning = false
                timerTask?.cancel()
                timerTask = nil
                revertAutoActivated()
                NSSound.beep()
            }

        case .pomodoro:
            if remainingSeconds > 0 {
                remainingSeconds -= 1
            } else {
                // Phase finished
                if phase == .work {
                    completedPomodoros += 1
                    let workDuration = Double(settings.pomodoroWorkMinutes * 60)
                    saveSession(duration: workDuration)
                    sessionStart = Date()
                    // Advance phase
                    if completedPomodoros % settings.pomodoroSessionsBeforeLong == 0 {
                        phase = .longBreak
                    } else {
                        phase = .shortBreak
                    }
                } else {
                    phase = .work
                    // Reset session start so next work session records the correct startedAt
                    sessionStart = Date()
                }
                remainingSeconds = initialRemaining()
                NSSound.beep()
            }
        }
    }

    private func initialRemaining() -> Int {
        switch mode {
        case .stopwatch: return 0
        case .countdown: return settings.countdownMinutes * 60
        case .pomodoro:
            switch phase {
            case .work:       return settings.pomodoroWorkMinutes * 60
            case .shortBreak: return settings.pomodoroBreakMinutes * 60
            case .longBreak:  return settings.pomodoroLongBreakMinutes * 60
            }
        }
    }

    private func saveSession(duration: TimeInterval) {
        let session = TimerSession(
            todoId: selectedTodoId,
            mode: mode,
            duration: duration,
            startedAt: sessionStart ?? Date().addingTimeInterval(-duration),
            endedAt: Date()
        )
        TodoStore.shared.saveTimerSession(session)

        // Save to main activities DB for timeline/stats integration
        let todoTitle: String
        if let tid = selectedTodoId, let todo = TodoStore.shared.todos.first(where: { $0.id == tid }) {
            todoTitle = todo.title
        } else {
            todoTitle = mode.rawValue
        }
        let record = ActivityRecord(
            timestamp: session.startedAt,
            appName: "FlowTrack Timer",
            bundleID: "com.flowtrack.timer",
            windowTitle: todoTitle,
            url: nil,
            category: Category("Work"),
            isIdle: false,
            duration: session.duration,
            contentMetadata: nil
        )
        Task(priority: .utility) { try? Database.shared.saveActivity(record) }
    }
}
