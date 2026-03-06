import SwiftUI
import Combine

struct MenuBarView: View {
    private var appState: AppState { AppState.shared }
    @Bindable private var timer = TimerStore.shared
    @Bindable private var todos = TodoStore.shared
    @ObservedObject private var tracker = ActivityTracker.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    @State private var currentSessionDuration: String = ""
    @State private var quickAddText: String = ""
    @State private var hoveredTodoId: String?
    @Namespace private var modeNS
    private let sessionTimer = Timer.publish(every: 15, on: .main, in: .common).autoconnect()
    private var theme: AppTheme { AppSettings.shared.appTheme }

    private var phaseColor: Color {
        timer.mode == .pomodoro ? timer.phase.color : theme.accentColor
    }

    var body: some View {
        VStack(spacing: 0) {
            headerSection

            if !appState.categoryStats.isEmpty {
                dayCompositionBar
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
            }

            theme.dividerColor.opacity(0.3)
                .frame(height: 1)

            ScrollView {
                VStack(spacing: 8) {
                    statsRow
                        .padding(.horizontal, 12)
                        .padding(.top, 8)

                    timerSection
                        .padding(.horizontal, 12)

                    if !tracker.currentApp.isEmpty {
                        currentAppRow
                            .padding(.horizontal, 12)
                    }

                    // Separator between timer and todo
                    theme.dividerColor.opacity(0.15)
                        .frame(height: 1)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 2)

                    todoSection
                        .padding(.horizontal, 12)
                }
                .padding(.bottom, 10)
            }

            theme.dividerColor.opacity(0.3)
                .frame(height: 1)

            footerRow
        }
        .background(theme.sidebarBg)
        .frame(width: 360)
        .onReceive(sessionTimer) { _ in updateSessionDuration() }
        .onAppear { updateSessionDuration() }
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    ThemeAwareMenuIcon(size: 13)
                    Text("FlowTrack")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(theme.primaryText)
                }
                HStack(spacing: 5) {
                    Circle()
                        .fill(tracker.isTracking ? theme.successColor : theme.errorColor)
                        .frame(width: 5, height: 5)
                    Text(tracker.isTracking ? "Tracking · \(todayActiveTime)" : "Not tracking")
                        .font(.caption)
                        .foregroundStyle(theme.secondaryText)
                }
            }

            Spacer()

            Button {
                if tracker.isTracking { tracker.stopTracking() } else { tracker.startTracking() }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: tracker.isTracking ? "pause.fill" : "play.fill")
                        .font(.system(size: 9, weight: .bold))
                    Text(tracker.isTracking ? "Pause" : "Start")
                        .font(.caption.weight(.semibold))
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .foregroundStyle(tracker.isTracking ? theme.secondaryText : theme.selectedForeground)
                .background(
                    tracker.isTracking
                        ? theme.secondaryText.opacity(0.12)
                        : theme.accentColor,
                    in: RoundedRectangle(cornerRadius: 6)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }

    // MARK: - Day Composition Bar

    private var dayCompositionBar: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                let total = appState.categoryStats.reduce(0.0) { $0 + $1.totalSeconds }
                ForEach(appState.categoryStats.prefix(6)) { stat in
                    let fraction = total > 0 ? CGFloat(stat.totalSeconds / total) : 0
                    RoundedRectangle(cornerRadius: 0)
                        .fill(Theme.color(for: stat.category))
                        .frame(width: geo.size.width * fraction)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 3))
        }
        .frame(height: 4)
    }

    // MARK: - Stats

    private var statsRow: some View {
        HStack(spacing: 6) {
            StatPill(icon: "brain.head.profile", label: "Focus", value: "\(Int(focusScore))%")
            StatPill(icon: "clock.fill", label: "Active", value: activeTime)
            StatPill(icon: "square.stack.fill", label: "Sessions", value: "\(appState.timeSlots.filter { !$0.isIdle }.count)")
            if appState.streakDays > 0 {
                StatPill(icon: "flame.fill", label: "Streak", value: "\(appState.streakDays)")
            }
        }
    }

    // MARK: - Timer Section

    private var timerSection: some View {
        VStack(spacing: 8) {
            // Mode selector
            HStack(spacing: 0) {
                ForEach(TimerMode.allCases, id: \.self) { mode in
                    Button {
                        guard mode != timer.mode else { return }
                        withAnimation(.easeInOut(duration: 0.18)) { timer.switchMode(mode) }
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: mode.icon).font(.system(size: 9))
                            Text(mode.rawValue)
                        }
                        .font(.caption.weight(timer.mode == mode ? .semibold : .regular))
                        .foregroundStyle(timer.mode == mode ? theme.selectedForeground : theme.secondaryText)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .contentShape(Rectangle())
                        .background {
                            if timer.mode == mode {
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(timer.mode == .pomodoro ? timer.phase.color : theme.accentColor)
                                    .matchedGeometryEffect(id: "modeMenuBg", in: modeNS)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(2)
            .background(theme.dividerColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))

            // Timer display + controls
            HStack(spacing: 10) {
                // Mini progress ring for pomodoro/countdown
                if timer.mode != .stopwatch {
                    ZStack {
                        Circle()
                            .stroke(theme.secondaryText.opacity(0.1), lineWidth: 2.5)
                            .frame(width: 28, height: 28)
                        Circle()
                            .trim(from: 0, to: timer.progress)
                            .stroke(phaseColor, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                            .frame(width: 28, height: 28)
                            .rotationEffect(.degrees(-90))
                            .animation(.linear(duration: 0.8), value: timer.progress)
                    }
                }

                VStack(alignment: .leading, spacing: 3) {
                    // Phase label (Pomodoro) or mode icon
                    if timer.mode == .pomodoro {
                        HStack(spacing: 4) {
                            Text("🍅").font(.caption2)
                            Text(timer.phase.label)
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(timer.phase.color)
                        }
                    }

                    // Time
                    Text(timer.formattedTime)
                        .font(.system(size: 22, weight: .light, design: .monospaced))
                        .foregroundStyle(theme.primaryText)

                    // Pomodoro dots OR today total
                    if timer.mode == .pomodoro && timer.completedPomodoros > 0 {
                        HStack(spacing: 3) {
                            ForEach(0..<min(timer.completedPomodoros, 8), id: \.self) { _ in
                                Circle()
                                    .fill(timer.phase.color)
                                    .frame(width: 4, height: 4)
                            }
                            if timer.completedPomodoros > 8 {
                                Text("+\(timer.completedPomodoros - 8)")
                                    .font(.caption2).foregroundStyle(theme.secondaryText)
                            }
                        }
                    } else {
                        let total = TodoStore.shared.timerSessions
                            .filter { Calendar.current.isDateInToday($0.startedAt) }
                            .reduce(0.0) { $0 + $1.duration }
                        if total >= 60 {
                            Text("Today \(Theme.formatDuration(total))")
                                .font(.caption2)
                                .foregroundStyle(theme.secondaryText)
                        }
                    }
                }

                Spacer()

                HStack(spacing: 6) {
                    Button { timer.reset() } label: {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 10))
                            .frame(width: 26, height: 26)
                            .contentShape(Circle())
                            .background(theme.dividerColor.opacity(0.12), in: Circle())
                            .foregroundStyle(theme.secondaryText)
                    }
                    .buttonStyle(.plain)

                    Button {
                        if timer.isRunning { timer.pause() } else { timer.start() }
                    } label: {
                        Image(systemName: timer.isRunning ? "pause.fill" : "play.fill")
                            .font(.system(size: 12))
                            .frame(width: 36, height: 36)
                            .contentShape(Circle())
                            .foregroundStyle(theme.selectedForeground)
                            .background(
                                phaseColor,
                                in: Circle()
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(10)
            .background(theme.cardBg, in: RoundedRectangle(cornerRadius: 10))

            // Task selector (compact dropdown)
            Menu {
                Button {
                    timer.setTodo(nil)
                } label: {
                    HStack {
                        Text("No task")
                        if timer.selectedTodoId == nil {
                            Image(systemName: "checkmark")
                        }
                    }
                }
                Divider()
                let activeTodos = todos.todos.filter { $0.status != .done }
                ForEach(activeTodos) { todo in
                    Button {
                        timer.setTodo(todo.id)
                    } label: {
                        HStack {
                            Circle()
                                .fill(todo.priority.color)
                                .frame(width: 6, height: 6)
                            Text(todo.title)
                            if timer.selectedTodoId == todo.id {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
                if activeTodos.isEmpty {
                    Text("No active tasks")
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "checklist")
                        .font(.system(size: 9))
                        .foregroundStyle(phaseColor)
                    if let todoId = timer.selectedTodoId,
                       let todo = todos.todos.first(where: { $0.id == todoId }) {
                        Text(todo.title)
                            .font(.caption.weight(.medium))
                            .lineLimit(1)
                            .foregroundStyle(theme.primaryText)
                    } else {
                        Text("No task linked")
                            .font(.caption)
                            .foregroundStyle(theme.secondaryText)
                    }
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 7))
                        .foregroundStyle(theme.secondaryText)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(theme.dividerColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
            }
            .menuStyle(.borderlessButton)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Todo Section

    private var todoSection: some View {
        VStack(spacing: 6) {
            // Header
            HStack {
                HStack(spacing: 4) {
                    Text("Tasks")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(theme.primaryText)
                    let pendingCount = todos.todos.filter { $0.status != .done }.count
                    if pendingCount > 0 {
                        Text("\(pendingCount)")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(theme.selectedForeground)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(theme.accentColor, in: Capsule())
                    }
                }
                Spacer()
                Button {
                    openDashboard()
                } label: {
                    Text("Show All")
                        .font(.caption2)
                        .foregroundStyle(theme.accentColor)
                }
                .buttonStyle(.plain)
            }

            // Quick add
            HStack(spacing: 6) {
                TextField("Add a task…", text: $quickAddText)
                    .font(.caption)
                    .textFieldStyle(.plain)
                    .onSubmit { addQuickTodo() }

                Button {
                    addQuickTodo()
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(quickAddText.trimmingCharacters(in: .whitespaces).isEmpty
                                         ? theme.secondaryText.opacity(0.4) : theme.accentColor)
                }
                .buttonStyle(.plain)
                .disabled(quickAddText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(theme.dividerColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))

            // Top 3 pending/in-progress tasks
            let topTasks = todos.todos.filter { $0.status != .done }.prefix(3)
            if !topTasks.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(topTasks)) { todo in
                        HStack(spacing: 6) {
                            // Toggle circle
                            Button {
                                todos.toggle(todo)
                            } label: {
                                Circle()
                                    .strokeBorder(todo.priority.color, lineWidth: 1.5)
                                    .frame(width: 14, height: 14)
                                    .contentShape(Circle())
                            }
                            .buttonStyle(.plain)

                            // Priority dot
                            Circle()
                                .fill(todo.priority.color)
                                .frame(width: 4, height: 4)

                            // Title
                            Text(todo.title)
                                .font(.caption)
                                .lineLimit(1)
                                .foregroundStyle(theme.primaryText)

                            Spacer()

                            // Timer badge if linked to active timer
                            if timer.isRunning && timer.selectedTodoId == todo.id {
                                HStack(spacing: 2) {
                                    Image(systemName: "timer")
                                        .font(.system(size: 7))
                                    Text(timer.formattedTime)
                                        .font(.system(size: 8, weight: .medium, design: .monospaced))
                                }
                                .foregroundStyle(phaseColor)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 2)
                                .background(phaseColor.opacity(0.12), in: Capsule())
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(
                            hoveredTodoId == todo.id
                                ? theme.dividerColor.opacity(0.08)
                                : Color.clear,
                            in: RoundedRectangle(cornerRadius: 5)
                        )
                        .onHover { isHovered in
                            hoveredTodoId = isHovered ? todo.id : nil
                        }
                    }
                }
                .padding(.vertical, 2)
                .background(theme.cardBg, in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private func addQuickTodo() {
        let trimmed = quickAddText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let newTodo = TodoItem(title: trimmed, priority: .medium)
        todos.add(newTodo)
        quickAddText = ""
    }

    // MARK: - Current App

    private var currentAppRow: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(theme.successColor.opacity(0.8))
                .frame(width: 5, height: 5)
            Text(tracker.currentApp)
                .font(.caption.weight(.medium))
                .lineLimit(1)
                .foregroundStyle(theme.primaryText)
            Spacer()
            if !currentSessionDuration.isEmpty {
                Text(currentSessionDuration)
                    .font(.caption)
                    .foregroundStyle(theme.secondaryText)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(theme.cardBg, in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Footer

    private var footerRow: some View {
        HStack(spacing: 2) {
            Button(action: openDashboard) {
                Image(systemName: "rectangle.grid.1x2")
                    .font(.system(size: 13))
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(theme.secondaryText)
            .help("Open Dashboard (⌘D)")

            SettingsLink {
                Image(systemName: "gear")
                    .font(.system(size: 13))
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(theme.secondaryText)
            .help("Settings (⌘,)")

            Spacer()

            Button {
                UserDefaults.standard.set(true, forKey: "reallyQuit")
                NSApp.terminate(nil)
            } label: {
                Image(systemName: "power")
                    .font(.system(size: 13))
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(theme.errorColor)
            .help("Quit FlowTrack")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
    }

    // MARK: - Helpers

    private func openDashboard() {
        dismiss()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: "dashboard")
        }
    }

    private var focusScore: Double {
        let productive = appState.categoryStats.filter { $0.category.isProductive }.reduce(0) { $0 + $1.totalSeconds }
        let total = appState.categoryStats.reduce(0) { $0 + $1.totalSeconds }
        guard total > 0 else { return 0 }
        return productive / total * 100
    }

    private var activeTime: String {
        let total = appState.timeSlots.filter { !$0.isIdle }.reduce(0.0) { $0 + $1.duration }
        return Theme.formatDuration(total)
    }

    private var todayActiveTime: String {
        let secs = appState.timeSlots.filter { !$0.isIdle }.reduce(0.0) { $0 + $1.duration }
        guard secs >= 60 else { return "just started" }
        return Theme.formatDuration(secs)
    }

    private func updateSessionDuration() {
        let elapsed = Date().timeIntervalSince(tracker.currentAppSince)
        let minutes = Int(elapsed / 60)
        if minutes < 1 {
            currentSessionDuration = ""
        } else if minutes < 60 {
            currentSessionDuration = "\(minutes)m"
        } else {
            let h = minutes / 60; let m = minutes % 60
            currentSessionDuration = m > 0 ? "\(h)h \(m)m" : "\(h)h"
        }
    }
}

// MARK: - StatPill

struct StatPill: View {
    var icon: String = ""
    let label: String
    let value: String
    private var theme: AppTheme { AppSettings.shared.appTheme }

    var body: some View {
        VStack(spacing: 2) {
            HStack(spacing: 3) {
                if !icon.isEmpty {
                    Image(systemName: icon)
                        .font(.system(size: 7))
                        .foregroundStyle(theme.accentColor.opacity(0.7))
                }
                Text(value)
                    .font(.caption.bold())
                    .foregroundStyle(theme.primaryText)
            }
            Text(label)
                .font(.caption2)
                .foregroundStyle(theme.secondaryText)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .background(theme.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - MenuBarLabelView

struct MenuBarLabelView: View {
    @Bindable private var timer = TimerStore.shared
    private var theme: AppTheme { AppSettings.shared.appTheme }

    var body: some View {
        if timer.isRunning {
            HStack(spacing: 3) {
                Image(systemName: "timer")
                    .font(.system(size: 12, weight: .semibold))
                Text(timer.formattedTime)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
            }
            .foregroundStyle(timer.mode == .pomodoro ? timer.phase.color : theme.accentColor)
        } else {
            MenuBarIconView(size: 16)
        }
    }
}
