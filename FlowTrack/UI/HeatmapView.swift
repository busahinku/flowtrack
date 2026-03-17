import SwiftUI

struct HeatmapView: View {
    @Bindable var appState = AppState.shared
    @State private var weeklyData: [[Double]] = []
    @State private var yearlyData: [Date: Double] = [:]
    @State private var weekOffset = 0
    @State private var yearOffset = 0
    @State private var hoveredCell: (day: Int, hour: Int)?
    @State private var hoveredYearDay: Date?
    @State private var showWeekDatePicker = false
    @State private var weekPickerDate = Date()

    @Environment(Theme.self) private var theme
    private let cellSize: CGFloat = 18

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                weeklyHeatmap
                Divider().padding(.horizontal)
                yearlyHeatmap
            }
            .padding()
        }
        .background(theme.timelineBackgroundColor)
        .toolbarBackground(.hidden, for: .windowToolbar)
        .onAppear { loadData() }
        .toolbar {
            ToolbarItem(placement: .principal) {
                heatmapWeekNav
            }
            ToolbarItem(placement: .primaryAction) {
                weeklyStats
            }
        }
    }

    private var heatmapWeekNav: some View {
        HStack(spacing: 2) {
            Button(action: { weekOffset -= 1; loadData() }) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(theme.secondaryTextColor)

            Button(action: { showWeekDatePicker.toggle() }) {
                Text(weekLabel)
                    .font(.headline)
                    .frame(minWidth: 90)
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showWeekDatePicker) {
                DatePicker("", selection: $weekPickerDate, displayedComponents: .date)
                    .labelsHidden()
                    .datePickerStyle(.graphical)
                    .padding(8)
                    .frame(width: 300, height: 320)
                    .onChange(of: weekPickerDate) {
                        let cal = Calendar.current
                        let today = cal.startOfDay(for: Date())
                        let diff = cal.dateComponents([.weekOfYear], from: today, to: weekPickerDate)
                        weekOffset = diff.weekOfYear ?? 0
                        loadData()
                        showWeekDatePicker = false
                    }
            }

            Button(action: { weekOffset += 1; loadData() }) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(theme.secondaryTextColor)

            if weekOffset != 0 {
                Button("This Week") { weekOffset = 0; loadData() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
    }

    @ViewBuilder
    private var weeklyStats: some View {
        if !weeklyData.isEmpty {
            let totalMinutes = weeklyData.flatMap { $0 }.reduce(0, +)
            Text("\((totalMinutes * 60).formattedDuration()) productive")
                .font(.subheadline)
                .foregroundStyle(theme.secondaryTextColor)
        }
    }

    // MARK: - Weekly Heatmap (rows = days, columns = hours)
    private var weeklyHeatmap: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Grid: rows = days (Mon-Sun), columns = hours (0-23)
            ScrollView(.horizontal, showsIndicators: false) {
                VStack(spacing: 1) {
                    // Hour headers
                    HStack(spacing: 1) {
                        Text("")
                            .frame(width: 36)
                        ForEach(0..<24, id: \.self) { hour in
                            Text(hour % 3 == 0 ? hourLabel24(hour) : "")
                                .font(.system(size: 8))
                                .foregroundStyle(theme.hourLabelColor)
                                .frame(width: cellSize, alignment: .leading)
                        }
                    }
                    .padding(.bottom, 2)

                    ForEach(0..<7, id: \.self) { dayIndex in
                        HStack(spacing: 1) {
                            Text(shortDayLabel(weekDays[dayIndex]))
                                .font(.system(size: 9).bold())
                                .foregroundStyle(theme.secondaryTextColor)
                                .frame(width: 36, alignment: .trailing)

                            ForEach(0..<24, id: \.self) { hour in
                                let focusVal = weeklyData.isEmpty ? 0 : weeklyData[dayIndex][hour]
                                let intensity = min(focusVal / 60.0, 1.0)

                                RoundedRectangle(cornerRadius: 2)
                                    .fill(cellColor(intensity: intensity, value: focusVal))
                                    .frame(width: cellSize, height: cellSize)
                                    .overlay {
                                        if hoveredCell?.day == dayIndex && hoveredCell?.hour == hour {
                                            RoundedRectangle(cornerRadius: 2)
                                                .stroke(theme.dividerColor, lineWidth: 1)
                                        }
                                    }
                                    .onHover { isHovering in
                                        hoveredCell = isHovering ? (day: dayIndex, hour: hour) : nil
                                    }
                            }
                        }
                    }
                }
                .padding()
            }
            .background(theme.cardBackgroundColor)
            .cornerRadius(12)

            // Tooltip — always reserve the row height to prevent layout shift
            HStack(spacing: 6) {
                if let hovered = hoveredCell {
                    let focusVal = weeklyData.isEmpty ? 0 : weeklyData[hovered.day][hovered.hour]
                    Text("\(shortDayLabel(weekDays[hovered.day])) \(hourLabel24(hovered.hour))")
                        .font(.caption.bold())
                    Text("—")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Text(focusVal > 0 ? "\(Int(focusVal))m productive" : "No activity")
                        .font(.caption)
                        .foregroundStyle(theme.secondaryTextColor)
                } else {
                    Text(" ").font(.caption) // invisible placeholder
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .background(hoveredCell != nil ? theme.cardBackgroundColor : Color.clear)
            .cornerRadius(6)

            // Legend
            HStack(spacing: 8) {
                Text("Less")
                    .font(.caption2)
                    .foregroundStyle(theme.secondaryTextColor)
                ForEach([0.0, 0.25, 0.5, 0.75, 1.0], id: \.self) { level in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(cellColor(intensity: level, value: level * 60))
                        .frame(width: 12, height: 12)
                }
                Text("More")
                    .font(.caption2)
                    .foregroundStyle(theme.secondaryTextColor)
            }
        }
    }

    // MARK: - Yearly GitHub-style Heatmap
    private var yearlyHeatmap: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Yearly Focus")
                    .font(.title2.bold())
                Spacer()

                HStack(spacing: 4) {
                    if yearOffset != 0 {
                        Button("This Year") { yearOffset = 0; loadYearlyData() }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }

                    Button(action: { yearOffset -= 1; loadYearlyData() }) {
                        Image(systemName: "chevron.left")
                            .font(.caption.bold())
                            .foregroundStyle(theme.secondaryTextColor)
                            .frame(width: 24, height: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    Text(String(displayYear))
                        .font(.subheadline.bold())

                    Button(action: { yearOffset += 1; loadYearlyData() }) {
                        Image(systemName: "chevron.right")
                            .font(.caption.bold())
                            .foregroundStyle(theme.secondaryTextColor)
                            .frame(width: 24, height: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }

            // Stats row
            let yearStats = computeYearStats()
            HStack(spacing: 20) {
                VStack(spacing: 2) {
                    Text("\(Int(yearStats.totalHours))h")
                        .font(.headline.bold())
                    Text("Total")
                        .font(.caption2)
                        .foregroundStyle(theme.secondaryTextColor)
                }
                VStack(spacing: 2) {
                    Text(String(format: "%.1fh", yearStats.avgPerDay))
                        .font(.headline.bold())
                    Text("Avg/Day")
                        .font(.caption2)
                        .foregroundStyle(theme.secondaryTextColor)
                }
                VStack(spacing: 2) {
                    Text("\(yearStats.streak)d")
                        .font(.headline.bold())
                    Text("Streak")
                        .font(.caption2)
                        .foregroundStyle(theme.secondaryTextColor)
                }
                VStack(spacing: 2) {
                    Text(yearStats.bestDay)
                        .font(.headline.bold())
                    Text("Best Day")
                        .font(.caption2)
                        .foregroundStyle(theme.secondaryTextColor)
                }
                VStack(spacing: 2) {
                    Text("\(yearStats.activeDays)")
                        .font(.headline.bold())
                    Text("Active Days")
                        .font(.caption2)
                        .foregroundStyle(theme.secondaryTextColor)
                }
            }
            .padding(.vertical, 4)

            ScrollView(.horizontal, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 2) {
                    // Month labels
                    HStack(spacing: 2) {
                        Text("").frame(width: 28)
                        ForEach(monthLabels, id: \.offset) { m in
                            Text(m.label)
                                .font(.system(size: 9))
                                .foregroundStyle(theme.secondaryTextColor)
                                .frame(width: CGFloat(m.weeks) * 15, alignment: .leading)
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
                                    .foregroundStyle(theme.secondaryTextColor)
                                    .frame(width: 28, height: 13, alignment: .trailing)
                            }
                        }

                        // The grid
                        HStack(spacing: 2) {
                            ForEach(0..<weeks.count, id: \.self) { weekIdx in
                                VStack(spacing: 2) {
                                    // Pad short weeks at TOP (like GitHub)
                                    if weeks[weekIdx].count < 7 {
                                        ForEach(0..<(7 - weeks[weekIdx].count), id: \.self) { _ in
                                            Color.clear.frame(width: 13, height: 13)
                                        }
                                    }

                                    ForEach(0..<weeks[weekIdx].count, id: \.self) { dayIdx in
                                        let day = weeks[weekIdx][dayIdx]
                                        let dayStart = Calendar.current.startOfDay(for: day)
                                        let isFuture = dayStart > Calendar.current.startOfDay(for: Date())
                                        let hours = yearlyData[dayStart] ?? 0
                                        let intensity = isFuture ? -1 : min(hours / 28800, 1.0)

                                        RoundedRectangle(cornerRadius: 2)
                                            .fill(intensity < 0 ? theme.gridLineColor.opacity(0.15) : yearCellColor(intensity: intensity, date: day))
                                            .frame(width: 13, height: 13)
                                            .onHover { isHovering in
                                                if !isFuture {
                                                    hoveredYearDay = isHovering ? day : nil
                                                }
                                            }
                                    }
                                }
                            }
                        }
                    }
                }
                .padding()
            }
            .background(theme.cardBackgroundColor)
            .cornerRadius(12)

            // Tooltip for hovered yearly cell
            if let day = hoveredYearDay {
                let hours = yearlyData[Calendar.current.startOfDay(for: day)] ?? 0
                HStack(spacing: 6) {
                    Text(fullDateLabel(day))
                        .font(.caption.bold())
                    Text("—")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Text(hours > 0 ? hours.formattedDuration() + " productive" : "No activity")
                        .font(.caption)
                        .foregroundStyle(theme.secondaryTextColor)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .background(theme.cardBackgroundColor)
                .cornerRadius(6)
            }

            // Legend + total
            HStack(spacing: 8) {
                Text("Less")
                    .font(.caption2)
                    .foregroundStyle(theme.secondaryTextColor)
                ForEach([0.0, 0.25, 0.5, 0.75, 1.0], id: \.self) { level in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(yearCellColor(intensity: level, date: Date()))
                        .frame(width: 12, height: 12)
                }
                Text("More")
                    .font(.caption2)
                    .foregroundStyle(theme.secondaryTextColor)
                Spacer()
                Text("\(Int(yearlyData.values.reduce(0, +) / 3600))h of productive work in \(displayYear)")
                    .font(.caption)
                    .foregroundStyle(theme.secondaryTextColor)
            }
        }
    }

    // MARK: - Year Stats
    private struct YearStats {
        let totalHours: Double
        let avgPerDay: Double
        let streak: Int
        let bestDay: String
        let activeDays: Int
    }

    private func computeYearStats() -> YearStats {
        let totalSeconds = yearlyData.values.reduce(0, +)
        let totalHours = totalSeconds / 3600
        let activeDays = yearlyData.filter { $0.value > 0 }.count
        let dayCount = max(activeDays, 1)
        let avgPerDay = totalHours / Double(dayCount)

        let best = yearlyData.max(by: { $0.value < $1.value })
        let f = DateFormatter()
        f.dateFormat = "EEE"
        let bestDay = best.map { f.string(from: $0.key) } ?? "—"

        let sortedDays = yearlyData.filter { $0.value > 0 }.keys.sorted()
        var maxStreak = 0
        var currentStreak = 0
        var lastDay: Date?
        for day in sortedDays {
            if let last = lastDay, Calendar.current.dateComponents([.day], from: last, to: day).day == 1 {
                currentStreak += 1
            } else {
                currentStreak = 1
            }
            maxStreak = max(maxStreak, currentStreak)
            lastDay = day
        }

        return YearStats(totalHours: totalHours, avgPerDay: avgPerDay, streak: maxStreak, bestDay: bestDay, activeDays: activeDays)
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
        let mondayOffset = (weekday == 1) ? -6 : (2 - weekday)
        let startOfWeek = cal.date(byAdding: .day, value: mondayOffset, to: baseDate)!
        let endOfWeek = cal.date(byAdding: .day, value: 7, to: startOfWeek)!

        var result: [[Double]] = Array(repeating: Array(repeating: 0, count: 24), count: 7)

        // Single range query instead of 7 separate per-day queries
        let allActivities = (try? Database.shared.activitiesForRange(from: startOfWeek, to: endOfWeek)) ?? []
        for a in allActivities where a.category.isProductive {
            let dayIdx = cal.dateComponents([.day], from: cal.startOfDay(for: startOfWeek), to: cal.startOfDay(for: a.timestamp)).day ?? 0
            guard dayIdx >= 0 && dayIdx < 7 else { continue }
            let hour = cal.component(.hour, from: a.timestamp)
            result[dayIdx][hour] += a.duration / 60.0
        }
        weeklyData = result
    }

    private var displayYear: Int {
        Calendar.current.component(.year, from: Date()) + yearOffset
    }

    private func loadYearlyData() {
        let cal = Calendar.current
        let year = displayYear
        let startOfYear = cal.date(from: DateComponents(year: year))!
        let endOfYear = cal.date(from: DateComponents(year: year + 1))!
        let today = cal.startOfDay(for: Date())

        // Only load data up to today (no future data exists)
        let end = min(endOfYear, cal.date(byAdding: .day, value: 1, to: today)!)

        var result: [Date: Double] = [:]

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
        let mondayOffset = (weekday == 1) ? -6 : (2 - weekday)
        let start = cal.date(byAdding: .day, value: mondayOffset, to: baseDate)!
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
        String(format: "%02d", hour)
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
        if intensity <= 0 { return theme.accentColor.opacity(0.06) }
        return theme.accentColor.opacity(max(0.15, intensity * 0.85))
    }

    // MARK: - Yearly Grid Computation (full year Jan 1 - Dec 31)
    private var yearWeeks: [[Date]] {
        let cal = Calendar.current
        let year = displayYear
        let startOfYear = cal.date(from: DateComponents(year: year))!
        let endOfYear = cal.date(from: DateComponents(year: year + 1))!
        let lastDay = cal.date(byAdding: .day, value: -1, to: endOfYear)!

        var weeks: [[Date]] = []
        var currentWeek: [Date] = []
        var day = startOfYear

        while day <= lastDay {
            let weekday = cal.component(.weekday, from: day) // 1=Sun
            // Start new week on Monday (weekday == 2)
            if weekday == 2 && !currentWeek.isEmpty {
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
        let year = displayYear

        var labels: [MonthLabel] = []
        var currentMonth = cal.component(.month, from: yearWeeks.first?.first ?? Date())
        var weeksInMonth = 0
        var weekIdx = 0

        for week in yearWeeks {
            guard let firstDay = week.first else { continue }
            let month = cal.component(.month, from: firstDay)
            if month != currentMonth {
                let f = DateFormatter()
                f.dateFormat = "MMM"
                let d = cal.date(from: DateComponents(year: year, month: currentMonth))!
                labels.append(MonthLabel(offset: weekIdx - weeksInMonth, label: f.string(from: d), weeks: weeksInMonth))
                currentMonth = month
                weeksInMonth = 0
            }
            weeksInMonth += 1
            weekIdx += 1
        }
        if weeksInMonth > 0 {
            let f = DateFormatter()
            f.dateFormat = "MMM"
            let d = cal.date(from: DateComponents(year: year, month: currentMonth))!
            labels.append(MonthLabel(offset: weekIdx - weeksInMonth, label: f.string(from: d), weeks: weeksInMonth))
        }
        return labels
    }
}
