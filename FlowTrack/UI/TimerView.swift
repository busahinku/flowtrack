import SwiftUI

struct TimerView: View {
    @Bindable private var timer = TimerStore.shared
    @Bindable private var todos = TodoStore.shared
    @State private var showConfig = false
    @State private var showHistory = false
    @Namespace private var modeNS

    private var theme: AppTheme { AppSettings.shared.appTheme }
    private var settings: AppSettings { AppSettings.shared }

    private var phaseColor: Color {
        timer.mode == .pomodoro ? timer.phase.color : theme.accentColor
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                timerCard
                todoSelectorCard
                controlsRow
                if !timer.laps.isEmpty {
                    lapsCard
                }
            }
            .padding(20)
        }
        .background(theme.timelineBg)
        .toolbar {
            ToolbarItem(placement: .principal) {
                modeSelectorBar
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button { showHistory.toggle() } label: {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 13))
                }
                .buttonStyle(.plain)
                .help("Timer history")
                Button { showConfig.toggle() } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 13))
                }
                .buttonStyle(.plain)
                .help("Configure timer")
            }
        }
        .toolbarBackground(.hidden, for: .windowToolbar)
        .sheet(isPresented: $showConfig) { TimerConfigSheet() }
        .sheet(isPresented: $showHistory) { TimerHistorySheet() }
    }

    // MARK: - Mode Selector

    private var modeSelectorBar: some View {
        HStack(spacing: 0) {
            ForEach(TimerMode.allCases, id: \.self) { mode in
                Button {
                    guard mode != timer.mode else { return }
                    withAnimation(.easeInOut(duration: 0.2)) { timer.switchMode(mode) }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: mode.icon).font(.system(size: 10))
                        Text(mode.rawValue)
                            .font(.subheadline.weight(timer.mode == mode ? .semibold : .regular))
                    }
                    .foregroundStyle(timer.mode == mode ? theme.selectedForeground : theme.secondaryText)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                    .background {
                        if timer.mode == mode {
                            RoundedRectangle(cornerRadius: 7)
                                .fill(phaseColor)
                                .matchedGeometryEffect(id: "modeBg", in: modeNS)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(theme.dividerColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
        .frame(width: 300)
    }

    // MARK: - Timer Card

    private var timerCard: some View {
        VStack(spacing: 12) {
            ZStack {
                // Background track
                Circle()
                    .stroke(theme.secondaryText.opacity(0.1), lineWidth: 5)
                    .frame(width: 168, height: 168)

                // Progress ring (pomodoro / countdown only)
                if timer.mode != .stopwatch {
                    Circle()
                        .trim(from: 0, to: timer.progress)
                        .stroke(phaseColor, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                        .frame(width: 168, height: 168)
                        .rotationEffect(.degrees(-90))
                        .animation(.linear(duration: 0.8), value: timer.progress)
                } else {
                    // Stopwatch: full circle in accent color at low opacity
                    Circle()
                        .stroke(phaseColor.opacity(0.2), lineWidth: 5)
                        .frame(width: 168, height: 168)
                }

                // Center content
                VStack(spacing: 4) {
                    if timer.mode == .pomodoro {
                        Text(timer.phase.label.uppercased())
                            .font(.system(size: 9, weight: .semibold, design: .rounded))
                            .foregroundStyle(phaseColor)
                            .tracking(2)
                    }

                    Text(timer.formattedTime)
                        .font(.system(size: 44, weight: .light, design: .monospaced))
                        .foregroundStyle(theme.primaryText)

                    if timer.mode == .pomodoro {
                        HStack(spacing: 4) {
                            ForEach(0..<settings.sessionsBeforeLong, id: \.self) { i in
                                Circle()
                                    .fill(i < timer.completedSessions % settings.sessionsBeforeLong
                                          ? phaseColor : phaseColor.opacity(0.15))
                                    .frame(width: 5, height: 5)
                            }
                        }
                    } else if timer.mode == .countdown {
                        Text(remainingLabel)
                            .font(.system(size: 10, weight: .regular))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .frame(height: 190)

            // Today's total tracked time
            if todayTimerTotal > 0 {
                HStack(spacing: 4) {
                    Image(systemName: "clock.fill")
                        .font(.caption2)
                        .foregroundStyle(theme.secondaryText)
                    Text("Today: \(Theme.formatDuration(todayTimerTotal))")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(theme.secondaryText)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .background(theme.cardBg, in: RoundedRectangle(cornerRadius: 14))
    }

    private var todayTimerTotal: Double {
        TodoStore.shared.timerSessions.filter {
            Calendar.current.isDateInToday($0.startedAt)
        }.reduce(0.0) { $0 + $1.duration }
    }

    private var remainingLabel: String {
        let total = timer.totalSeconds
        guard total > 0 else { return "" }
        let mins = total / 60
        return "\(mins) min"
    }

    // MARK: - Todo Selector Card

    private var todoSelectorCard: some View {
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
            let active = todos.todos.filter { $0.status != .done }
            ForEach(active) { todo in
                if todo.subtasks.isEmpty {
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
                } else {
                    // Parent task with subtasks — show as submenu
                    Menu {
                        Button {
                            timer.setTodo(todo.id)
                        } label: {
                            HStack {
                                Text(todo.title)
                                if timer.selectedTodoId == todo.id {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                        Divider()
                        ForEach(todo.subtasks.filter { $0.status != .done }) { sub in
                            Button {
                                timer.setTodo(sub.id)
                            } label: {
                                HStack {
                                    Text(sub.title)
                                    if timer.selectedTodoId == sub.id {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    } label: {
                        HStack {
                            Circle()
                                .fill(todo.priority.color)
                                .frame(width: 6, height: 6)
                            Text(todo.title)
                            if timer.selectedTodoId == todo.id || todo.subtasks.contains(where: { $0.id == timer.selectedTodoId }) {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            }
            if active.isEmpty {
                Text("No active tasks").foregroundStyle(theme.secondaryText)
            }
        } label: {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(phaseColor.opacity(0.12))
                        .frame(width: 32, height: 32)
                    Image(systemName: "checklist")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(phaseColor)
                }

                if let todoId = timer.selectedTodoId,
                   let resolved = resolvedTodo(for: todoId) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(resolved.title)
                            .font(.subheadline.weight(.medium))
                            .lineLimit(1)
                            .foregroundStyle(theme.primaryText)
                        Text(resolved.isSubtask ? "Subtask" : "Linked task")
                            .font(.caption2)
                            .foregroundStyle(theme.secondaryText)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("No task selected")
                            .font(.subheadline)
                            .foregroundStyle(theme.secondaryText)
                        Text("Link a task to track time")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                Spacer()
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(10)
            .background(theme.cardBg, in: RoundedRectangle(cornerRadius: 12))
            .shadow(color: theme.shadowColor.opacity(0.04), radius: 4, y: 1)
        }
        .menuStyle(.borderlessButton)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Controls

    private var controlsRow: some View {
        HStack(spacing: 20) {
            // Reset
            Button {
                timer.reset()
            } label: {
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 44, height: 44)
                    .foregroundStyle(theme.secondaryText)
                    .background(theme.cardBg, in: Circle())
            }
            .buttonStyle(.plain)

            // Play / Pause
            Button {
                if timer.isRunning { timer.pause() } else { timer.start() }
            } label: {
                ZStack {
                    Circle()
                        .fill(phaseColor)
                        .frame(width: 58, height: 58)

                    Image(systemName: timer.isRunning ? "pause.fill" : "play.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(theme.selectedForeground)
                        .offset(x: timer.isRunning ? 0 : 1.5)
                }
            }
            .buttonStyle(.plain)

            // Skip / Lap
            if timer.mode == .pomodoro {
                Button {
                    skipPhase()
                } label: {
                    Image(systemName: "forward.end.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 44, height: 44)
                        .foregroundStyle(theme.secondaryText)
                        .background(theme.cardBg, in: Circle())
                }
                .buttonStyle(.plain)
                .help("Skip to next phase")
            } else {
                Button {
                    timer.addLap()
                } label: {
                    Image(systemName: "flag.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 44, height: 44)
                        .foregroundStyle(timer.isRunning ? .secondary : .quaternary)
                        .background(theme.cardBg, in: Circle())
                }
                .buttonStyle(.plain)
                .help("Add lap")
                .disabled(!timer.isRunning)
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Laps Card

    private var lapsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "flag.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(phaseColor)
                Text("Laps")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(timer.laps.count)")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(theme.selectedForeground)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(phaseColor.opacity(0.7), in: Capsule())
            }

            VStack(spacing: 0) {
                ForEach(Array(timer.laps.reversed().enumerated()), id: \.element.id) { index, lap in
                    lapRow(lap, isFirst: index == 0)
                    if index < timer.laps.count - 1 {
                        Divider().padding(.leading, 50)
                    }
                }
            }
            .background(theme.cardBg.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
        }
        .padding(14)
        .background(theme.cardBg, in: RoundedRectangle(cornerRadius: 12))
    }

    private func lapRow(_ lap: LapRecord, isFirst: Bool) -> some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(isFirst ? phaseColor.opacity(0.15) : theme.secondaryText.opacity(0.08))
                    .frame(width: 28, height: 28)
                Text("\(lap.index)")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(isFirst ? phaseColor : theme.secondaryText)
            }

            if let todoId = lap.todoId,
               let todo = todos.todos.first(where: { $0.id == todoId }) {
                Text(todo.title)
                    .font(.caption)
                    .foregroundStyle(theme.primaryText)
                    .lineLimit(1)
            } else {
                Text("No task")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            Text(lapDurationString(lap.duration))
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(isFirst ? theme.primaryText : theme.secondaryText)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    // MARK: - Helpers

    private func resolvedTodo(for id: String) -> (title: String, isSubtask: Bool)? {
        if let todo = todos.todos.first(where: { $0.id == id }) {
            return (todo.title, false)
        }
        for parent in todos.todos {
            if let sub = parent.subtasks.first(where: { $0.id == id }) {
                return (sub.title, true)
            }
        }
        return nil
    }

    private func skipPhase() {
        timer.skipPhase()
    }

    private func lapDurationString(_ seconds: TimeInterval) -> String {
        let h = Int(seconds) / 3600
        let m = (Int(seconds) % 3600) / 60
        let s = Int(seconds) % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%02d:%02d", m, s)
    }
}

// MARK: - Config Sheet

struct TimerConfigSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable private var settings = AppSettings.shared
    private var theme: AppTheme { AppSettings.shared.appTheme }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Image(systemName: "slider.horizontal.3")
                    .font(.title2)
                    .foregroundStyle(theme.accentColor)
                Text("Timer Settings")
                    .font(.title2.bold())
            }

            GroupBox {
                VStack(spacing: 12) {
                    stepperRow("Focus duration", value: $settings.sessionWorkMinutes, range: 1...120, unit: "min", icon: "brain", color: theme.infoColor)
                    Divider()
                    stepperRow("Short break", value: $settings.sessionBreakMinutes, range: 1...30, unit: "min", icon: "cup.and.saucer.fill", color: theme.successColor)
                    Divider()
                    stepperRow("Long break", value: $settings.sessionLongBreakMinutes, range: 5...60, unit: "min", icon: "leaf.fill", color: theme.infoColor)
                    Divider()
                    stepperRow("Sessions before long break", value: $settings.sessionsBeforeLong, range: 1...10, unit: "", icon: "repeat", color: theme.warningColor)
                }
                .padding(.vertical, 4)
            } label: {
                Label("Session", systemImage: "timer")
                    .font(.subheadline.weight(.semibold))
            }

            GroupBox {
                stepperRow("Duration", value: $settings.countdownMinutes, range: 1...180, unit: "min", icon: "hourglass", color: theme.accentColor)
                    .padding(.vertical, 4)
            } label: {
                Label("Countdown", systemImage: "hourglass")
                    .font(.subheadline.weight(.semibold))
            }

            GroupBox {
                HStack {
                    Label("Default mode", systemImage: "star.fill")
                        .font(.subheadline)
                        .foregroundStyle(theme.accentColor)
                    Spacer()
                    Picker("", selection: $settings.defaultTimerMode) {
                        ForEach(TimerMode.allCases, id: \.self) { mode in
                            Label(mode.rawValue, systemImage: mode.icon).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 140)
                }
                .padding(.vertical, 4)
            } label: {
                Label("Set in Timer", systemImage: "link")
                    .font(.subheadline.weight(.semibold))
            }

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 400)
    }

    private func stepperRow(_ label: String, value: Binding<Int>, range: ClosedRange<Int>, unit: String, icon: String, color: Color) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundStyle(color)
                .frame(width: 20)
            Text(label)
                .font(.subheadline)
            Spacer()
            Stepper(unit.isEmpty ? "\(value.wrappedValue)" : "\(value.wrappedValue) \(unit)",
                    value: value, in: range)
                .fixedSize()
        }
    }
}

// MARK: - History Sheet

struct TimerHistorySheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var showClearConfirm = false
    private var store: TodoStore { TodoStore.shared }
    private var theme: AppTheme { AppSettings.shared.appTheme }

    private var sortedSessions: [TimerSession] {
        store.timerSessions.sorted { $0.startedAt > $1.startedAt }
    }

    private var groupedSessions: [(String, [TimerSession])] {
        let sorted = sortedSessions
        var seen = Set<String>()
        var orderedKeys: [String] = []
        for session in sorted {
            let key = dateKey(for: session.startedAt)
            if seen.insert(key).inserted { orderedKeys.append(key) }
        }
        let grouped = Dictionary(grouping: sorted) { dateKey(for: $0.startedAt) }
        return orderedKeys.compactMap { key in
            guard let items = grouped[key] else { return nil }
            return (key, items)
        }
    }

    private var totalDuration: TimeInterval {
        store.timerSessions.reduce(0) { $0 + $1.duration }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.title2)
                    .foregroundStyle(theme.accentColor)
                Text("Timer History")
                    .font(.title2.bold())
                Spacer()
                if !sortedSessions.isEmpty {
                    Button(role: .destructive) {
                        showClearConfirm = true
                    } label: {
                        Label("Clear All", systemImage: "trash")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(theme.errorColor)
                    .confirmationDialog("Clear all timer sessions?", isPresented: $showClearConfirm) {
                        Button("Clear All Sessions", role: .destructive) {
                            store.clearTimerSessions()
                        }
                    } message: {
                        Text("This will permanently delete all \(store.timerSessions.count) session(s).")
                    }
                }
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding()

            if sortedSessions.isEmpty {
                VStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(theme.accentColor.opacity(0.08))
                            .frame(width: 72, height: 72)
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 30))
                            .foregroundStyle(theme.accentColor.opacity(0.4))
                    }
                    Text("No sessions yet")
                        .font(.title3.bold())
                    Text("Start a timer to see history here")
                        .font(.subheadline)
                        .foregroundStyle(theme.secondaryText)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // Summary bar
                HStack(spacing: 16) {
                    summaryPill(icon: "number", label: "\(store.timerSessions.count) sessions")
                    summaryPill(icon: "clock.fill", label: "Total: \(durationString(totalDuration))")
                }
                .padding(.horizontal)
                .padding(.bottom, 8)

                List {
                    ForEach(groupedSessions, id: \.0) { (dateLabel, items) in
                        Section(dateLabel) {
                            ForEach(items) { session in
                                sessionRow(session)
                                    .swipeActions(edge: .trailing) {
                                        Button(role: .destructive) {
                                            store.deleteTimerSession(session.id)
                                        } label: {
                                            Label("Delete", systemImage: "trash")
                                        }
                                    }
                            }
                        }
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }
        }
        .frame(width: 440, height: 520)
    }

    private func summaryPill(icon: String, label: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 9))
                .foregroundStyle(theme.accentColor)
            Text(label)
                .font(.caption2.weight(.medium))
                .foregroundStyle(theme.secondaryText)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(theme.cardBg, in: Capsule())
    }

    private func sessionRow(_ session: TimerSession) -> some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(modeColor(session.mode).opacity(0.12))
                    .frame(width: 32, height: 32)
                Image(systemName: session.mode.icon)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(modeColor(session.mode))
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(sessionTitle(session))
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Text(timeRange(for: session))
                    .font(.caption2)
                    .foregroundStyle(theme.secondaryText)
            }

            Spacer()

            Text(durationString(session.duration))
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(theme.secondaryText)
        }
        .padding(.vertical, 2)
    }

    private func modeColor(_ mode: TimerMode) -> Color {
        switch mode {
        case .pomodoro: AppSettings.shared.appTheme.infoColor
        case .countdown: AppSettings.shared.appTheme.accentColor
        case .stopwatch: AppSettings.shared.appTheme.warningColor
        }
    }

    private func sessionTitle(_ session: TimerSession) -> String {
        if let todoId = session.todoId {
            // Check top-level todos
            if let todo = store.todos.first(where: { $0.id == todoId }) {
                return todo.title
            }
            // Check subtasks
            for parent in store.todos {
                if let sub = parent.subtasks.first(where: { $0.id == todoId }) {
                    return sub.title
                }
            }
        }
        return session.mode.rawValue
    }

    private func dateKey(for date: Date) -> String {
        if Calendar.current.isDateInToday(date) { return "Today" }
        if Calendar.current.isDateInYesterday(date) { return "Yesterday" }
        let fmt = DateFormatter()
        fmt.dateFormat = "MMM d"
        return fmt.string(from: date)
    }

    private func timeRange(for session: TimerSession) -> String {
        let fmt = DateFormatter()
        fmt.timeStyle = .short
        fmt.dateStyle = .none
        return "\(fmt.string(from: session.startedAt)) – \(fmt.string(from: session.endedAt))"
    }

    private func durationString(_ seconds: TimeInterval) -> String {
        let h = Int(seconds) / 3600
        let m = (Int(seconds) % 3600) / 60
        let s = Int(seconds) % 60
        if h > 0 { return "\(h)h \(m)m" }
        if m > 0 { return "\(m)m \(s)s" }
        return "\(s)s"
    }
}
