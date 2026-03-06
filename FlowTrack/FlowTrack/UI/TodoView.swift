import SwiftUI

// MARK: - Due Section

private enum DueSection: String {
    case overdue   = "Overdue"
    case today     = "Today"
    case tomorrow  = "Tomorrow"
    case thisWeek  = "This Week"
    case later     = "Later"
    case someday   = "No Due Date"
    case completed = "Completed"

    var icon: String {
        switch self {
        case .overdue:          "exclamationmark.circle.fill"
        case .today:            "sun.max.fill"
        case .tomorrow:         "sunrise.fill"
        case .thisWeek:         "calendar.badge.clock"
        case .later:            "calendar"
        case .someday:          "tray.fill"
        case .completed:        "checkmark.circle.fill"
        }
    }

    var color: Color {
        let t = AppSettings.shared.appTheme
        switch self {
        case .overdue:          return t.errorColor
        case .today:            return t.infoColor
        case .tomorrow:         return t.warningColor
        case .thisWeek:         return t.infoColor
        case .later, .someday:  return t.secondaryText
        case .completed:        return t.successColor
        }
    }
}

// MARK: - TodoView

struct TodoView: View {
    @Bindable private var store = TodoStore.shared
    @Bindable private var timerStore = TimerStore.shared
    @State private var showAdd = false
    @State private var editingTodo: TodoItem?
    @State private var filterStatus: TodoStatus? = nil
    @State private var showBreakdownFor: TodoItem?
    @State private var selectedDate = Date()
    @State private var showDatePicker = false
    @State private var searchText = ""
    @State private var collapsedSections: Set<String> = ["Completed"]
    @Namespace private var filterNS

    private var theme: AppTheme { AppSettings.shared.appTheme }

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            todoHeader
            todoList
        }
        .background(theme.timelineBg)
        .sheet(isPresented: $showAdd) {
            TodoEditSheet(todo: nil, defaultDueDate: isFutureDate ? selectedDate : nil)
        }
        .sheet(item: $editingTodo) { todo in
            TodoEditSheet(todo: todo)
        }
        .toolbar {
            ToolbarItem(placement: .principal) { todoDateNav }
            ToolbarItem(placement: .primaryAction) {
                Button { showAdd = true } label: {
                    Label("New Task", systemImage: "plus")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(theme.selectedForeground)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(theme.accentColor, in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .help("Add task (⌘N)")
                .keyboardShortcut("n", modifiers: .command)
            }
        }
        .toolbarBackground(.hidden, for: .windowToolbar)
    }

    // MARK: - Search Bar

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.tertiary)
                .font(.system(size: 12))
            TextField("Search tasks…", text: $searchText)
                .textFieldStyle(.plain)
                .font(.subheadline)
            if !searchText.isEmpty {
                Button { searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                        .font(.system(size: 13))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(theme.dividerColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 2)
    }

    // MARK: - Date Nav

    private var todoDateNav: some View {
        HStack(spacing: 2) {
            Button {
                selectedDate = Calendar.current.date(byAdding: .day, value: -1, to: selectedDate) ?? selectedDate
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(theme.secondaryText)

            Button { showDatePicker.toggle() } label: {
                HStack(spacing: 5) {
                    Text(dateLabelString).font(.headline)
                    if isFutureDate {
                        Image(systemName: "calendar.badge.plus")
                            .font(.system(size: 10))
                            .foregroundStyle(theme.accentColor)
                    }
                }
                .frame(minWidth: 90)
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showDatePicker) {
                DatePicker("", selection: $selectedDate, displayedComponents: .date)
                    .labelsHidden()
                    .datePickerStyle(.graphical)
                    .padding(8)
                    .frame(width: 300, height: 320)
            }

            Button {
                selectedDate = Calendar.current.date(byAdding: .day, value: 1, to: selectedDate) ?? selectedDate
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(theme.secondaryText)
        }
    }

    private var dateLabelString: String {
        let cal = Calendar.current
        if cal.isDateInToday(selectedDate) { return "Today" }
        if cal.isDateInYesterday(selectedDate) { return "Yesterday" }
        let tomorrow = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: Date()))!
        if cal.isDate(selectedDate, inSameDayAs: tomorrow) { return "Tomorrow" }
        let fmt = DateFormatter()
        fmt.dateFormat = "MMM d"
        return fmt.string(from: selectedDate)
    }

    // MARK: - Header / Filters

    private var todoHeader: some View {
        HStack(spacing: 12) {
            HStack(spacing: 0) {
                filterButton(nil,       label: "All",    icon: "tray.full.fill")
                filterButton(.pending,  label: "To Do",  icon: "circle")
                filterButton(.inProgress, label: "Active", icon: "play.circle.fill")
                filterButton(.done,     label: "Done",   icon: "checkmark.circle.fill")
            }
            .padding(3)
            .background(theme.dividerColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))

            Spacer()

            if isViewingToday && !store.todos.isEmpty {
                let undone = store.todos.filter { $0.status != .done }.count
                let done   = store.todos.filter { $0.status == .done }.count
                let total  = store.todos.count
                HStack(spacing: 8) {
                    if undone == 0 {
                        Text("All done!")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(theme.successColor)
                    } else {
                        Text("\(undone) left")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(theme.secondaryText)
                    }
                    CircularProgress(
                        progress: total > 0 ? Double(done) / Double(total) : 0,
                        color: done == total ? theme.successColor : theme.accentColor,
                        size: 20
                    )
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func filterButton(_ status: TodoStatus?, label: String, icon: String) -> some View {
        let isSelected = filterStatus == status
        return Button {
            withAnimation(.easeInOut(duration: 0.15)) { filterStatus = status }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 10))
                Text(label)
            }
            .font(.subheadline.weight(isSelected ? .semibold : .regular))
            .foregroundStyle(isSelected ? theme.selectedForeground : theme.secondaryText)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 7)
                        .fill(theme.accentColor)
                        .matchedGeometryEffect(id: "filterBg", in: filterNS)
                }
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Computed State

    private var isViewingToday: Bool { Calendar.current.isDateInToday(selectedDate) }
    private var isFutureDate: Bool {
        Calendar.current.startOfDay(for: selectedDate) > Calendar.current.startOfDay(for: Date())
    }

    // MARK: - Main List Router

    private var todoList: some View {
        Group {
            if isViewingToday {
                todayGroupedList
            } else if isFutureDate {
                futureDateList
            } else {
                pastDateList
            }
        }
    }

    // MARK: - Today: Grouped Sections

    private struct SectionGroup: Identifiable {
        var id: String { section.rawValue }
        let section: DueSection
        let tasks: [TodoItem]
    }

    private func makeTodayGroups() -> [SectionGroup] {
        let cal         = Calendar.current
        let today       = cal.startOfDay(for: Date())
        let tomorrowStart = cal.date(byAdding: .day, value: 1, to: today)!
        let nextWeekStart = cal.date(byAdding: .day, value: 7, to: today)!

        var all = store.todos
        if let filter = filterStatus { all = all.filter { $0.status == filter } }
        if !searchText.isEmpty {
            all = all.filter {
                $0.title.localizedCaseInsensitiveContains(searchText) ||
                $0.notes.localizedCaseInsensitiveContains(searchText)
            }
        }

        var overdue:    [TodoItem] = []
        var todayT:     [TodoItem] = []
        var tomorrowT:  [TodoItem] = []
        var thisWeekT:  [TodoItem] = []
        var laterT:     [TodoItem] = []
        var somedayT:   [TodoItem] = []
        var completedT: [TodoItem] = []

        for task in all {
            if task.status == .done { completedT.append(task); continue }
            if let due = task.dueDate {
                let dueDay = cal.startOfDay(for: due)
                if      dueDay < today                                  { overdue.append(task) }
                else if cal.isDate(dueDay, inSameDayAs: today)          { todayT.append(task) }
                else if cal.isDate(dueDay, inSameDayAs: tomorrowStart)  { tomorrowT.append(task) }
                else if dueDay < nextWeekStart                          { thisWeekT.append(task) }
                else                                                    { laterT.append(task) }
            } else {
                somedayT.append(task)
            }
        }

        let byPriority: (TodoItem, TodoItem) -> Bool = { $0.priority.rawValue > $1.priority.rawValue }
        return [
            SectionGroup(section: .overdue,   tasks: overdue.sorted(by: byPriority)),
            SectionGroup(section: .today,     tasks: todayT.sorted(by: byPriority)),
            SectionGroup(section: .tomorrow,  tasks: tomorrowT.sorted(by: byPriority)),
            SectionGroup(section: .thisWeek,  tasks: thisWeekT.sorted(by: byPriority)),
            SectionGroup(section: .later,     tasks: laterT.sorted(by: byPriority)),
            SectionGroup(section: .someday,   tasks: somedayT.sorted(by: byPriority)),
            SectionGroup(section: .completed, tasks: completedT),
        ]
    }

    private var todayGroupedList: some View {
        let groups  = makeTodayGroups()
        let hasAny  = groups.contains { !$0.tasks.isEmpty }
        return Group {
            if !hasAny {
                emptyStateView
            } else {
                List {
                    ForEach(groups) { group in
                        if !group.tasks.isEmpty {
                            sectionHeaderRow(group)
                                .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 4, trailing: 16))
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)

                            if !collapsedSections.contains(group.id) {
                                ForEach(group.tasks) { todo in
                                    todoRowItem(todo, trackedTime: store.trackedTime(for: todo.id))
                                }
                            }
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
    }

    private func sectionHeaderRow(_ group: SectionGroup) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                if collapsedSections.contains(group.id) {
                    collapsedSections.remove(group.id)
                } else {
                    collapsedSections.insert(group.id)
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: group.section.icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(group.section.color)
                Text(group.section.rawValue.uppercased())
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(theme.secondaryText)
                    .tracking(0.5)
                Text("\(group.tasks.count)")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(theme.selectedForeground)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(group.section.color.opacity(0.75), in: Capsule())
                Spacer()
                Image(systemName: collapsedSections.contains(group.id) ? "chevron.right" : "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .buttonStyle(.plain)
    }

    private func todoRowItem(_ todo: TodoItem, trackedTime: TimeInterval) -> some View {
        TodoRowView(
            todo: todo,
            trackedTime: trackedTime,
            isBreakingDown: store.isBreakingDown && showBreakdownFor?.id == todo.id,
            isTimerActive: timerStore.selectedTodoId == todo.id && timerStore.isRunning,
            onToggle:    { store.toggle(todo) },
            onEdit:      { editingTodo = todo },
            onDelete:    { store.delete(todo) },
            onBreakdown: {
                showBreakdownFor = todo
                Task { await store.breakdown(todo: todo) }
            },
            onSetTimer:  {
                let defaultMode = AppSettings.shared.defaultTimerMode
                if timerStore.mode != defaultMode { timerStore.switchMode(defaultMode) }
                timerStore.setTodo(todo.id)
                AppState.shared.requestedTab = .timer
            }
        )
        .listRowInsets(EdgeInsets(top: 3, leading: 12, bottom: 3, trailing: 12))
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }

    // MARK: - Future Date List

    private var futureDateList: some View {
        let tasks = store.todos.filter { todo in
            guard let due = todo.dueDate else { return false }
            return Calendar.current.isDate(due, inSameDayAs: selectedDate)
        }
        let filtered = applyFilter(tasks)
        return Group {
            if filtered.isEmpty {
                futureDateEmpty
            } else {
                List {
                    futureSummaryRow(count: filtered.count)
                        .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                    ForEach(filtered) { todo in
                        todoRowItem(todo, trackedTime: 0)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
    }

    private var futureDateEmpty: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(theme.accentColor.opacity(0.08))
                    .frame(width: 80, height: 80)
                Image(systemName: "calendar.badge.plus")
                    .font(.system(size: 32))
                    .foregroundStyle(theme.accentColor.opacity(0.4))
            }
            Text("Nothing scheduled for \(dateLabelString)")
                .font(.title3.bold())
                .multilineTextAlignment(.center)
            Text("Schedule a task with this date as its due date")
                .font(.subheadline)
                .foregroundStyle(theme.secondaryText)
                .multilineTextAlignment(.center)
            Button { showAdd = true } label: {
                Label("Schedule Task", systemImage: "calendar.badge.plus")
                    .font(.subheadline.weight(.medium))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(theme.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                    .foregroundStyle(theme.accentColor)
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func futureSummaryRow(count: Int) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "calendar.badge.clock")
                .font(.caption)
                .foregroundStyle(theme.accentColor)
            Text("\(count) task\(count == 1 ? "" : "s") scheduled for \(dateLabelString)")
                .font(.subheadline.weight(.semibold))
            Spacer()
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 12)
        .background(theme.cardBg, in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Past Date List

    private var pastDateList: some View {
        let sessionsOnDate = store.timerSessions.filter {
            Calendar.current.isDate($0.startedAt, inSameDayAs: selectedDate)
        }
        let todoIds = Set(sessionsOnDate.compactMap { $0.todoId })
        let tasks   = applyFilter(store.todos.filter { todoIds.contains($0.id) })
        return Group {
            if tasks.isEmpty {
                pastDateEmpty
            } else {
                List {
                    pastSummaryRow(sessions: sessionsOnDate, count: tasks.count)
                        .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                    ForEach(tasks) { todo in
                        let sessionTime = sessionsOnDate
                            .filter { $0.todoId == todo.id }
                            .reduce(0.0) { $0 + $1.duration }
                        TodoRowView(
                            todo: todo,
                            trackedTime: sessionTime,
                            isBreakingDown: false,
                            isTimerActive: false,
                            onToggle:    { store.toggle(todo) },
                            onEdit:      { editingTodo = todo },
                            onDelete:    { store.delete(todo) },
                            onBreakdown: {},
                            onSetTimer:  {}
                        )
                        .listRowInsets(EdgeInsets(top: 3, leading: 12, bottom: 3, trailing: 12))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
    }

    private var pastDateEmpty: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(theme.accentColor.opacity(0.08))
                    .frame(width: 80, height: 80)
                Image(systemName: "clock.badge.xmark")
                    .font(.system(size: 32))
                    .foregroundStyle(theme.accentColor.opacity(0.4))
            }
            Text("No tracked tasks")
                .font(.title3.bold())
            Text("No timer sessions were recorded on this day")
                .font(.subheadline)
                .foregroundStyle(theme.secondaryText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 260)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func pastSummaryRow(sessions: [TimerSession], count: Int) -> some View {
        let totalTime = sessions.reduce(0.0) { $0 + $1.duration }
        return HStack(spacing: 8) {
            Image(systemName: "calendar")
                .font(.caption)
                .foregroundStyle(theme.accentColor)
            Text("\(count) task\(count == 1 ? "" : "s")")
                .font(.subheadline.weight(.semibold))
            Text("·").foregroundStyle(theme.secondaryText)
            Text(totalTime >= 60 ? "\(Theme.formatDuration(totalTime)) tracked" : "No time tracked")
                .font(.subheadline)
                .foregroundStyle(theme.secondaryText)
            Spacer()
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 12)
        .background(theme.cardBg, in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Empty State (Today)

    private var emptyStateView: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(theme.accentColor.opacity(0.08))
                    .frame(width: 80, height: 80)
                Image(systemName: !searchText.isEmpty
                      ? "magnifyingglass"
                      : (filterStatus == nil ? "checklist" : filterStatus!.emptyIcon))
                    .font(.system(size: 32))
                    .foregroundStyle(theme.accentColor.opacity(0.4))
            }
            Text(!searchText.isEmpty
                 ? "No results"
                 : (filterStatus == nil ? "No tasks yet" : "No \(filterStatus!.label.lowercased()) tasks"))
                .font(.title3.bold())
            Text(!searchText.isEmpty
                 ? "Try a different search term"
                 : (filterStatus == nil ? "Tap + to add your first task" : "Tasks will appear here when status matches"))
                .font(.subheadline)
                .foregroundStyle(theme.secondaryText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 260)
            if filterStatus == nil && searchText.isEmpty {
                Button { showAdd = true } label: {
                    Label("Add Task", systemImage: "plus.circle.fill")
                        .font(.subheadline.weight(.medium))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(theme.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                        .foregroundStyle(theme.accentColor)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Helpers

    private func applyFilter(_ todos: [TodoItem]) -> [TodoItem] {
        var result = todos
        if let filter = filterStatus { result = result.filter { $0.status == filter } }
        if !searchText.isEmpty {
            result = result.filter {
                $0.title.localizedCaseInsensitiveContains(searchText) ||
                $0.notes.localizedCaseInsensitiveContains(searchText)
            }
        }
        return result
    }
}

// MARK: - Circular Progress

private struct CircularProgress: View {
    let progress: Double
    let color: Color
    let size: CGFloat

    var body: some View {
        ZStack {
            Circle().stroke(color.opacity(0.15), lineWidth: 2)
            Circle().trim(from: 0, to: progress)
                .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: size, height: size)
    }
}

// MARK: - TodoStatus extension

private extension TodoStatus {
    var emptyIcon: String {
        switch self {
        case .pending:    "circle"
        case .inProgress: "play.circle"
        case .done:       "checkmark.circle"
        }
    }
}

// MARK: - Todo Row

struct TodoRowView: View {
    let todo: TodoItem
    let trackedTime: TimeInterval
    let isBreakingDown: Bool
    let isTimerActive: Bool
    let onToggle:    () -> Void
    let onEdit:      () -> Void
    let onDelete:    () -> Void
    let onBreakdown: () -> Void
    let onSetTimer:  () -> Void

    @State private var isHovered = false
    private var theme: AppTheme { AppSettings.shared.appTheme }

    private var isOverdue: Bool {
        guard let due = todo.dueDate, todo.status != .done else { return false }
        return Calendar.current.startOfDay(for: due) < Calendar.current.startOfDay(for: Date())
    }

    var body: some View {
        HStack(spacing: 0) {
            // Status circle button
            Button(action: onToggle) {
                ZStack {
                    Circle()
                        .stroke(
                            todo.status == .done ? theme.successColor :
                            isOverdue ? theme.errorColor.opacity(0.6) :
                            todo.priority.color.opacity(0.4),
                            lineWidth: 1.5
                        )
                        .frame(width: 22, height: 22)
                    if todo.status == .done {
                        Circle().fill(theme.successColor).frame(width: 22, height: 22)
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(theme.selectedForeground)
                    } else if todo.status == .inProgress {
                        Circle().fill(todo.priority.color.opacity(0.15)).frame(width: 22, height: 22)
                        Circle().fill(todo.priority.color).frame(width: 8, height: 8)
                    } else if isOverdue {
                        Circle().fill(theme.errorColor.opacity(0.06)).frame(width: 22, height: 22)
                    }
                }
                .frame(width: 38, height: 38)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Main content
            Button(action: onEdit) {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(todo.title)
                            .font(.body.weight(todo.status == .inProgress ? .semibold : .regular))
                            .foregroundStyle(todo.status == .done ? theme.secondaryText : theme.primaryText)
                            .strikethrough(todo.status == .done, color: theme.secondaryText.opacity(0.5))
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        HStack(spacing: 6) {
                            // Priority badge
                            HStack(spacing: 3) {
                                Image(systemName: todo.priority.icon).font(.system(size: 8, weight: .bold))
                                Text(todo.priority.label).font(.system(size: 10, weight: .medium))
                            }
                            .foregroundStyle(todo.priority.color)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(todo.priority.color.opacity(0.1), in: Capsule())

                            // Due date chip
                            if let due = todo.dueDate {
                                dueDateChip(due)
                            }

                            // Timer active badge
                            if isTimerActive {
                                HStack(spacing: 3) {
                                    Image(systemName: "timer").font(.system(size: 8))
                                    Text("Active").font(.system(size: 10, weight: .medium))
                                }
                                .foregroundStyle(theme.accentColor)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(theme.accentColor.opacity(0.1), in: Capsule())
                            }

                            // Tracked time chip
                            if trackedTime >= 60 {
                                HStack(spacing: 3) {
                                    Image(systemName: "clock.fill").font(.system(size: 8))
                                    Text(formatDuration(trackedTime)).font(.system(size: 10, weight: .medium))
                                }
                                .foregroundStyle(theme.secondaryText)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(.quaternary, in: Capsule())
                            }

                            // AI breakdown spinner
                            if isBreakingDown {
                                HStack(spacing: 3) {
                                    Image(systemName: "sparkles").font(.system(size: 8))
                                    Text("Breaking down…").font(.system(size: 10, weight: .medium))
                                }
                                .foregroundStyle(theme.infoColor)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(theme.infoColor.opacity(0.1), in: Capsule())
                            }
                        }
                    }
                }
                .padding(.vertical, 10)
                .padding(.trailing, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .background {
            RoundedRectangle(cornerRadius: 10)
                .fill(theme.cardBg)
                .shadow(
                    color: isHovered ? theme.shadowColor.opacity(0.08) : theme.shadowColor.opacity(0.03),
                    radius: isHovered ? 6 : 3, y: 1
                )
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(
                    isOverdue ? theme.errorColor.opacity(0.2) :
                    todo.status == .inProgress ? todo.priority.color.opacity(0.2) :
                    Color.clear,
                    lineWidth: 1
                )
        }
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.1), value: isHovered)
        .contextMenu {
            Button(action: onEdit) { Label("Edit", systemImage: "pencil") }
            Button {
                withAnimation { onToggle() }
            } label: {
                Label(
                    todo.status == .done ? "Mark To Do" : "Mark Done",
                    systemImage: todo.status == .done ? "circle" : "checkmark.circle"
                )
            }
            Divider()
            Button(action: onSetTimer) { Label("Set in Timer", systemImage: "timer") }
            Button(action: onBreakdown) {
                Label(
                    isBreakingDown ? "Breaking down…" : "Break down with AI",
                    systemImage: "sparkles"
                )
            }
            .disabled(isBreakingDown)
            Divider()
            Button("Delete", role: .destructive, action: onDelete)
        }
    }

    @ViewBuilder
    private func dueDateChip(_ due: Date) -> some View {
        let t        = theme
        let cal      = Calendar.current
        let today    = cal.startOfDay(for: Date())
        let dueDay   = cal.startOfDay(for: due)
        let tomorrow = cal.date(byAdding: .day, value: 1, to: today)!

        let isOverdueDate = dueDay < today && todo.status != .done
        let isTodayDue    = cal.isDate(dueDay, inSameDayAs: today)
        let isTomorrowDue = cal.isDate(dueDay, inSameDayAs: tomorrow)

        let (label, color, icon): (String, Color, String) = {
            if isOverdueDate {
                let days = cal.dateComponents([.day], from: dueDay, to: today).day ?? 0
                return (days == 1 ? "Yesterday" : "\(days)d overdue", t.errorColor, "exclamationmark.circle.fill")
            } else if isTodayDue {
                return ("Today", t.infoColor, "sun.max.fill")
            } else if isTomorrowDue {
                return ("Tomorrow", t.warningColor, "sunrise.fill")
            } else {
                let fmt = DateFormatter(); fmt.dateFormat = "MMM d"
                return (fmt.string(from: due), t.secondaryText, "calendar")
            }
        }()

        HStack(spacing: 3) {
            Image(systemName: icon).font(.system(size: 8))
            Text(label).font(.system(size: 10, weight: .medium))
        }
        .foregroundStyle(todo.status == .done ? t.secondaryText : color)
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background((todo.status == .done ? t.secondaryText : color).opacity(0.1), in: Capsule())
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let h = Int(seconds) / 3600
        let m = (Int(seconds) % 3600) / 60
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }
}

// MARK: - Add / Edit Sheet

struct TodoEditSheet: View {
    @Environment(\.dismiss) private var dismiss
    let todo: TodoItem?
    var defaultDueDate: Date? = nil

    @State private var title    = ""
    @State private var notes    = ""
    @State private var priority: TodoPriority = .medium
    @State private var status:   TodoStatus   = .pending
    @State private var dueDate:  Date         = Date()
    @State private var hasDueDate = false

    private var theme: AppTheme { AppSettings.shared.appTheme }
    private var isEditing: Bool { todo != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Header
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(theme.accentColor.opacity(0.12))
                        .frame(width: 36, height: 36)
                    Image(systemName: isEditing ? "pencil" : "plus")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(theme.accentColor)
                }
                Text(isEditing ? "Edit Task" : "New Task")
                    .font(.title2.bold())
            }

            // Title
            VStack(alignment: .leading, spacing: 6) {
                Text("Title").font(.subheadline.weight(.medium))
                TextField("What needs to be done?", text: $title)
                    .textFieldStyle(.roundedBorder)
            }

            // Notes
            VStack(alignment: .leading, spacing: 6) {
                Text("Notes").font(.subheadline.weight(.medium))
                TextEditor(text: $notes)
                    .font(.body)
                    .frame(height: 70)
                    .padding(4)
                    .background(theme.cardBg)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.2)))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            // Priority + Status
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Priority").font(.subheadline.weight(.medium))
                    HStack(spacing: 6) {
                        ForEach(TodoPriority.allCases, id: \.self) { p in
                            Button { priority = p } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: p.icon).font(.system(size: 10, weight: .bold))
                                    Text(p.label).font(.caption.weight(.medium))
                                }
                                .foregroundStyle(priority == p ? theme.selectedForeground : p.color)
                                .padding(.horizontal, 10).padding(.vertical, 5)
                                .background(priority == p ? p.color : p.color.opacity(0.1), in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                if isEditing {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Status").font(.subheadline.weight(.medium))
                        Picker("Status", selection: $status) {
                            ForEach(TodoStatus.allCases, id: \.self) { s in
                                Text(s.label).tag(s)
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(width: 130)
                    }
                }
            }

            // Due Date
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("Due Date", systemImage: "calendar")
                        .font(.subheadline.weight(.medium))
                    Spacer()
                    Toggle("", isOn: $hasDueDate)
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .scaleEffect(0.8)
                }
                if hasDueDate {
                    DatePicker(
                        "",
                        selection: $dueDate,
                        displayedComponents: .date
                    )
                    .labelsHidden()
                    .datePickerStyle(.compact)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
            .animation(.easeInOut(duration: 0.15), value: hasDueDate)

            // Actions
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(isEditing ? "Save" : "Add Task") {
                    save(); dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 460)
        .onAppear {
            if let t = todo {
                title    = t.title
                notes    = t.notes
                priority = t.priority
                status   = t.status
                if let d = t.dueDate { dueDate = d; hasDueDate = true }
            } else if let d = defaultDueDate {
                dueDate = d; hasDueDate = true
            }
        }
    }

    private func save() {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let resolvedDue: Date? = hasDueDate ? dueDate : nil
        if var existing = todo {
            existing.title   = trimmed
            existing.notes   = notes
            existing.priority = priority
            existing.status  = status
            existing.dueDate = resolvedDue
            TodoStore.shared.update(existing)
        } else {
            var newTodo = TodoItem(title: trimmed, notes: notes, priority: priority)
            newTodo.dueDate = resolvedDue
            TodoStore.shared.add(newTodo)
        }
    }
}

// MARK: - Safe subscript

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
