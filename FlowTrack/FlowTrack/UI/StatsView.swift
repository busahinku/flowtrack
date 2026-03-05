import SwiftUI
import Charts

// MARK: - Stats Period
enum StatsPeriod: String, CaseIterable {
    case day = "Day"
    case week = "Week"
    case month = "Month"
}

struct StatsView: View {
    @Bindable var appState = AppState.shared
    @State private var period: StatsPeriod = .day
    @State private var selectedDate = Date()
    @State private var allActivities: [ActivityRecord] = []
    @State private var periodTimeSlots: [TimeSlot] = []
    @State private var selectedApp: AppUsageInfo?
    @State private var selectedCatStat: CategoryStat?
    @State private var selectedHourStat: Int?
    @State private var selectedFlowHour: Int?
    @State private var selectedSessionSlot: TimeSlot?
    @State private var searchText = ""
    @State private var showAllApps = false
    @State private var showDatePicker = false

    private var theme: AppTheme { AppSettings.shared.appTheme }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                summaryCards
                HStack(alignment: .top, spacing: 16) {
                    categoryDonut
                        .frame(maxHeight: .infinity)
                    activityChart
                        .frame(maxHeight: .infinity)
                }
                periodProductivityFlow
                distractionSection
                topApps
                sessionsSection
            }
            .padding()
        }
        .background(theme.timelineBg)
        .toolbarBackground(theme.timelineBg, for: .windowToolbar)
        .onAppear { loadData() }
        .onChange(of: selectedDate) { Task { loadData() } }
        .onChange(of: period) { selectedHourStat = nil; selectedFlowHour = nil; Task { loadData() } }
        .sheet(item: $selectedApp) { app in
            AppDetailSheet(app: app, allActivities: allActivities)
        }
        .sheet(item: $selectedSessionSlot) { slot in
            SessionDetailView(slot: slot)
        }
        .sheet(item: $selectedCatStat) { stat in
            CategoryDetailSheet(stat: stat, activities: allActivities.filter { $0.category.rawValue == stat.category.rawValue })
        }
        .toolbar {
            // Period picker — custom capsule style, no system segmented background
            ToolbarItem(placement: .principal) {
                periodPicker
            }

            // Date navigation — right
            ToolbarItemGroup(placement: .primaryAction) {
                statsDateNav
            }
        }
    }

    private var periodPicker: some View {
        HStack(spacing: 2) {
            ForEach(StatsPeriod.allCases, id: \.self) { p in
                Button(p.rawValue) { period = p }
                    .buttonStyle(.plain)
                    .font(.subheadline.weight(period == p ? .semibold : .regular))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(
                        period == p ? theme.accentColor : Color.clear,
                        in: RoundedRectangle(cornerRadius: 6)
                    )
                    .foregroundStyle(period == p ? .white : .secondary)
                    .animation(.easeInOut(duration: 0.15), value: period)
            }
        }
    }

    private var statsDateNav: some View {
        HStack(spacing: 2) {
            if !isCurrentPeriod {
                Button("Today") { selectedDate = Date() }
                    .buttonStyle(.plain)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(theme.accentColor)
            }

            Button(action: navigateBack) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)

            Button { showDatePicker.toggle() } label: {
                Text(dateRangeLabel)
                    .font(.headline)
                    .frame(minWidth: 90)
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showDatePicker) {
                DatePicker("Select Date", selection: $selectedDate, displayedComponents: .date)
                    .datePickerStyle(.graphical)
                    .padding()
                    .frame(width: 320)
            }

            Button(action: navigateForward) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
    }

    private var isCurrentPeriod: Bool {
        switch period {
        case .day:   return Calendar.current.isDateInToday(selectedDate)
        case .week:  return Calendar.current.isDate(selectedDate, equalTo: Date(), toGranularity: .weekOfYear)
        case .month: return Calendar.current.isDate(selectedDate, equalTo: Date(), toGranularity: .month)
        }
    }

    // MARK: - Summary Cards
    private var summaryCards: some View {
        HStack(spacing: 12) {
            SummaryCard(title: "Active", value: Theme.formatDuration(totalActiveSeconds),
                       icon: "clock.fill", color: .blue)
            SummaryCard(title: "Productive", value: "\(Int(productivePercent))%",
                       icon: "checkmark.circle.fill", color: .green)
            SummaryCard(title: "Distraction", value: Theme.formatDuration(distractionSeconds),
                       icon: "eye.slash.fill", color: .red)
            SummaryCard(title: "Sessions", value: "\(periodTimeSlots.filter { !$0.isIdle }.count)",
                       icon: "square.stack.fill", color: .purple)
            SummaryCard(title: "Focus Score",
                       value: totalActiveSeconds > 0 ? "\(Int(productivePercent))%" : "—",
                       icon: "brain", color: theme.accentColor)
        }
    }

    // MARK: - Category Donut
    private var categoryDonut: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Category Breakdown")
                .font(.headline)

            if catStats.isEmpty {
                Text("No data for this period")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(height: 200)
            } else {
                Chart(catStats) { stat in
                    SectorMark(
                        angle: .value("Time", stat.totalSeconds),
                        innerRadius: .ratio(0.6),
                        angularInset: 1.5
                    )
                    .foregroundStyle(Theme.color(for: stat.category))
                    .opacity(selectedCatStat?.id == stat.id ? 0.7 : 1.0)
                }
                .chartAngleSelection(value: $chartAngleSelection)
                .frame(height: 200)
                .overlay {
                    VStack(spacing: 2) {
                        if let selected = selectedCatStat ?? catStats.first {
                            Image(systemName: selected.category.icon)
                                .font(.title3)
                                .foregroundStyle(Theme.color(for: selected.category))
                            Text(selected.category.rawValue)
                                .font(.caption.bold())
                            Text("\(Int(selected.percentage))%")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 5) {
                    ForEach(catStats) { stat in
                        Button(action: { selectedCatStat = stat }) {
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(Theme.color(for: stat.category))
                                    .frame(width: 10, height: 10)
                                Image(systemName: stat.category.icon)
                                    .font(.caption)
                                    .frame(width: 16)
                                Text(stat.category.rawValue)
                                    .font(.caption)
                                Spacer()
                                Text(Theme.formatDuration(stat.totalSeconds))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text("\(Int(stat.percentage))%")
                                    .font(.caption.bold())
                                    .frame(width: 35, alignment: .trailing)
                            }
                            .contentShape(Rectangle())
                            .padding(.vertical, 2)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
        .background(theme.cardBg)
        .cornerRadius(12)
    }

    @State private var chartAngleSelection: Double?

    // MARK: - Activity Chart (period-aware: hours for day, days for week/month)
    private var activityChart: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(period == .day ? "Hourly Activity" : "Daily Activity")
                    .font(.headline)
                Spacer()
                Group {
                    if let x = selectedHourStat {
                        Text(activitySelectionLabel(x))
                    } else {
                        Text(" ")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(theme.accentColor.opacity(selectedHourStat != nil ? 0.1 : 0))
                .cornerRadius(6)
            }

            switch period {
            case .day:   dayActivityChart
            case .week:  weekActivityChart
            case .month: monthActivityChart
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
        .background(theme.cardBg)
        .cornerRadius(12)
    }

    private var dayActivityChart: some View {
        Chart(hourlyStats) { stat in
            BarMark(
                x: .value("Hour", stat.hour),
                y: .value("Minutes", stat.minutes),
                width: .fixed(max(8, 400.0 / 24.0 - 2))
            )
            .foregroundStyle(Theme.color(for: stat.category))
            .opacity(selectedHourStat == stat.hour ? 0.7 : 1.0)
        }
        .chartXScale(domain: 0...23)
        .chartYScale(domain: 0...60)
        .chartXSelection(value: $selectedHourStat)
        .chartXAxis {
            AxisMarks(values: Array(stride(from: 0, through: 23, by: 3))) { value in
                AxisValueLabel {
                    if let h = value.as(Int.self) {
                        Text("\(h == 0 ? 12 : (h > 12 ? h - 12 : h))\(h < 12 ? "a" : "p")")
                            .font(.caption2)
                    }
                }
                AxisGridLine()
            }
        }
        .chartYAxis {
            AxisMarks(values: [0, 15, 30, 45, 60]) { value in
                AxisValueLabel {
                    if let v = value.as(Int.self) { Text("\(v)m").font(.caption2) }
                }
                AxisGridLine()
            }
        }
        .frame(height: 280)
    }

    private var weekActivityChart: some View {
        Chart(dailyActivityStats) { stat in
            BarMark(x: .value("Day", stat.x), y: .value("Minutes", stat.minutes))
                .foregroundStyle(Theme.color(for: stat.category))
                .opacity(selectedHourStat == stat.x ? 0.7 : 1.0)
        }
        .chartXScale(domain: 0...6)
        .chartXSelection(value: $selectedHourStat)
        .chartXAxis {
            let names = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
            AxisMarks(values: Array(0...6)) { value in
                AxisValueLabel {
                    if let v = value.as(Int.self) { Text(names[v]).font(.caption2) }
                }
                AxisGridLine()
            }
        }
        .chartYAxis {
            AxisMarks { value in
                AxisValueLabel {
                    if let v = value.as(Double.self) { Text("\(Int(v))m").font(.caption2) }
                }
                AxisGridLine()
            }
        }
        .frame(height: 280)
    }

    private var monthActivityChart: some View {
        let days = daysInCurrentMonth
        return Chart(dailyActivityStats) { stat in
            BarMark(x: .value("Day", stat.x), y: .value("Minutes", stat.minutes))
                .foregroundStyle(Theme.color(for: stat.category))
                .opacity(selectedHourStat == stat.x ? 0.7 : 1.0)
        }
        .chartXScale(domain: 1...days)
        .chartXSelection(value: $selectedHourStat)
        .chartXAxis {
            AxisMarks(values: Array(stride(from: 1, through: days, by: 5))) { value in
                AxisValueLabel {
                    if let v = value.as(Int.self) { Text("\(v)").font(.caption2) }
                }
                AxisGridLine()
            }
        }
        .chartYAxis {
            AxisMarks { value in
                AxisValueLabel {
                    if let v = value.as(Double.self) { Text("\(Int(v))m").font(.caption2) }
                }
                AxisGridLine()
            }
        }
        .frame(height: 280)
    }

    private func activitySelectionLabel(_ x: Int) -> String {
        switch period {
        case .day:
            let total = hourlyStats.filter { $0.hour == x }.reduce(0.0) { $0 + $1.minutes }
            let h = x == 0 ? 12 : (x > 12 ? x - 12 : x)
            return "\(h):00 \(x < 12 ? "AM" : "PM") — \(Int(total))m"
        case .week:
            let names = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
            let total = dailyActivityStats.filter { $0.x == x }.reduce(0.0) { $0 + $1.minutes }
            return "\(names[max(0, min(6, x))]) — \(Int(total))m"
        case .month:
            let total = dailyActivityStats.filter { $0.x == x }.reduce(0.0) { $0 + $1.minutes }
            return "Day \(x) — \(Int(total))m"
        }
    }

    // MARK: - Productivity Flow (period-aware)
    private var periodProductivityFlow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Productivity Flow")
                    .font(.headline)
                Spacer()
                Group {
                    if let x = selectedFlowHour {
                        Text(flowSelectionLabel(x))
                    } else {
                        Text(" ")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.green.opacity(selectedFlowHour != nil ? 0.1 : 0))
                .cornerRadius(6)
            }

            switch period {
            case .day:   dayFlowChart
            case .week:  periodicFlowChart(data: productivityByDay, domain: 0...6)
            case .month: periodicFlowChart(data: productivityByDay, domain: 1...daysInCurrentMonth)
            }
        }
        .padding()
        .background(theme.cardBg)
        .cornerRadius(12)
    }

    private var dayFlowChart: some View {
        Chart(productivityByHour.filter { $0.hasData }) { item in
            AreaMark(x: .value("Hour", item.hour), y: .value("Score", item.score))
                .foregroundStyle(LinearGradient(colors: [.green.opacity(0.3), .green.opacity(0.05)],
                                               startPoint: .top, endPoint: .bottom))
                .interpolationMethod(.catmullRom)
            LineMark(x: .value("Hour", item.hour), y: .value("Score", item.score))
                .foregroundStyle(.green)
                .interpolationMethod(.catmullRom)
                .lineStyle(StrokeStyle(lineWidth: 2))
            if let sel = selectedFlowHour, sel == item.hour {
                PointMark(x: .value("Hour", item.hour), y: .value("Score", item.score))
                    .foregroundStyle(.green).symbolSize(60)
            }
        }
        .chartXScale(domain: 0...23)
        .chartYScale(domain: 0...100)
        .chartXSelection(value: $selectedFlowHour)
        .chartXAxis {
            AxisMarks(values: Array(stride(from: 0, through: 23, by: 3))) { value in
                AxisValueLabel {
                    if let h = value.as(Int.self) {
                        Text("\(h == 0 ? 12 : (h > 12 ? h - 12 : h))\(h < 12 ? "a" : "p")").font(.caption2)
                    }
                }
                AxisGridLine()
            }
        }
        .chartYAxis {
            AxisMarks(values: [0, 25, 50, 75, 100]) { value in
                AxisValueLabel {
                    if let v = value.as(Int.self) { Text("\(v)%").font(.caption2) }
                }
                AxisGridLine()
            }
        }
        .frame(height: 180)
    }

    private func periodicFlowChart(data: [DayScore], domain: ClosedRange<Int>) -> some View {
        let filtered = data.filter { $0.hasData }
        return Chart(filtered) { item in
            AreaMark(x: .value("X", item.x), y: .value("Score", item.score))
                .foregroundStyle(LinearGradient(colors: [.green.opacity(0.3), .green.opacity(0.05)],
                                               startPoint: .top, endPoint: .bottom))
                .interpolationMethod(.catmullRom)
            LineMark(x: .value("X", item.x), y: .value("Score", item.score))
                .foregroundStyle(.green)
                .interpolationMethod(.catmullRom)
                .lineStyle(StrokeStyle(lineWidth: 2))
            if let sel = selectedFlowHour, sel == item.x {
                PointMark(x: .value("X", item.x), y: .value("Score", item.score))
                    .foregroundStyle(.green).symbolSize(60)
            }
        }
        .chartXScale(domain: domain)
        .chartYScale(domain: 0...100)
        .chartXSelection(value: $selectedFlowHour)
        .chartXAxis {
            if period == .week {
                let names = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
                AxisMarks(values: Array(0...6)) { value in
                    AxisValueLabel {
                        if let v = value.as(Int.self) { Text(names[v]).font(.caption2) }
                    }
                    AxisGridLine()
                }
            } else {
                AxisMarks(values: Array(stride(from: 1, through: domain.upperBound, by: 5))) { value in
                    AxisValueLabel {
                        if let v = value.as(Int.self) { Text("\(v)").font(.caption2) }
                    }
                    AxisGridLine()
                }
            }
        }
        .chartYAxis {
            AxisMarks(values: [0, 25, 50, 75, 100]) { value in
                AxisValueLabel {
                    if let v = value.as(Int.self) { Text("\(v)%").font(.caption2) }
                }
                AxisGridLine()
            }
        }
        .frame(height: 180)
    }

    private func flowSelectionLabel(_ x: Int) -> String {
        switch period {
        case .day:
            let item = productivityByHour.first(where: { $0.hour == x })
            let h = x == 0 ? 12 : (x > 12 ? x - 12 : x)
            return "\(h):00 \(x < 12 ? "AM" : "PM") — \(Int(item?.score ?? 0))% focus"
        case .week:
            let names = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
            let item = productivityByDay.first(where: { $0.x == x })
            return "\(names[max(0, min(6, x))]) — \(Int(item?.score ?? 0))% focus"
        case .month:
            let item = productivityByDay.first(where: { $0.x == x })
            return "Day \(x) — \(Int(item?.score ?? 0))% focus"
        }
    }

    // MARK: - Distraction Section
    private var distractionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Distraction Breakdown", systemImage: "eye.slash.fill")
                    .font(.headline)
                    .foregroundStyle(.primary)
                Spacer()
                VStack(alignment: .trailing, spacing: 1) {
                    Text(Theme.formatDuration(distractionSeconds))
                        .font(.subheadline.bold())
                        .foregroundStyle(.red)
                    if totalActiveSeconds > 0 {
                        Text("\(Int(distractionSeconds / totalActiveSeconds * 100))% of active time")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if distractionApps.isEmpty {
                Text("No distraction time recorded for this period")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity)
            } else {
                ForEach(distractionApps.prefix(6)) { app in
                    HStack(spacing: 10) {
                        AppIconImage(bundleID: app.bundleID, size: 20)
                        Text(app.appName)
                            .font(.caption.bold())
                            .lineLimit(1)
                        Spacer()
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(Color.red.opacity(0.12))
                                    .frame(height: 6)
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(Color.red.opacity(0.5))
                                    .frame(width: max(4, geo.size.width * CGFloat(app.duration / max(distractionSeconds, 1))), height: 6)
                            }
                        }
                        .frame(width: 100, height: 6)
                        Text(Theme.formatDuration(app.duration))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 52, alignment: .trailing)
                    }
                }
            }
        }
        .padding()
        .background(theme.cardBg)
        .cornerRadius(12)
    }

    // MARK: - Top Apps
    private var topApps: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Top Apps")
                    .font(.headline)
                Spacer()
                Text("\(appUsages.count) apps")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            let displayApps = showAllApps ? appUsages : Array(appUsages.prefix(10))

            ForEach(displayApps) { app in
                Button(action: { selectedApp = app }) {
                    HStack(spacing: 10) {
                        AppIconImage(bundleID: app.bundleID, size: 24)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(app.appName)
                                .font(.subheadline.bold())
                            Text(app.category.rawValue)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(Theme.formatDuration(app.duration))
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)

                        // Usage bar
                        let fraction = CGFloat(app.duration / max(totalActiveSeconds, 1))
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Theme.color(for: app.category))
                            .frame(width: 80 * fraction, height: 8)
                            .frame(width: 80, alignment: .leading)
                    }
                    .contentShape(Rectangle())
                    .padding(.vertical, 4)
                    .padding(.horizontal, 4)
                }
                .buttonStyle(.plain)
            }

            if appUsages.count > 10 {
                Button(action: { showAllApps.toggle() }) {
                    HStack {
                        Spacer()
                        Text(showAllApps ? "Show less" : "Show all \(appUsages.count) apps")
                            .font(.caption)
                        Image(systemName: showAllApps ? "chevron.up" : "chevron.down")
                            .font(.caption)
                        Spacer()
                    }
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(theme.accentColor)
            }
        }
        .padding()
        .background(theme.cardBg)
        .cornerRadius(12)
    }

    // MARK: - Sessions Section
    private var sessionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Sessions")
                    .font(.headline)
                Text("(\(filteredSessions.count))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Search", text: $searchText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 180)
                }
            }

            if filteredSessions.isEmpty {
                Text("No sessions found")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 20)
                    .frame(maxWidth: .infinity)
            }

            ForEach(filteredSessions) { slot in
                Button(action: { selectedSessionSlot = slot }) {
                    HStack(spacing: 8) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Theme.color(for: slot.category))
                            .frame(width: 4, height: 40)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(appState.sessionTitle(for: slot))
                                .font(.subheadline.bold())
                                .lineLimit(1)
                            Text(Theme.formatTimeRange(slot.startTime, slot.endTime))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        HStack(spacing: 4) {
                            Image(systemName: slot.category.icon)
                                .font(.caption2)
                            Text(slot.category.rawValue)
                                .font(.caption2)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Theme.color(for: slot.category).opacity(0.12))
                        .cornerRadius(6)

                        Text(Theme.formatDuration(slot.duration))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 50, alignment: .trailing)
                    }
                    .contentShape(Rectangle())
                    .padding(.vertical, 4)
                    .padding(.horizontal, 4)
                }
                .buttonStyle(.plain)
            }
        }
        .padding()
        .background(theme.cardBg)
        .cornerRadius(12)
    }

    // MARK: - Data Loading
    private func loadData() {
        let (from, to) = dateRange
        allActivities = (try? Database.shared.activitiesForRange(from: from, to: to)) ?? []
        periodTimeSlots = (try? Database.shared.sessionsForRange(from: from, to: to)) ?? []
    }

    private var dateRange: (from: Date, to: Date) {
        let cal = Calendar.current
        switch period {
        case .day:
            let start = cal.startOfDay(for: selectedDate)
            return (start, cal.date(byAdding: .day, value: 1, to: start)!)
        case .week:
            let weekday = cal.component(.weekday, from: selectedDate)
            let start = cal.date(byAdding: .day, value: -(weekday - 1), to: cal.startOfDay(for: selectedDate))!
            return (start, cal.date(byAdding: .day, value: 7, to: start)!)
        case .month:
            let comps = cal.dateComponents([.year, .month], from: selectedDate)
            let start = cal.date(from: comps)!
            return (start, cal.date(byAdding: .month, value: 1, to: start)!)
        }
    }

    private var dateRangeLabel: String {
        let f = DateFormatter()
        switch period {
        case .day:
            if Calendar.current.isDateInToday(selectedDate) { return "Today" }
            f.dateFormat = "MMM d, yyyy"
            return f.string(from: selectedDate)
        case .week:
            let (from, to) = dateRange
            f.dateFormat = "MMM d"
            return "\(f.string(from: from)) – \(f.string(from: to))"
        case .month:
            f.dateFormat = "MMMM yyyy"
            return f.string(from: selectedDate)
        }
    }

    private func navigateBack() {
        let cal = Calendar.current
        switch period {
        case .day: selectedDate = cal.date(byAdding: .day, value: -1, to: selectedDate)!
        case .week: selectedDate = cal.date(byAdding: .weekOfYear, value: -1, to: selectedDate)!
        case .month: selectedDate = cal.date(byAdding: .month, value: -1, to: selectedDate)!
        }
    }

    private func navigateForward() {
        let cal = Calendar.current
        switch period {
        case .day: selectedDate = cal.date(byAdding: .day, value: 1, to: selectedDate)!
        case .week: selectedDate = cal.date(byAdding: .weekOfYear, value: 1, to: selectedDate)!
        case .month: selectedDate = cal.date(byAdding: .month, value: 1, to: selectedDate)!
        }
    }

    // MARK: - Computed Stats
    private var catStats: [CategoryStat] {
        var durations: [String: (duration: Double, apps: Set<String>)] = [:]
        var total: Double = 0
        for a in allActivities where !a.isIdle {
            var entry = durations[a.category.rawValue] ?? (0, Set())
            entry.duration += a.duration
            entry.apps.insert(a.appName)
            durations[a.category.rawValue] = entry
            total += a.duration
        }
        guard total > 0 else { return [] }
        return durations.map { (key, val) in
            CategoryStat(category: Category(rawValue: key), totalSeconds: val.duration,
                        percentage: val.duration / total * 100, appCount: val.apps.count)
        }.sorted { $0.totalSeconds > $1.totalSeconds }
    }

    private var hourlyStats: [HourStat] {
        var hourCats: [Int: [String: Double]] = [:]
        let cal = Calendar.current
        for a in allActivities where !a.isIdle {
            let hour = cal.component(.hour, from: a.timestamp)
            hourCats[hour, default: [:]][a.category.rawValue, default: 0] += a.duration / 60
        }

        // Collect all categories present in data for stable ordering
        let allCategoryNames = Set(hourCats.values.flatMap(\.keys)).sorted()

        // Generate entries for all hours 0-23 with all categories for stability
        var result: [HourStat] = []
        for hour in 0...23 {
            let cats = hourCats[hour] ?? [:]
            for catName in allCategoryNames {
                let minutes = cats[catName] ?? 0
                if minutes > 0 {
                    result.append(HourStat(hour: hour, category: Category(rawValue: catName), minutes: minutes))
                }
            }
        }
        return result
    }

    private var productivityByHour: [HourScore] {
        var hourProd: [Int: (prod: Double, total: Double)] = [:]
        let cal = Calendar.current
        for a in allActivities where !a.isIdle {
            let hour = cal.component(.hour, from: a.timestamp)
            var entry = hourProd[hour] ?? (0, 0)
            entry.total += a.duration
            if a.category.isProductive { entry.prod += a.duration }
            hourProd[hour] = entry
        }
        return (0...23).map { hour in
            let entry = hourProd[hour]
            let score = entry.map { $0.total > 0 ? $0.prod / $0.total * 100 : 0 } ?? 0
            let hasData = entry != nil
            return HourScore(hour: hour, score: score, hasData: hasData)
        }
    }

    private var distractionSeconds: Double {
        allActivities.filter { $0.category.rawValue == "Distraction" }.reduce(0) { $0 + $1.duration }
    }

    private var distractionApps: [AppUsageInfo] {
        appUsages.filter { $0.category.rawValue == "Distraction" }
    }

    private var daysInCurrentMonth: Int {
        Calendar.current.range(of: .day, in: .month, for: selectedDate)?.count ?? 31
    }

    private var dailyActivityStats: [DayStat] {
        guard period != .day else { return [] }
        let cal = Calendar.current
        let (from, _) = dateRange
        var dayCats: [Int: [String: Double]] = [:]
        for a in allActivities where !a.isIdle {
            let x: Int
            switch period {
            case .week:
                let diff = cal.dateComponents([.day], from: cal.startOfDay(for: from), to: cal.startOfDay(for: a.timestamp)).day ?? 0
                x = max(0, min(6, diff))
            case .month:
                x = cal.component(.day, from: a.timestamp)
            default: continue
            }
            dayCats[x, default: [:]][a.category.rawValue, default: 0] += a.duration / 60
        }
        let allCatNames = Set(dayCats.values.flatMap(\.keys)).sorted()
        var result: [DayStat] = []
        let (start, count) = period == .week ? (0, 7) : (1, daysInCurrentMonth)
        for x in start..<(start + count) {
            for catName in allCatNames {
                let mins = dayCats[x]?[catName] ?? 0
                if mins > 0 { result.append(DayStat(x: x, category: Category(rawValue: catName), minutes: mins)) }
            }
        }
        return result
    }

    private var productivityByDay: [DayScore] {
        guard period != .day else { return [] }
        let cal = Calendar.current
        let (from, _) = dateRange
        var dayData: [Int: (prod: Double, total: Double)] = [:]
        for a in allActivities where !a.isIdle {
            let x: Int
            switch period {
            case .week:
                let diff = cal.dateComponents([.day], from: cal.startOfDay(for: from), to: cal.startOfDay(for: a.timestamp)).day ?? 0
                x = max(0, min(6, diff))
            case .month:
                x = cal.component(.day, from: a.timestamp)
            default: continue
            }
            var e = dayData[x] ?? (0, 0)
            e.total += a.duration
            if a.category.isProductive { e.prod += a.duration }
            dayData[x] = e
        }
        let (start, count) = period == .week ? (0, 7) : (1, daysInCurrentMonth)
        return (start..<(start + count)).map { x in
            let e = dayData[x]
            let score = e.map { $0.total > 0 ? $0.prod / $0.total * 100 : 0 } ?? 0
            return DayScore(x: x, score: score, hasData: e != nil)
        }
    }

    private var totalActiveSeconds: Double {
        allActivities.filter { !$0.isIdle }.reduce(0) { $0 + $1.duration }
    }

    private var productivePercent: Double {
        let total = totalActiveSeconds
        guard total > 0 else { return 0 }
        return allActivities.filter { $0.category.isProductive }.reduce(0) { $0 + $1.duration } / total * 100
    }

    private var topAppName: String {
        appUsages.first?.appName ?? "—"
    }

    private var appUsages: [AppUsageInfo] {
        var apps: [String: (bundleID: String, category: Category, duration: Double, timestamps: [Date])] = [:]
        for a in allActivities where !a.isIdle {
            var entry = apps[a.appName] ?? (a.bundleID, a.category, 0, [])
            entry.duration += a.duration
            entry.timestamps.append(a.timestamp)
            apps[a.appName] = entry
        }
        return apps.map { (name, val) in
            AppUsageInfo(appName: name, bundleID: val.bundleID, category: val.category,
                        duration: val.duration, timestamps: val.timestamps.sorted())
        }.sorted { $0.duration > $1.duration }
    }

    private var filteredSessions: [TimeSlot] {
        let slots = periodTimeSlots.filter { !$0.isIdle }
        if searchText.isEmpty { return slots }
        return slots.filter {
            appState.sessionTitle(for: $0).lowercased().contains(searchText.lowercased()) ||
            $0.category.rawValue.lowercased().contains(searchText.lowercased()) ||
            $0.activities.contains { $0.appName.lowercased().contains(searchText.lowercased()) }
        }
    }
}

// MARK: - Supporting Types
struct DayStat: Identifiable {
    let x: Int               // 0-6 (week) or 1-31 (month)
    let category: Category
    let minutes: Double
    var id: String { "\(x)-\(category.rawValue)" }
}

struct DayScore: Identifiable {
    let x: Int
    let score: Double
    let hasData: Bool
    var id: Int { x }
}

struct HourScore: Identifiable {
    let id = UUID()
    let hour: Int
    let score: Double
    let hasData: Bool

    init(hour: Int, score: Double, hasData: Bool = true) {
        self.hour = hour
        self.score = score
        self.hasData = hasData
    }
}

struct AppUsageInfo: Identifiable {
    let id = UUID()
    let appName: String
    let bundleID: String
    let category: Category
    let duration: Double
    let timestamps: [Date]
}

// MARK: - Summary Card
struct SummaryCard: View {
    let title: String
    let value: String
    let icon: String
    let color: Color

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(color)
            Text(value)
                .font(.headline)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .frame(height: 20) // stable height regardless of content
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 80)
        .padding(.vertical, 12)
        .background(AppSettings.shared.appTheme.cardBg)
        .cornerRadius(10)
    }
}

// MARK: - App Detail Sheet
struct AppDetailSheet: View {
    let app: AppUsageInfo
    let allActivities: [ActivityRecord]
    @Environment(\.dismiss) private var dismiss

    private var appActivities: [ActivityRecord] {
        allActivities.filter { $0.appName == app.appName && !$0.isIdle }
    }

    private var uniqueTitles: [(title: String, duration: Double, count: Int)] {
        var dict: [String: (duration: Double, count: Int)] = [:]
        for a in appActivities {
            let title = a.windowTitle.isEmpty ? "(no title)" : a.windowTitle
            var entry = dict[title] ?? (0, 0)
            entry.duration += a.duration
            entry.count += 1
            dict[title] = entry
        }
        return dict.map { ($0.key, $0.value.duration, $0.value.count) }
            .sorted { $0.duration > $1.duration }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            HStack {
                AppIconImage(bundleID: app.bundleID, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(app.appName)
                        .font(.title2.bold())
                    HStack(spacing: 6) {
                        Image(systemName: app.category.icon)
                            .foregroundStyle(Theme.color(for: app.category))
                        Text(app.category.rawValue)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            Divider()

            // Stats
            HStack(spacing: 24) {
                VStack {
                    Text(Theme.formatDuration(app.duration))
                        .font(.title3.bold())
                    Text("Total Time")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                VStack {
                    Text("\(uniqueTitles.count)")
                        .font(.title3.bold())
                    Text("Windows")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                VStack {
                    Text("\(appActivities.count)")
                        .font(.title3.bold())
                    Text("Records")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // Window Titles
            VStack(alignment: .leading, spacing: 6) {
                Text("Windows & Pages")
                    .font(.headline)
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(uniqueTitles.prefix(30), id: \.title) { item in
                            HStack {
                                Text(item.title)
                                    .font(.caption)
                                    .lineLimit(2)
                                Spacer()
                                Text(Theme.formatDuration(item.duration))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                            .padding(.vertical, 3)
                            Divider().opacity(0.3)
                        }
                    }
                }
                .frame(maxHeight: 250)
            }

            // Activity Timeline
            if !app.timestamps.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Activity Timeline")
                        .font(.headline)
                    let firstTime = app.timestamps.first!
                    let lastTime = app.timestamps.last!
                    Text("\(Theme.formatTime(firstTime)) – \(Theme.formatTime(lastTime))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding()
        .frame(minWidth: 500, minHeight: 400)
    }
}

// MARK: - Category Detail Sheet
struct CategoryDetailSheet: View {
    let stat: CategoryStat
    let activities: [ActivityRecord]
    @Environment(\.dismiss) private var dismiss

    private var appBreakdown: [(name: String, bundleID: String, duration: Double)] {
        var dict: [String: (bundleID: String, duration: Double)] = [:]
        for a in activities {
            var entry = dict[a.appName] ?? (a.bundleID, 0)
            entry.duration += a.duration
            dict[a.appName] = entry
        }
        return dict.map { ($0.key, $0.value.bundleID, $0.value.duration) }
            .sorted { $0.duration > $1.duration }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: stat.category.icon)
                    .font(.title2)
                    .foregroundStyle(Theme.color(for: stat.category))
                VStack(alignment: .leading) {
                    Text(stat.category.rawValue)
                        .font(.title2.bold())
                    Text("\(Int(stat.percentage))% of total • \(Theme.formatDuration(stat.totalSeconds))")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            Divider()

            Text("Apps in this category")
                .font(.headline)

            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(appBreakdown, id: \.name) { item in
                        HStack(spacing: 10) {
                            AppIconImage(bundleID: item.bundleID, size: 24)
                            Text(item.name)
                                .font(.subheadline)
                            Spacer()
                            Text(Theme.formatDuration(item.duration))
                                .font(.caption)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                            let frac = CGFloat(item.duration / max(stat.totalSeconds, 1))
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Theme.color(for: stat.category))
                                .frame(width: 60 * frac, height: 8)
                                .frame(width: 60, alignment: .leading)
                        }
                    }
                }
            }
            .frame(maxHeight: 300)
        }
        .padding()
        .frame(minWidth: 450, minHeight: 350)
    }
}
