import SwiftUI

struct HeatmapView: View {
    @Bindable var appState = AppState.shared
    @State private var weeklyData: [[Double]] = []
    @State private var yearlyData: [Date: Double] = [:]
    @State private var weekOffset = 0
    @State private var hoveredCell: (day: Int, hour: Int)?
    @State private var hoveredYearDay: Date?

    private var theme: AppTheme { AppSettings.shared.appTheme }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                weeklyHeatmap
                Divider().padding(.horizontal)
                yearlyHeatmap
            }
            .padding()
        }
        .background(theme.timelineBg)
        .onAppear { loadData() }
    }

    // MARK: - Weekly 24×7 Heatmap
    private var weeklyHeatmap: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Weekly Activity")
                    .font(.title2.bold())
                Spacer()
                HStack(spacing: 12) {
                    Button(action: { weekOffset -= 1; loadData() }) {
                        Image(systemName: "chevron.left")
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.bordered)

                    Text(weekLabel)
                        .font(.subheadline.bold())
                        .frame(minWidth: 160)

                    Button(action: { weekOffset += 1; loadData() }) {
                        Image(systemName: "chevron.right")
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.bordered)

                    if weekOffset != 0 {
                        Button("This Week") { weekOffset = 0; loadData() }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                }
            }

            // Grid: rows = hours (0-23), columns = days (Mon-Sun)
            VStack(spacing: 1) {
                // Day headers
                HStack(spacing: 1) {
                    Text("")
                        .frame(width: 44)
                    ForEach(weekDays, id: \.self) { day in
                        Text(shortDayLabel(day))
                            .font(.caption2.bold())
                            .frame(maxWidth: .infinity)
                    }
                }
                .padding(.bottom, 4)

                ForEach(0..<24, id: \.self) { hour in
                    HStack(spacing: 1) {
                        Text(hourLabel24(hour))
                            .font(.system(size: 9))
                            .foregroundStyle(theme.hourLabelColor)
                            .frame(width: 44, alignment: .trailing)

                        ForEach(0..<7, id: \.self) { dayIndex in
                            let focusVal = weeklyData.isEmpty ? 0 : weeklyData[dayIndex][hour]
                            let intensity = min(focusVal / 60.0, 1.0) // 60 min = max

                            RoundedRectangle(cornerRadius: 2)
                                .fill(cellColor(intensity: intensity, value: focusVal))
                                .frame(maxWidth: .infinity)
                                .frame(height: 14)
                                .overlay {
                                    if hoveredCell?.day == dayIndex && hoveredCell?.hour == hour {
                                        RoundedRectangle(cornerRadius: 2)
                                            .stroke(Color.primary, lineWidth: 1)
                                    }
                                }
                                .onHover { isHovering in
                                    hoveredCell = isHovering ? (day: dayIndex, hour: hour) : nil
                                }
                                .popover(isPresented: Binding(
                                    get: { hoveredCell?.day == dayIndex && hoveredCell?.hour == hour && focusVal > 0 },
                                    set: { _ in }
                                )) {
                                    VStack(spacing: 4) {
                                        Text("\(shortDayLabel(weekDays[dayIndex])) \(hourLabel24(hour))")
                                            .font(.caption.bold())
                                        Text("\(Int(focusVal))m productive")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    .padding(8)
                                }
                        }
                    }
                }
            }
            .padding()
            .background(theme.cardBg)
            .cornerRadius(12)

            // Legend
            HStack(spacing: 8) {
                Text("Less")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                ForEach([0.0, 0.25, 0.5, 0.75, 1.0], id: \.self) { level in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(cellColor(intensity: level, value: level * 60))
                        .frame(width: 12, height: 12)
                }
                Text("More")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Yearly GitHub-style Heatmap
    private var yearlyHeatmap: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Yearly Focus")
                .font(.title2.bold())

            VStack(alignment: .leading, spacing: 2) {
                // Month labels
                HStack(spacing: 2) {
                    Text("").frame(width: 28)
                    ForEach(monthLabels, id: \.offset) { m in
                        Text(m.label)
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                            .frame(width: CGFloat(m.weeks) * 13, alignment: .leading)
                    }
                }

                // Day labels + grid
                let weeks = yearWeeks
                HStack(alignment: .top, spacing: 0) {
                    // Day-of-week labels
                    VStack(spacing: 2) {
                        ForEach(0..<7, id: \.self) { dow in
                            Text(dow % 2 == 1 ? ["", "Mon", "", "Wed", "", "Fri", ""][dow] : "")
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                                .frame(width: 28, height: 11, alignment: .trailing)
                        }
                    }

                    // The grid
                    HStack(spacing: 2) {
                        ForEach(0..<weeks.count, id: \.self) { weekIdx in
                            VStack(spacing: 2) {
                                ForEach(0..<weeks[weekIdx].count, id: \.self) { dayIdx in
                                    let day = weeks[weekIdx][dayIdx]
                                    let hours = yearlyData[Calendar.current.startOfDay(for: day)] ?? 0
                                    let intensity = min(hours / 28800, 1.0) // 8h max

                                    RoundedRectangle(cornerRadius: 2)
                                        .fill(yearCellColor(intensity: intensity, date: day))
                                        .frame(width: 11, height: 11)
                                        .onHover { isHovering in
                                            hoveredYearDay = isHovering ? day : nil
                                        }
                                        .popover(isPresented: Binding(
                                            get: { hoveredYearDay == day && hours > 0 },
                                            set: { _ in }
                                        )) {
                                            VStack(spacing: 4) {
                                                Text(fullDateLabel(day))
                                                    .font(.caption.bold())
                                                Text(Theme.formatDuration(hours) + " productive")
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)
                                            }
                                            .padding(8)
                                        }
                                }
                                // Pad short weeks
                                if weeks[weekIdx].count < 7 {
                                    ForEach(0..<(7 - weeks[weekIdx].count), id: \.self) { _ in
                                        Color.clear.frame(width: 11, height: 11)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .padding()
            .background(theme.cardBg)
            .cornerRadius(12)

            // Legend
            HStack(spacing: 8) {
                Text("Less")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                ForEach([0.0, 0.25, 0.5, 0.75, 1.0], id: \.self) { level in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(yearCellColor(intensity: level, date: Date()))
                        .frame(width: 12, height: 12)
                }
                Text("More")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(Int(yearlyData.values.reduce(0, +) / 3600))h total productive this year")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Data Loading
    private func loadData() {
        loadWeeklyData()
        loadYearlyData()
    }

    private func loadWeeklyData() {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let baseDate = cal.date(byAdding: .weekOfYear, value: weekOffset, to: today)!
        let weekday = cal.component(.weekday, from: baseDate)
        let startOfWeek = cal.date(byAdding: .day, value: -(weekday - 1), to: baseDate)!

        var result: [[Double]] = Array(repeating: Array(repeating: 0, count: 24), count: 7)

        for dayIdx in 0..<7 {
            let day = cal.date(byAdding: .day, value: dayIdx, to: startOfWeek)!
            guard let activities = try? Database.shared.activitiesForDate(day) else { continue }
            for a in activities where !a.isIdle && a.category.isProductive {
                let hour = cal.component(.hour, from: a.timestamp)
                result[dayIdx][hour] += a.duration / 60.0 // convert to minutes
            }
        }
        weeklyData = result
    }

    private func loadYearlyData() {
        let cal = Calendar.current
        let now = Date()
        let startOfYear = cal.date(from: cal.dateComponents([.year], from: now))!
        let endOfYear = cal.date(byAdding: .year, value: 1, to: startOfYear)!
        let today = cal.startOfDay(for: now)

        // Only load up to today
        let end = min(endOfYear, cal.date(byAdding: .day, value: 1, to: today)!)

        var result: [Date: Double] = [:]

        // Load in weekly batches for efficiency
        var current = startOfYear
        while current < end {
            let weekEnd = min(cal.date(byAdding: .day, value: 7, to: current)!, end)
            if let activities = try? Database.shared.activitiesForRange(from: current, to: weekEnd) {
                for a in activities where !a.isIdle && a.category.isProductive {
                    let day = cal.startOfDay(for: a.timestamp)
                    result[day, default: 0] += a.duration
                }
            }
            current = weekEnd
        }
        yearlyData = result
    }

    // MARK: - Helpers
    private var weekDays: [Date] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let baseDate = cal.date(byAdding: .weekOfYear, value: weekOffset, to: today)!
        let weekday = cal.component(.weekday, from: baseDate)
        let start = cal.date(byAdding: .day, value: -(weekday - 1), to: baseDate)!
        return (0..<7).map { cal.date(byAdding: .day, value: $0, to: start)! }
    }

    private var weekLabel: String {
        let days = weekDays
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return "\(f.string(from: days.first!)) – \(f.string(from: days.last!))"
    }

    private func shortDayLabel(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "EEE"
        return f.string(from: date)
    }

    private func hourLabel24(_ hour: Int) -> String {
        String(format: "%02d:00", hour)
    }

    private func fullDateLabel(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "MMM d, yyyy"
        return f.string(from: date)
    }

    private func cellColor(intensity: Double, value: Double) -> Color {
        if value <= 0 { return theme.gridLineColor.opacity(0.3) }
        return theme.accentColor.opacity(max(0.15, intensity))
    }

    private func yearCellColor(intensity: Double, date: Date) -> Color {
        if intensity <= 0 { return Color.green.opacity(0.06) }
        return Color.green.opacity(max(0.15, intensity * 0.85))
    }

    // MARK: - Yearly Grid Computation
    private var yearWeeks: [[Date]] {
        let cal = Calendar.current
        let now = Date()
        let startOfYear = cal.date(from: cal.dateComponents([.year], from: now))!
        let today = cal.startOfDay(for: now)

        var weeks: [[Date]] = []
        var currentWeek: [Date] = []
        var day = startOfYear

        while day <= today {
            let weekday = cal.component(.weekday, from: day) // 1=Sun
            if weekday == 1 && !currentWeek.isEmpty {
                weeks.append(currentWeek)
                currentWeek = []
            }
            currentWeek.append(day)
            day = cal.date(byAdding: .day, value: 1, to: day)!
        }
        if !currentWeek.isEmpty {
            weeks.append(currentWeek)
        }
        return weeks
    }

    private struct MonthLabel: Identifiable {
        let offset: Int
        let label: String
        let weeks: Int
        var id: Int { offset }
    }

    private var monthLabels: [MonthLabel] {
        let cal = Calendar.current
        let now = Date()
        let startOfYear = cal.date(from: cal.dateComponents([.year], from: now))!
        let today = cal.startOfDay(for: now)

        var labels: [MonthLabel] = []
        var currentMonth = cal.component(.month, from: startOfYear)
        var weeksInMonth = 0
        var weekIdx = 0

        for week in yearWeeks {
            guard let firstDay = week.first else { continue }
            let month = cal.component(.month, from: firstDay)
            if month != currentMonth {
                let f = DateFormatter()
                f.dateFormat = "MMM"
                let d = cal.date(from: DateComponents(year: cal.component(.year, from: now), month: currentMonth))!
                labels.append(MonthLabel(offset: weekIdx - weeksInMonth, label: f.string(from: d), weeks: weeksInMonth))
                currentMonth = month
                weeksInMonth = 0
            }
            weeksInMonth += 1
            weekIdx += 1
        }
        // Last month
        if weeksInMonth > 0 {
            let f = DateFormatter()
            f.dateFormat = "MMM"
            let d = Calendar.current.date(from: DateComponents(year: cal.component(.year, from: now), month: currentMonth))!
            labels.append(MonthLabel(offset: weekIdx - weeksInMonth, label: f.string(from: d), weeks: weeksInMonth))
        }
        return labels
    }
}
