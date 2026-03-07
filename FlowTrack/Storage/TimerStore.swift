import Foundation
import AppKit
import UserNotifications
import OSLog

private let timerLog = Logger(subsystem: "com.flowtrack", category: "TimerStore")

// MARK: - TimerStore
@MainActor @Observable
final class TimerStore {
    static let shared = TimerStore()

    var mode: TimerMode = .pomodoro
    var phase: SessionPhase = .work
    var isRunning = false
    var elapsedSeconds: Int = 0          // used for stopwatch (counts up)
    var remainingSeconds: Int = 0        // used for session / countdown (counts down)
    var completedSessions: Int = 0       // work sessions completed today
    var selectedTodoId: String?
    var laps: [LapRecord] = []
    var lapStartTime: Date?

    private var timerTask: Task<Void, Never>?
    private var sessionStart: Date?
    private var settings: AppSettings { AppSettings.shared }
    /// ID of the todo that was auto-set to .inProgress when the timer started
    private var autoActivatedTodoId: String? = nil
    /// Milestone thresholds (seconds) already notified in the current stopwatch session
    private var firedMilestones: Set<Int> = []
    /// Focus milestones: 30 min, 1 hr, 2 hr, 3 hr, 5 hr
    private let focusMilestones = [1800, 3600, 7200, 10800, 18000]

    private init() {
        let s = AppSettings.shared
        self.mode = s.defaultTimerMode
        switch s.defaultTimerMode {
        case .pomodoro:  remainingSeconds = s.sessionWorkMinutes * 60
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
            case .work:       return settings.sessionWorkMinutes * 60
            case .shortBreak: return settings.sessionBreakMinutes * 60
            case .longBreak:  return settings.sessionLongBreakMinutes * 60
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
            // Use wall-clock anchoring to eliminate cumulative drift.
            // Each wake calculates how many ticks have actually elapsed since start.
            let anchor = Date()
            var lastTickCount = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { break }
                // How many full seconds have elapsed since anchor?
                let elapsed = Int(Date().timeIntervalSince(anchor))
                let ticksNeeded = elapsed - lastTickCount
                // Normally 1, but catch up if OS delayed wakeup (e.g. App Nap, Doze)
                for _ in 0..<max(1, min(ticksNeeded, 3)) { tick() }
                lastTickCount = elapsed
            }
        }
    }

    func pause() {
        isRunning = false
        timerTask?.cancel()
        timerTask = nil
        firedMilestones.removeAll()
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
        firedMilestones.removeAll()
        laps = []
        lapStartTime = nil
    }

    /// Skip the current session phase without saving a session or reverting the linked todo.
    func skipPhase() {
        guard mode == .pomodoro else { return }
        timerTask?.cancel()
        timerTask = nil
        isRunning = false
        sessionStart = nil
        if phase == .work {
            completedSessions += 1
            phase = completedSessions % settings.sessionsBeforeLong == 0 ? .longBreak : .shortBreak
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
        completedSessions = 0
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
            checkFocusMilestone(elapsedSeconds: elapsedSeconds)

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
                    completedSessions += 1
                    let workDuration = Double(settings.sessionWorkMinutes * 60)
                    saveSession(duration: workDuration)
                    AchievementEngine.shared.checkSessionAchievement(completedToday: completedSessions)
                    sessionStart = Date()
                    // Advance phase
                    if completedSessions % settings.sessionsBeforeLong == 0 {
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
            case .work:       return settings.sessionWorkMinutes * 60
            case .shortBreak: return settings.sessionBreakMinutes * 60
            case .longBreak:  return settings.sessionLongBreakMinutes * 60
            }
        }
    }

    private func saveSession(duration: TimeInterval) {
        let startedAt = sessionStart ?? Date().addingTimeInterval(-duration)
        let session = TimerSession(
            todoId: selectedTodoId,
            mode: mode,
            duration: duration,
            startedAt: startedAt,
            endedAt: Date()
        )
        TodoStore.shared.saveTimerSession(session)
        AchievementEngine.shared.checkSessionAchievements(duration: duration, startedAt: startedAt)

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

    // MARK: - Focus Milestone Notifications

    private func checkFocusMilestone(elapsedSeconds: Int) {
        for milestone in focusMilestones {
            guard elapsedSeconds >= milestone, !firedMilestones.contains(milestone) else { continue }
            firedMilestones.insert(milestone)
            fireMilestoneNotification(seconds: milestone)
            break   // fire one milestone at a time
        }
    }

    private func fireMilestoneNotification(seconds: Int) {
        let milestoneMessages: [Int: (title: String, body: String)] = [
            1800:  ("30 Minutes! 🔥",              "You're warming up nicely. Keep the focus going!"),
            3600:  ("1 Hour of Focus! 💪",          "You're in the zone. Incredible concentration!"),
            7200:  ("2 Hours Deep Work! 🎯",        "This is extraordinary focus. You're absolutely crushing it!"),
            10800: ("3 Hours! You're a Legend 🏆",  "Incredible dedication. Time for a well-earned break soon?"),
            18000: ("5 Hours! 🌟",                  "Absolutely extraordinary. You are an inspiration!")
        ]
        let msg = milestoneMessages[seconds] ?? ("Keep Going! 🚀", "You've been focusing for \(seconds / 60) minutes!")
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = msg.title
            content.body  = msg.body
            content.sound = .default
            let req = UNNotificationRequest(
                identifier: "milestone-\(seconds)-\(Int(Date().timeIntervalSince1970))",
                content: content,
                trigger: nil
            )
            UNUserNotificationCenter.current().add(req)
        }
    }
}
