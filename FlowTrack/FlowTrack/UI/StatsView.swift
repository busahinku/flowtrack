import SwiftUI
import Charts

// MARK: - Stats Period
enum StatsPeriod: String, CaseIterable {
    case day = "Day"
    case week = "Week"
    case month = "Month"
}

enum StatsSection: String, CaseIterable {
    case activity    = "Activity"
    case timerTasks  = "Tasks"
}

struct StatsView: View {
    @Bindable var appState = AppState.shared
    @Bindable private var todoStore = TodoStore.shared
    @State private var statsSection: StatsSection = .activity
    @State private var period: StatsPeriod = .day
    @State private var selectedDate = Date()
    @Namespace private var periodNS
    @Namespace private var sectionNS
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
    @State private var sevenDayActivities: [(date: Date, score: Double)] = []
    @State private var previousPeriodActive: Double = 0
    @State private var previousPeriodFocus: Double = 0
    @State private var cachedAppUsages: [AppUsageInfo] = []
    @State private var cachedHourlyScores: [HourScore] = []
    @State private var cachedDayScores: [DayScore] = []
    @State private var cachedDailyStats: [DayStat] = []
    @State private var cachedTotalActive: Double = 0
    @State private var cachedProductivePercent: Double = 0
    @State private var cachedDistractionSecs: Double = 0

    private var theme: AppTheme { AppSettings.shared.appTheme }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                if statsSection == .activity {
                    summaryCards
                    HStack(alignment: .top, spacing: 16) {
                        categoryDonut.frame(maxHeight: .infinity)
                        activityChart.frame(maxHeight: .infinity)
                    }
                    periodProductivityFlow
                    distractionSection
                    topApps
                    sessionsSection
                } else {
                    timerTasksContent
                }
            }
            .padding()
        }
        .background(theme.timelineBg)
        .toolbarBackground(.hidden, for: .windowToolbar)
        .onAppear { loadData() }
        .onChange(of: selectedDate) { Task { loadData() } }
        .onChange(of: period) { selectedHourStat = nil; selectedFlowHour = nil; Task { loadData() } }
        .onChange(of: statsSection) { selectedHourStat = nil; selectedFlowHour = nil }
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
            ToolbarItem(placement: .principal) {
                HStack(spacing: 10) {
                    sectionPicker
                    Divider().frame(height: 18)
                    periodPicker
                }
            }
            ToolbarItemGroup(placement: .primaryAction) {
                statsDateNav
            }
        }
    }

    private var statsHeader: some View {
        HStack(spacing: 8) {
            periodPicker
            Spacer()
            statsDateNav
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(theme.timelineBg)
    }

    // MARK: - Section Picker (Activity | Timer & Tasks)
    private var sectionPicker: some View {
        HStack(spacing: 0) {
            ForEach(StatsSection.allCases, id: \.self) { sec in
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { statsSection = sec }
                } label: {
                    Text(sec.rawValue)
                        .font(.subheadline.weight(statsSection == sec ? .semibold : .regular))
                        .foregroundStyle(statsSection == sec ? theme.selectedForeground : theme.secondaryText)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                        .background {
                            if statsSection == sec {
                                RoundedRectangle(cornerRadius: 7)
                                    .fill(theme.accentColor)
                                    .matchedGeometryEffect(id: "sectionBg", in: sectionNS)
                            }
                        }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(theme.dividerColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
    }

    private var periodPicker: some View {
        HStack(spacing: 0) {
            ForEach(StatsPeriod.allCases, id: \.self) { p in
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { period = p }
                } label: {
                    Text(p.rawValue)
                        .font(.subheadline.weight(period == p ? .semibold : .regular))
                        .foregroundStyle(period == p ? theme.selectedForeground : theme.secondaryText)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                        .background {
                            if period == p {
                                RoundedRectangle(cornerRadius: 7)
                                    .fill(theme.accentColor)
                                    .matchedGeometryEffect(id: "periodBg", in: periodNS)
                            }
                        }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(theme.dividerColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
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
            .foregroundStyle(theme.secondaryText)

            Button { showDatePicker.toggle() } label: {
                Text(dateRangeLabel)
                    .font(.headline)
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

            Button(action: navigateForward) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(theme.secondaryText)
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
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                SummaryCard(
                    title: "Active",
                    value: Theme.formatDuration(totalActiveSeconds),
                    icon: "clock.fill",
                    color: theme.infoColor,
                    delta: activeDelta
                )
                SummaryCard(
                    title: "Focus Score",
                    value: totalActiveSeconds > 0 ? "\(Int(productivePercent))%" : "—",
                    icon: "brain",
                    color: theme.accentColor,
                    delta: focusDelta
                )
                SummaryCard(title: "Distraction", value: Theme.formatDuration(distractionSeconds),
                           icon: "eye.slash.fill", color: theme.errorColor)
                SummaryCard(title: "Sessions", value: "\(periodTimeSlots.filter { !$0.isIdle }.count)",
                           icon: "square.stack.fill", color: theme.infoColor)
                if appState.streakDays > 0 {
                    SummaryCard(title: "Streak", value: "\(appState.streakDays)d 🔥",
                               icon: "flame.fill", color: theme.warningColor)
                }
                if period == .day && appState.todaySwitchCount > 0 {
                    SummaryCard(title: "Switches", value: "\(appState.todaySwitchCount)",
                               icon: "arrow.left.arrow.right", color: .teal)
                }
                SummaryCard(title: "Peak Hours", value: peakHoursLabel,
                           icon: "chart.bar.xaxis", color: .indigo)
            }

            // 7-day sparkline
            if !sevenDayActivities.isEmpty {
                productivitySparkline
            }
        }
    }

    // MARK: - 7-day Sparkline
    private var productivitySparkline: some View {
        let first = sevenDayActivities.first?.score ?? 0
        let last = sevenDayActivities.last?.score ?? 0
        let trend = last - first
        return HStack(spacing: 10) {
            Chart(Array(sevenDayActivities.enumerated()), id: \.offset) { idx, item in
                LineMark(
                    x: .value("Day", idx),
                    y: .value("Score", item.score)
                )
                .foregroundStyle(theme.accentColor)
                .interpolationMethod(.catmullRom)
                AreaMark(
                    x: .value("Day", idx),
                    y: .value("Score", item.score)
                )
                .foregroundStyle(theme.accentColor.opacity(0.1))
                .interpolationMethod(.catmullRom)
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .chartYScale(domain: 0...100)
            .frame(maxWidth: .infinity)
            .frame(height: 50)

            VStack(alignment: .trailing, spacing: 2) {
                Image(systemName: trend >= 0 ? "arrow.up.right" : "arrow.down.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(trend >= 0 ? theme.successColor : theme.errorColor)
                Text("7-day trend")
                    .font(.caption2)
                    .foregroundStyle(theme.secondaryText)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(theme.cardBg)
        .cornerRadius(10)
    }

    // MARK: - Category Donut
    private var categoryDonut: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Category Breakdown")
                .font(.headline)

            if catStats.isEmpty {
                Text("No data for this period")
                    .font(.caption)
                    .foregroundStyle(theme.secondaryText)
                    .frame(height: 200)
            } else {
                Chart(catStats) { stat in
                    SectorMark(
                        angle: .value("Time", stat.totalSeconds),
                        innerRadius: .ratio(0.6),
                        angularInset: 1.5
                    )
                    .foregroundStyle(Theme.color(for: stat.category))
                    .opacity(selectedCatStat == nil || selectedCatStat?.id == stat.id ? 1.0 : 0.4)
                }
                .chartOverlay { _ in
                    GeometryReader { geo in
                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture { location in
                                let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
                                let dx = location.x - center.x
                                let dy = location.y - center.y
                                let dist = sqrt(dx * dx + dy * dy)
                                let chartRadius = min(geo.size.width, geo.size.height) / 2
                                let innerRadius = chartRadius * 0.6
                                guard dist >= innerRadius && dist <= chartRadius else {
                                    withAnimation(.easeInOut(duration: 0.15)) { selectedCatStat = nil }
                                    return
                                }
                                var angle = atan2(dy, dx) * 180 / .pi + 90
                                if angle < 0 { angle += 360 }
                                var cumulative = 0.0
                                let total = catStats.reduce(0.0) { $0 + $1.totalSeconds }
                                for stat in catStats {
                                    cumulative += stat.totalSeconds / total * 360
                                    if angle < cumulative {
                                        withAnimation(.easeInOut(duration: 0.15)) { selectedCatStat = stat }
                                        return
                                    }
                                }
                                withAnimation(.easeInOut(duration: 0.15)) { selectedCatStat = catStats.last }
                            }
                    }
                }
                .frame(height: 200)
                .overlay {
                    VStack(spacing: 2) {
                        if let selected = selectedCatStat ?? catStats.first {
                            Image(systemName: selected.category.icon)
                                .font(.title3)
                                .foregroundStyle(Theme.color(for: selected.category))
                            Text(selected.category.rawValue)
                                .font(.caption.bold())
                            Text(Theme.formatDuration(selected.totalSeconds))
                                .font(.caption2)
                                .foregroundStyle(theme.secondaryText)
                            Text("\(Int(selected.percentage))%")
                                .font(.caption2.bold())
                                .foregroundStyle(Theme.color(for: selected.category))
                        }
                    }
                    .allowsHitTesting(false)  // let taps pass through to chartOverlay
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
                                    .foregroundStyle(theme.secondaryText)
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
                .foregroundStyle(theme.secondaryText)
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
        let maxMins = hourlyStats.reduce(0.0) { max($0, $1.minutes) }
        let yDomain = max(60.0, ceil(maxMins / 15) * 15)
        return Chart(hourlyStats) { stat in
            BarMark(
                x: .value("Hour", stat.hour),
                y: .value("Minutes", stat.minutes),
                width: .fixed(max(8, 400.0 / 24.0 - 2))
            )
            .foregroundStyle(Theme.color(for: stat.category))
            .opacity(selectedHourStat == nil || selectedHourStat == stat.hour ? 1.0 : 0.5)
        }
        .chartXScale(domain: 0...23)
        .chartYScale(domain: 0...yDomain)
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
                .opacity(selectedHourStat == nil || selectedHourStat == stat.x ? 1.0 : 0.5)
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
                .opacity(selectedHourStat == nil || selectedHourStat == stat.x ? 1.0 : 0.5)
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

    private var periodProductivityFlow: some View {
        let avgScore: Double = {
            switch period {
            case .day:
                let pts = productivityByHour.filter { $0.hasData }
                return pts.isEmpty ? 0 : pts.reduce(0) { $0 + $1.score } / Double(pts.count)
            default:
                let pts = productivityByDay.filter { $0.hasData }
                return pts.isEmpty ? 0 : pts.reduce(0) { $0 + $1.score } / Double(pts.count)
            }
        }()

        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Productivity Flow")
                    .font(.headline)
                Spacer()
                if avgScore > 0 {
                    HStack(spacing: 4) {
                        Image(systemName: "minus")
                            .font(.caption2)
                            .foregroundStyle(theme.successColor.opacity(0.6))
                        Text("avg \(Int(avgScore))%")
                            .font(.caption2)
                            .foregroundStyle(theme.secondaryText)
                    }
                }
                Group {
                    if let x = selectedFlowHour {
                        Text(flowSelectionLabel(x))
                    } else {
                        Text(" ")
                    }
                }
                .font(.caption)
                .foregroundStyle(theme.secondaryText)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(theme.successColor.opacity(selectedFlowHour != nil ? 0.1 : 0))
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
        let validPoints = productivityByHour.filter { $0.hasData }
        return Group {
            if validPoints.isEmpty {
                Text("Not enough data to show productivity flow")
                    .font(.caption)
                    .foregroundStyle(theme.secondaryText)
                    .frame(height: 180, alignment: .center)
                    .frame(maxWidth: .infinity)
            } else {
                Chart(validPoints) { item in
                    AreaMark(x: .value("Hour", item.hour), y: .value("Score", item.score))
                        .foregroundStyle(LinearGradient(colors: [theme.successColor.opacity(0.35), theme.successColor.opacity(0.05)],
                                                       startPoint: .top, endPoint: .bottom))
                        .interpolationMethod(.monotone)
                    LineMark(x: .value("Hour", item.hour), y: .value("Score", item.score))
                        .foregroundStyle(theme.successColor)
                        .interpolationMethod(.monotone)
                        .lineStyle(StrokeStyle(lineWidth: 2))
                    if let sel = selectedFlowHour, sel == item.hour {
                        PointMark(x: .value("Hour", item.hour), y: .value("Score", item.score))
                            .foregroundStyle(theme.successColor).symbolSize(60)
                        RuleMark(x: .value("Hour", item.hour))
                            .foregroundStyle(theme.successColor.opacity(0.3))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4]))
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
        }
    }

    private func periodicFlowChart(data: [DayScore], domain: ClosedRange<Int>) -> some View {
        let filtered = data.filter { $0.hasData }
        return Group {
            if filtered.isEmpty {
                Text("Not enough data to show productivity flow")
                    .font(.caption)
                    .foregroundStyle(theme.secondaryText)
                    .frame(height: 180, alignment: .center)
                    .frame(maxWidth: .infinity)
            } else {
                Chart(filtered) { item in
                    AreaMark(x: .value("X", item.x), y: .value("Score", item.score))
                        .foregroundStyle(LinearGradient(colors: [theme.successColor.opacity(0.35), theme.successColor.opacity(0.05)],
                                                       startPoint: .top, endPoint: .bottom))
                        .interpolationMethod(.monotone)
                    LineMark(x: .value("X", item.x), y: .value("Score", item.score))
                        .foregroundStyle(theme.successColor)
                        .interpolationMethod(.monotone)
                        .lineStyle(StrokeStyle(lineWidth: 2))
                    if let sel = selectedFlowHour, sel == item.x {
                        PointMark(x: .value("X", item.x), y: .value("Score", item.score))
                            .foregroundStyle(theme.successColor).symbolSize(60)
                        RuleMark(x: .value("X", item.x))
                            .foregroundStyle(theme.successColor.opacity(0.3))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4]))
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
        }
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
                    .foregroundStyle(theme.primaryText)
                Spacer()
                VStack(alignment: .trailing, spacing: 1) {
                    Text(Theme.formatDuration(distractionSeconds))
                        .font(.subheadline.bold())
                        .foregroundStyle(theme.errorColor)
                    if totalActiveSeconds > 0 {
                        Text("\(Int(distractionSeconds / totalActiveSeconds * 100))% of active time")
                            .font(.caption2)
                            .foregroundStyle(theme.secondaryText)
                    }
                }
            }

            if distractionApps.isEmpty {
                Text("No distraction time recorded for this period")
                    .font(.caption)
                    .foregroundStyle(theme.secondaryText)
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
                                    .fill(theme.errorColor.opacity(0.12))
                                    .frame(height: 6)
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(theme.errorColor.opacity(0.5))
                                    .frame(width: max(4, geo.size.width * CGFloat(app.duration / max(distractionSeconds, 1))), height: 6)
                            }
                        }
                        .frame(width: 100, height: 6)
                        Text(Theme.formatDuration(app.duration))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(theme.secondaryText)
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
                    .foregroundStyle(theme.secondaryText)
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
                                .foregroundStyle(theme.secondaryText)
                        }
                        Spacer()
                        Text(Theme.formatDuration(app.duration))
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(theme.secondaryText)

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
                    .foregroundStyle(theme.secondaryText)
                Spacer()
                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(theme.secondaryText)
                    TextField("Search", text: $searchText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 180)
                }
            }

            if filteredSessions.isEmpty {
                Text("No sessions found")
                    .font(.caption)
                    .foregroundStyle(theme.secondaryText)
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
                                .foregroundStyle(theme.secondaryText)
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

                        Text(Theme.formatDuration(slot.activeDuration))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(theme.secondaryText)
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

    // MARK: - Timer & Tasks Content

    private var timerTasksContent: some View {
        VStack(spacing: 16) {
            timerSummaryCards
            timerTaskProgressCard
            timerStatsRow
            timerDailyChart.frame(maxWidth: .infinity)
            timerByModeCard.frame(maxWidth: .infinity)
            timerByTaskCard
            timerSessionsList
        }
    }

    private var filteredTimerSessions: [TimerSession] {
        let (from, to) = dateRange
        return todoStore.timerSessions.filter { $0.startedAt >= from && $0.startedAt < to }
    }

    private var timerTotalSeconds: Double { filteredTimerSessions.reduce(0) { $0 + $1.duration } }

    private var timerTaskProgressCard: some View {
        let periodTodoIds = Set(filteredTimerSessions.compactMap(\.todoId))
        let periodTodos = todoStore.todos.filter { periodTodoIds.contains($0.id) }
        let done = periodTodos.filter { $0.status == .done }.count
        let inProg = periodTodos.filter { $0.status == .inProgress }.count
        let pending = periodTodos.filter { $0.status == .pending }.count
        let total = periodTodos.count
        let rate = total > 0 ? Double(done) / Double(total) : 0

        return VStack(alignment: .leading, spacing: 12) {
            Text("Task Completion")
                .font(.headline)

            if total == 0 {
                Text("No tasks linked to sessions for this period")
                    .font(.caption).foregroundStyle(theme.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .center)
            } else {
                // Progress bar
                HStack {
                    Text("\(Int(rate * 100))% complete")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(theme.primaryText)
                    Spacer()
                    Text("\(done) / \(total)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(theme.secondaryText)
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(theme.dividerColor.opacity(0.15))
                            .frame(height: 8)
                        RoundedRectangle(cornerRadius: 4)
                            .fill(theme.successColor)
                            .frame(width: max(0, geo.size.width * CGFloat(rate)), height: 8)
                            .animation(.easeInOut, value: rate)
                    }
                }.frame(height: 8)

                // Status breakdown
                HStack(spacing: 0) {
                    statusPill(label: "Done", count: done, color: theme.successColor)
                    statusPill(label: "In Progress", count: inProg, color: theme.warningColor)
                    statusPill(label: "Pending", count: pending, color: theme.secondaryText)
                }
            }
        }
        .padding()
        .background(theme.cardBg)
        .cornerRadius(12)
    }

    @ViewBuilder
    private func statusPill(label: String, count: Int, color: Color) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label).font(.caption).foregroundStyle(theme.secondaryText)
            Text("\(count)")
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(theme.primaryText)
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .padding(.trailing, 8)
    }

    private var timerSummaryCards: some View {
        HStack(spacing: 12) {
            SummaryCard(title: "Timer Total", value: timerTotalSeconds >= 60 ? Theme.formatDuration(timerTotalSeconds) : "—",
                       icon: "timer", color: theme.accentColor)
            let pomodoroSessions = filteredTimerSessions.filter { $0.mode == .pomodoro }.count
            SummaryCard(title: "Pomodoros", value: pomodoroSessions > 0 ? "\(pomodoroSessions)" : "—",
                       icon: "circle.fill", color: theme.errorColor)
            let periodTodoIds = Set(filteredTimerSessions.compactMap(\.todoId))
            let periodTodos = todoStore.todos.filter { periodTodoIds.contains($0.id) }
            let activeTodos = periodTodos.filter { $0.status != .done }.count
            SummaryCard(title: "Tasks in Period", value: periodTodos.isEmpty ? "—" : "\(activeTodos)", icon: "checklist", color: theme.infoColor)
            let doneTodos = periodTodos.filter { $0.status == .done }.count
            let totalPeriod = periodTodos.count
            SummaryCard(title: "Completed", value: totalPeriod > 0 ? "\(doneTodos)/\(totalPeriod)" : "—",
                       icon: "checkmark.circle.fill", color: theme.successColor)
        }
    }

    private var timerStatsRow: some View {
        let sessions = filteredTimerSessions
        let totalSecs = timerTotalSeconds
        let avgSecs = sessions.isEmpty ? 0 : totalSecs / Double(sessions.count)
        let longestSecs = sessions.map(\.duration).max() ?? 0
        let cal = Calendar.current
        var hourDict: [Int: Double] = [:]
        for s in sessions { hourDict[cal.component(.hour, from: s.startedAt), default: 0] += s.duration }
        let peakHour = hourDict.max(by: { $0.value < $1.value })?.key
        let peakLabel: String = peakHour.map { h in
            h == 0 ? "12am" : h < 12 ? "\(h)am" : h == 12 ? "12pm" : "\(h-12)pm"
        } ?? "—"

        return HStack(spacing: 12) {
            StatMiniCard(title: "Avg Session", value: avgSecs >= 60 ? Theme.formatDuration(avgSecs) : "—")
            StatMiniCard(title: "Longest", value: longestSecs >= 60 ? Theme.formatDuration(longestSecs) : "—")
            StatMiniCard(title: "Peak Hour", value: peakLabel)
            StatMiniCard(title: "Sessions", value: "\(sessions.count)")
        }
    }

    private var timerByModeCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("By Mode")
                .font(.headline)

            let byMode: [(mode: TimerMode, duration: Double)] = {
                var dict: [String: Double] = [:]
                for s in filteredTimerSessions { dict[s.mode.rawValue, default: 0] += s.duration }
                return dict.map { (TimerMode(rawValue: $0.key) ?? .stopwatch, $0.value) }
                           .sorted { $0.duration > $1.duration }
            }()

            if byMode.isEmpty {
                Text("No sessions for this period")
                    .font(.caption).foregroundStyle(theme.secondaryText)
                    .frame(maxWidth: .infinity, minHeight: 80, alignment: .center)
            } else {
                ForEach(byMode, id: \.mode) { item in
                    let fraction = timerTotalSeconds > 0 ? item.duration / timerTotalSeconds : 0
                    HStack(spacing: 8) {
                        Image(systemName: item.mode.icon)
                            .font(.caption).frame(width: 16)
                            .foregroundStyle(theme.accentColor)
                        Text(item.mode.rawValue).font(.caption.weight(.medium))
                        Spacer()
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 3).fill(theme.accentColor.opacity(0.1)).frame(height: 6)
                                RoundedRectangle(cornerRadius: 3).fill(theme.accentColor.opacity(0.6))
                                    .frame(width: max(4, geo.size.width * CGFloat(fraction)), height: 6)
                            }
                        }.frame(width: 80, height: 6)
                        Text(Theme.formatDuration(item.duration))
                            .font(.caption.monospacedDigit()).foregroundStyle(theme.secondaryText).frame(width: 52, alignment: .trailing)
                    }
                }
            }
        }
        .padding()
        .background(theme.cardBg)
        .cornerRadius(12)
    }

    private var timerDailyChart: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(period == .day ? "Hourly Sessions" : "Daily Sessions")
                .font(.headline)

            let data: [(x: Int, minutes: Double)] = {
                let cal = Calendar.current
                let (from, _) = dateRange
                var dict: [Int: Double] = [:]
                for s in filteredTimerSessions {
                    let x: Int
                    switch period {
                    case .day: x = cal.component(.hour, from: s.startedAt)
                    case .week:
                        let diff = cal.dateComponents([.day], from: cal.startOfDay(for: from),
                                                      to: cal.startOfDay(for: s.startedAt)).day ?? 0
                        x = max(0, min(6, diff))
                    case .month: x = cal.component(.day, from: s.startedAt)
                    }
                    dict[x, default: 0] += s.duration / 60
                }
                return dict.map { ($0.key, $0.value) }.sorted { $0.x < $1.x }
            }()

            if data.isEmpty {
                Text("No sessions for this period")
                    .font(.caption).foregroundStyle(theme.secondaryText)
                    .frame(maxWidth: .infinity, minHeight: 120, alignment: .center)
            } else {
                Chart(data, id: \.x) { item in
                    BarMark(x: .value("X", item.x), y: .value("Min", item.minutes))
                        .foregroundStyle(theme.accentColor.opacity(0.7))
                }
                .chartYScale(domain: period == .day ? 0.0...60.0 : 0.0...Double((data.map(\.minutes).max().map { Int($0) } ?? 60) + 5))
                .chartXAxis {
                    if period == .week {
                        let names = ["Mon","Tue","Wed","Thu","Fri","Sat","Sun"]
                        AxisMarks(values: Array(0...6)) { v in
                            AxisValueLabel { if let i = v.as(Int.self) { Text(names[i]).font(.caption2) } }
                            AxisGridLine()
                        }
                    } else {
                        AxisMarks { v in
                            AxisValueLabel { if let i = v.as(Int.self) { Text("\(i)").font(.caption2) } }
                            AxisGridLine()
                        }
                    }
                }
                .chartYAxis {
                    AxisMarks { v in
                        AxisValueLabel { if let i = v.as(Double.self) { Text("\(Int(i))m").font(.caption2) } }
                        AxisGridLine()
                    }
                }
                .frame(height: 120)
            }
        }
        .padding()
        .background(theme.cardBg)
        .cornerRadius(12)
    }

    @ViewBuilder
    private func statusBadge(_ status: TodoStatus) -> some View {
        let (label, color): (String, Color) = {
            switch status {
            case .done:       return ("Done", theme.successColor)
            case .inProgress: return ("Active", theme.warningColor)
            case .pending:    return ("Pending", theme.secondaryText)
            }
        }()
        Text(label)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(color.opacity(0.12), in: Capsule())
    }


    private var timerByTaskCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Time by Task")
                .font(.headline)

            let byTask: [(todo: TodoItem?, duration: Double)] = {
                var dict: [String?: Double] = [:]
                for s in filteredTimerSessions { dict[s.todoId, default: 0] += s.duration }
                return dict.map { (todoId, dur) -> (TodoItem?, Double) in
                    let t = todoId.flatMap { id in todoStore.todos.first { $0.id == id } }
                    return (t, dur)
                }.sorted { $0.1 > $1.1 }
            }()

            if byTask.isEmpty {
                Text("No sessions linked to tasks for this period")
                    .font(.caption).foregroundStyle(theme.secondaryText)
                    .frame(maxWidth: .infinity, minHeight: 60, alignment: .center)
            } else {
                ForEach(Array(byTask.enumerated()), id: \.offset) { _, item in
                    HStack(spacing: 10) {
                        Circle()
                            .fill(item.todo?.priority.color ?? .secondary)
                            .frame(width: 8, height: 8)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.todo?.title ?? "Unlinked")
                                .font(.subheadline.weight(.medium)).lineLimit(1)
                            if let todo = item.todo {
                                Text(todo.status.rawValue.capitalized)
                                    .font(.caption2).foregroundStyle(theme.secondaryText)
                            }
                        }
                        Spacer()
                        let fraction = timerTotalSeconds > 0 ? item.duration / timerTotalSeconds : 0
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 3).fill(theme.dividerColor.opacity(0.1)).frame(height: 6)
                                RoundedRectangle(cornerRadius: 3).fill(theme.accentColor.opacity(0.55))
                                    .frame(width: max(4, geo.size.width * CGFloat(fraction)), height: 6)
                            }
                        }.frame(width: 100, height: 6)
                        Text(Theme.formatDuration(item.duration))
                            .font(.caption.monospacedDigit()).foregroundStyle(theme.secondaryText).frame(width: 52, alignment: .trailing)
                    }
                    .padding(.vertical, 3)
                }
            }
        }
        .padding()
        .background(theme.cardBg)
        .cornerRadius(12)
    }

    private var timerSessionsList: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Sessions")
                    .font(.headline)
                Text("(\(filteredTimerSessions.count))")
                    .font(.caption).foregroundStyle(theme.secondaryText)
                Spacer()
            }

            if filteredTimerSessions.isEmpty {
                Text("No timer sessions for this period")
                    .font(.caption).foregroundStyle(theme.secondaryText)
                    .frame(maxWidth: .infinity, minHeight: 60, alignment: .center)
            } else {
                let sorted = filteredTimerSessions.sorted { $0.startedAt > $1.startedAt }
                ForEach(sorted.prefix(20)) { session in
                    HStack(spacing: 10) {
                        Image(systemName: session.mode.icon)
                            .font(.caption)
                            .foregroundStyle(theme.accentColor)
                            .frame(width: 20)
                        VStack(alignment: .leading, spacing: 2) {
                            if let todoId = session.todoId,
                               let todo = todoStore.todos.first(where: { $0.id == todoId }) {
                                HStack(spacing: 6) {
                                    Text(todo.title).font(.subheadline.weight(.medium)).lineLimit(1)
                                    statusBadge(todo.status)
                                }
                            } else {
                                Text(session.mode.rawValue).font(.subheadline.weight(.medium))
                            }
                            Text(Theme.formatTimeRange(session.startedAt, session.endedAt))
                                .font(.caption2).foregroundStyle(theme.secondaryText)
                        }
                        Spacer()
                        Text(Theme.formatDuration(session.duration))
                            .font(.caption.monospacedDigit()).foregroundStyle(theme.secondaryText)
                    }
                    .padding(.vertical, 3)
                    Divider()
                }
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

        // Load 7-day sparkline data (always for last 7 days from today)
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        sevenDayActivities = (0..<7).map { offset in
            let day = cal.date(byAdding: .day, value: -(6 - offset), to: today)!
            let nextDay = cal.date(byAdding: .day, value: 1, to: day)!
            let acts = (try? Database.shared.activitiesForRange(from: day, to: nextDay)) ?? []
            let total = acts.filter { !$0.isIdle }.reduce(0.0) { $0 + $1.duration }
            let prod = acts.filter { $0.category.isProductive }.reduce(0.0) { $0 + $1.duration }
            let score = total > 0 ? prod / total * 100 : 0
            return (date: day, score: score)
        }

        // Load previous period for comparison
        let prevRange = previousPeriodRange
        let prevActivities = (try? Database.shared.activitiesForRange(from: prevRange.from, to: prevRange.to)) ?? []
        previousPeriodActive = prevActivities.filter { !$0.isIdle }.reduce(0.0) { $0 + $1.duration }
        let prevTotal = previousPeriodActive
        let prevProd = prevActivities.filter { $0.category.isProductive }.reduce(0.0) { $0 + $1.duration }
        previousPeriodFocus = prevTotal > 0 ? prevProd / prevTotal * 100 : 0

        // Cache expensive computations once
        let acts = allActivities
        let per = period
        let selDate = selectedDate

        cachedTotalActive = acts.filter { !$0.isIdle }.reduce(0) { $0 + $1.duration }
        let totalAct = cachedTotalActive
        cachedProductivePercent = totalAct > 0 ? acts.filter { $0.category.isProductive }.reduce(0) { $0 + $1.duration } / totalAct * 100 : 0

        var apps: [String: (bundleID: String, category: Category, duration: Double, timestamps: [Date])] = [:]
        for a in acts where !a.isIdle {
            var entry = apps[a.appName] ?? (a.bundleID, a.category, 0, [])
            entry.duration += a.duration
            entry.timestamps.append(a.timestamp)
            apps[a.appName] = entry
        }
        cachedAppUsages = apps.map { (name, val) in
            AppUsageInfo(appName: name, bundleID: val.bundleID, category: val.category,
                        duration: val.duration, timestamps: val.timestamps.sorted())
        }.sorted { $0.duration > $1.duration }

        cachedDistractionSecs = acts.filter { $0.category.rawValue == "Distraction" }.reduce(0) { $0 + $1.duration }

        var hourProd: [Int: (prod: Double, total: Double)] = [:]
        for a in acts where !a.isIdle {
            let hour = cal.component(.hour, from: a.timestamp)
            var entry = hourProd[hour] ?? (0, 0)
            entry.total += a.duration
            if a.category.isProductive { entry.prod += a.duration }
            hourProd[hour] = entry
        }
        cachedHourlyScores = (0...23).map { hour in
            let entry = hourProd[hour]
            let totalMins = (entry?.total ?? 0) / 60
            let score: Double = (entry != nil && entry!.total >= 300) ? entry!.prod / entry!.total * 100 : 0
            return HourScore(hour: hour, score: score, hasData: (entry?.total ?? 0) >= 300, totalMinutes: totalMins)
        }

        if per != .day {
            let (fromDate, _) = dateRange
            var dayData: [Int: (prod: Double, total: Double)] = [:]
            for a in acts where !a.isIdle {
                let x: Int
                switch per {
                case .week:
                    let diff = cal.dateComponents([.day], from: cal.startOfDay(for: fromDate), to: cal.startOfDay(for: a.timestamp)).day ?? 0
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
            let daysInMonth = cal.range(of: .day, in: .month, for: selDate)?.count ?? 31
            let (start, count) = per == .week ? (0, 7) : (1, daysInMonth)
            cachedDayScores = (start..<(start + count)).map { x in
                let e = dayData[x]
                let totalMins = (e?.total ?? 0) / 60
                let score: Double = (e != nil && e!.total >= 900) ? e!.prod / e!.total * 100 : 0
                return DayScore(x: x, score: score, hasData: (e?.total ?? 0) >= 900, totalMinutes: totalMins)
            }

            var dayCats: [Int: [String: Double]] = [:]
            for a in acts where !a.isIdle {
                let x: Int
                switch per {
                case .week:
                    let diff = cal.dateComponents([.day], from: cal.startOfDay(for: fromDate), to: cal.startOfDay(for: a.timestamp)).day ?? 0
                    x = max(0, min(6, diff))
                case .month:
                    x = cal.component(.day, from: a.timestamp)
                default: continue
                }
                dayCats[x, default: [:]][a.category.rawValue, default: 0] += a.duration / 60
            }
            let allCatNames = Set(dayCats.values.flatMap(\.keys)).sorted()
            var result: [DayStat] = []
            let daysInMonth2 = cal.range(of: .day, in: .month, for: selDate)?.count ?? 31
            let (start2, count2) = per == .week ? (0, 7) : (1, daysInMonth2)
            for x in start2..<(start2 + count2) {
                for catName in allCatNames {
                    let mins = dayCats[x]?[catName] ?? 0
                    if mins > 0 { result.append(DayStat(x: x, category: Category(rawValue: catName), minutes: mins)) }
                }
            }
            cachedDailyStats = result
        } else {
            cachedDayScores = []
            cachedDailyStats = []
        }
    }

    private var previousPeriodRange: (from: Date, to: Date) {
        let cal = Calendar.current
        let (from, _) = dateRange
        switch period {
        case .day:
            return (cal.date(byAdding: .day, value: -1, to: from)!, from)
        case .week:
            return (cal.date(byAdding: .weekOfYear, value: -1, to: from)!, from)
        case .month:
            return (cal.date(byAdding: .month, value: -1, to: from)!, from)
        }
    }

    private var activeDelta: String? {
        guard previousPeriodActive > 0 else { return nil }
        let pct = (totalActiveSeconds - previousPeriodActive) / previousPeriodActive * 100
        let sign = pct >= 0 ? "+" : ""
        return "\(sign)\(Int(pct))%"
    }

    private var focusDelta: String? {
        guard previousPeriodFocus > 0 else { return nil }
        let diff = productivePercent - previousPeriodFocus
        let sign = diff >= 0 ? "+" : ""
        return "\(sign)\(Int(diff))%"
    }

    private var dateRange: (from: Date, to: Date) {
        let cal = Calendar.current
        switch period {
        case .day:
            let start = cal.startOfDay(for: selectedDate)
            return (start, cal.date(byAdding: .day, value: 1, to: start)!)
        case .week:
            let weekday = cal.component(.weekday, from: selectedDate)
            // weekday: 1=Sun,2=Mon,...,7=Sat. Compute days back to most recent Monday.
            let daysFromMonday = (weekday + 5) % 7  // Sun→6, Mon→0, Tue→1, ..., Sat→5
            let start = cal.date(byAdding: .day, value: -daysFromMonday, to: cal.startOfDay(for: selectedDate))!
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
        case .day: selectedDate = cal.date(byAdding: .day, value: -1, to: selectedDate) ?? selectedDate
        case .week: selectedDate = cal.date(byAdding: .weekOfYear, value: -1, to: selectedDate) ?? selectedDate
        case .month: selectedDate = cal.date(byAdding: .month, value: -1, to: selectedDate) ?? selectedDate
        }
    }

    private func navigateForward() {
        let cal = Calendar.current
        switch period {
        case .day: selectedDate = cal.date(byAdding: .day, value: 1, to: selectedDate) ?? selectedDate
        case .week: selectedDate = cal.date(byAdding: .weekOfYear, value: 1, to: selectedDate) ?? selectedDate
        case .month: selectedDate = cal.date(byAdding: .month, value: 1, to: selectedDate) ?? selectedDate
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

    private var productivityByHour: [HourScore] { cachedHourlyScores }

    private var distractionSeconds: Double { cachedDistractionSecs }

    private var distractionApps: [AppUsageInfo] {
        appUsages.filter { $0.category.rawValue == "Distraction" }
    }

    private var peakHoursLabel: String {
        let cal = Calendar.current
        // Aggregate productive time per hour
        var hourProd: [Int: Double] = [:]
        for a in allActivities where !a.isIdle && a.category.isProductive {
            let h = cal.component(.hour, from: a.timestamp)
            hourProd[h, default: 0] += a.duration
        }
        guard !hourProd.isEmpty else { return "—" }
        // Find best 2-consecutive-hour window
        var bestHour = hourProd.max(by: { $0.value < $1.value })!.key
        var bestTotal = 0.0
        for h in 0..<23 {
            let t = (hourProd[h] ?? 0) + (hourProd[h + 1] ?? 0)
            if t > bestTotal { bestTotal = t; bestHour = h }
        }
        func fmt(_ h: Int) -> String {
            h == 0 ? "12am" : h < 12 ? "\(h)am" : h == 12 ? "12pm" : "\(h - 12)pm"
        }
        return "\(fmt(bestHour))–\(fmt(bestHour + 2))"
    }

    private var daysInCurrentMonth: Int {
        Calendar.current.range(of: .day, in: .month, for: selectedDate)?.count ?? 31
    }

    private var dailyActivityStats: [DayStat] { cachedDailyStats }

    private var productivityByDay: [DayScore] { cachedDayScores }

    private var totalActiveSeconds: Double { cachedTotalActive }

    private var productivePercent: Double { cachedProductivePercent }

    private var topAppName: String {
        appUsages.first?.appName ?? "—"
    }

    private var appUsages: [AppUsageInfo] { cachedAppUsages }

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
    let totalMinutes: Double
    var id: Int { x }
}

struct HourScore: Identifiable {
    let id = UUID()
    let hour: Int
    let score: Double
    let hasData: Bool
    let totalMinutes: Double

    init(hour: Int, score: Double, hasData: Bool = true, totalMinutes: Double = 0) {
        self.hour = hour
        self.score = score
        self.hasData = hasData
        self.totalMinutes = totalMinutes
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
    var delta: String? = nil
    private var theme: AppTheme { AppSettings.shared.appTheme }

    private func deltaColor(_ d: String) -> Color {
        d.hasPrefix("+") ? AppSettings.shared.appTheme.successColor : AppSettings.shared.appTheme.errorColor
    }

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
                .foregroundStyle(theme.secondaryText)
            if let d = delta {
                Text(d)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(deltaColor(d))
            }
        }
        .frame(maxWidth: .infinity, minHeight: 80)
        .padding(.vertical, 12)
        .background(AppSettings.shared.appTheme.cardBg)
        .cornerRadius(10)
    }
}

// MARK: - Stat Mini Card
private struct StatMiniCard: View {
    let title: String
    let value: String
    private var theme: AppTheme { AppSettings.shared.appTheme }
    var body: some View {
        VStack(spacing: 4) {
            Text(value).font(.title3.weight(.semibold))
            Text(title).font(.caption2).foregroundStyle(theme.secondaryText)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(theme.cardBg)
        .cornerRadius(10)
    }
}

// MARK: - App Detail Sheet
struct AppDetailSheet: View {
    let app: AppUsageInfo
    let allActivities: [ActivityRecord]
    @Environment(\.dismiss) private var dismiss
    private var theme: AppTheme { AppSettings.shared.appTheme }

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
                            .foregroundStyle(theme.secondaryText)
                    }
                }
                Spacer()
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(theme.secondaryText)
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
                        .foregroundStyle(theme.secondaryText)
                }
                VStack {
                    Text("\(uniqueTitles.count)")
                        .font(.title3.bold())
                    Text("Windows")
                        .font(.caption)
                        .foregroundStyle(theme.secondaryText)
                }
                VStack {
                    Text("\(appActivities.count)")
                        .font(.title3.bold())
                    Text("Records")
                        .font(.caption)
                        .foregroundStyle(theme.secondaryText)
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
                                    .foregroundStyle(theme.secondaryText)
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
                        .foregroundStyle(theme.secondaryText)
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
    private var theme: AppTheme { AppSettings.shared.appTheme }

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
                        .foregroundStyle(theme.secondaryText)
                }
                Spacer()
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(theme.secondaryText)
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
                                .foregroundStyle(theme.secondaryText)
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
