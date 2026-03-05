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
    @State private var selectedApp: AppUsageInfo?
    @State private var searchText = ""

    private var theme: AppTheme { AppSettings.shared.appTheme }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                dateNavigation
                summaryCards
                categoryDonut
                hourlyChart
                productivityFlow
                topApps
                sessionsSection
            }
            .padding()
        }
        .background(theme.timelineBg)
        .onAppear { loadData() }
        .onChange(of: selectedDate) { Task { loadData() } }
        .onChange(of: period) { Task { loadData() } }
        .sheet(item: $selectedApp) { app in
            AppDetailSheet(app: app)
        }
    }

    // MARK: - Date Navigation
    private var dateNavigation: some View {
        HStack {
            Picker("Period", selection: $period) {
                ForEach(StatsPeriod.allCases, id: \.self) { p in
                    Text(p.rawValue).tag(p)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 200)

            Spacer()

            HStack(spacing: 12) {
                Button(action: navigateBack) {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.plain)

                Text(dateRangeLabel)
                    .font(.headline)

                Button(action: navigateForward) {
                    Image(systemName: "chevron.right")
                }
                .buttonStyle(.plain)

                Button("Today") {
                    selectedDate = Date()
                }
                .font(.caption)
                .buttonStyle(.bordered)
            }
        }
    }

    // MARK: - Summary Cards
    private var summaryCards: some View {
        HStack(spacing: 12) {
            SummaryCard(
                title: "Total Active",
                value: Theme.formatDuration(totalActiveSeconds),
                icon: "clock.fill",
                color: .blue
            )
            SummaryCard(
                title: "Productive",
                value: "\(Int(productivePercent))%",
                icon: "checkmark.circle.fill",
                color: .green
            )
            SummaryCard(
                title: "Distraction",
                value: "\(Int(distractionPercent))%",
                icon: "eye.slash.fill",
                color: .red
            )
            SummaryCard(
                title: "Sessions",
                value: "\(appState.timeSlots.filter { !$0.isIdle }.count)",
                icon: "square.stack.fill",
                color: .purple
            )
            SummaryCard(
                title: "Top App",
                value: topAppName,
                icon: "star.fill",
                color: .orange
            )
        }
    }

    // MARK: - Category Donut
    private var categoryDonut: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Category Breakdown")
                .font(.headline)
            HStack(spacing: 20) {
                Chart(catStats) { stat in
                    SectorMark(
                        angle: .value("Time", stat.totalSeconds),
                        innerRadius: .ratio(0.6),
                        angularInset: 1
                    )
                    .foregroundStyle(Theme.color(for: stat.category))
                }
                .frame(width: 180, height: 180)
                .overlay {
                    VStack(spacing: 2) {
                        if let top = catStats.first {
                            Image(systemName: top.category.icon)
                                .font(.title2)
                                .foregroundStyle(Theme.color(for: top.category))
                            Text(top.category.rawValue)
                                .font(.caption.bold())
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    ForEach(catStats) { stat in
                        HStack(spacing: 8) {
                            Circle()
                                .fill(Theme.color(for: stat.category))
                                .frame(width: 10, height: 10)
                            Image(systemName: stat.category.icon)
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
                    }
                }
            }
        }
        .padding()
        .background(theme.cardBg)
        .cornerRadius(12)
    }

    // MARK: - Hourly Chart
    private var hourlyChart: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Hourly Activity")
                .font(.headline)
            Chart(hourlyStats) { stat in
                BarMark(
                    x: .value("Hour", stat.hour),
                    y: .value("Minutes", stat.minutes)
                )
                .foregroundStyle(Theme.color(for: stat.category))
            }
            .chartXScale(domain: 0...23)
            .chartXAxis {
                AxisMarks(values: [0, 3, 6, 9, 12, 15, 18, 21]) { value in
                    AxisValueLabel {
                        if let h = value.as(Int.self) {
                            Text("\(h == 0 ? 12 : (h > 12 ? h - 12 : h))\(h < 12 ? "a" : "p")")
                                .font(.caption2)
                        }
                    }
                }
            }
            .frame(height: 200)
        }
        .padding()
        .background(theme.cardBg)
        .cornerRadius(12)
    }

    // MARK: - Productivity Flow
    private var productivityFlow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Productivity Flow")
                .font(.headline)
            Chart(productivityByHour) { item in
                AreaMark(
                    x: .value("Hour", item.hour),
                    y: .value("Score", item.score)
                )
                .foregroundStyle(.green.opacity(0.3))
                .interpolationMethod(.catmullRom)
                LineMark(
                    x: .value("Hour", item.hour),
                    y: .value("Score", item.score)
                )
                .foregroundStyle(.green)
                .interpolationMethod(.catmullRom)
            }
            .chartXScale(domain: 0...23)
            .chartYScale(domain: 0...100)
            .frame(height: 150)
        }
        .padding()
        .background(theme.cardBg)
        .cornerRadius(12)
    }

    // MARK: - Top Apps
    private var topApps: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Top Apps")
                .font(.headline)
            ForEach(appUsages.prefix(10)) { app in
                Button(action: { selectedApp = app }) {
                    HStack {
                        AppIconImage(bundleID: app.bundleID, size: 24)
                        VStack(alignment: .leading) {
                            Text(app.appName)
                                .font(.subheadline.bold())
                            Text(app.category.rawValue)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(Theme.formatDuration(app.duration))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        // Usage bar
                        GeometryReader { geo in
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Theme.color(for: app.category))
                                .frame(width: geo.size.width * CGFloat(app.duration / max(totalActiveSeconds, 1)))
                        }
                        .frame(width: 80, height: 6)
                    }
                    .padding(.vertical, 4)
                }
                .buttonStyle(.plain)
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
                Spacer()
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Search", text: $searchText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 200)
                }
            }

            ForEach(filteredSessions) { slot in
                HStack {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Theme.color(for: slot.category))
                        .frame(width: 4, height: 36)
                    VStack(alignment: .leading) {
                        Text(appState.sessionTitle(for: slot))
                            .font(.subheadline)
                            .lineLimit(1)
                        Text(Theme.formatTimeRange(slot.startTime, slot.endTime))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(slot.category.rawValue)
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Theme.color(for: slot.category).opacity(0.15))
                        .cornerRadius(4)
                    Text(Theme.formatDuration(slot.duration))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
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
        return hourCats.flatMap { (hour, cats) in
            cats.map { HourStat(hour: hour, category: Category(rawValue: $0.key), minutes: $0.value) }
        }
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
            return HourScore(hour: hour, score: score)
        }
    }

    private var totalActiveSeconds: Double {
        allActivities.filter { !$0.isIdle }.reduce(0) { $0 + $1.duration }
    }

    private var productivePercent: Double {
        let total = totalActiveSeconds
        guard total > 0 else { return 0 }
        let prod = allActivities.filter { $0.category.isProductive }.reduce(0) { $0 + $1.duration }
        return prod / total * 100
    }

    private var distractionPercent: Double {
        let total = totalActiveSeconds
        guard total > 0 else { return 0 }
        let dist = allActivities.filter { $0.category.rawValue == "Distraction" }.reduce(0) { $0 + $1.duration }
        return dist / total * 100
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
        let slots = appState.timeSlots.filter { !$0.isIdle }
        if searchText.isEmpty { return slots }
        return slots.filter {
            appState.sessionTitle(for: $0).lowercased().contains(searchText.lowercased()) ||
            $0.category.rawValue.lowercased().contains(searchText.lowercased()) ||
            $0.activities.contains { $0.appName.lowercased().contains(searchText.lowercased()) }
        }
    }
}

// MARK: - Supporting Types
struct HourScore: Identifiable {
    let id = UUID()
    let hour: Int
    let score: Double
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
                .minimumScaleFactor(0.7)
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(AppSettings.shared.appTheme.cardBg)
        .cornerRadius(10)
    }
}

// MARK: - App Detail Sheet
struct AppDetailSheet: View {
    let app: AppUsageInfo
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                AppIconImage(bundleID: app.bundleID, size: 32)
                VStack(alignment: .leading) {
                    Text(app.appName)
                        .font(.title2.bold())
                    Text(app.category.rawValue)
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

            HStack(spacing: 20) {
                VStack {
                    Text(Theme.formatDuration(app.duration))
                        .font(.title3.bold())
                    Text("Total Time")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                VStack {
                    Text("\(app.timestamps.count)")
                        .font(.title3.bold())
                    Text("Activities")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // Activity timeline
            if !app.timestamps.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Activity Timeline")
                        .font(.headline)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(app.timestamps, id: \.self) { ts in
                                HStack(spacing: 8) {
                                    Circle()
                                        .fill(.blue)
                                        .frame(width: 6, height: 6)
                                    Text(Theme.formatTime(ts))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .frame(maxHeight: 200)
                }
            }
        }
        .padding()
        .frame(minWidth: 400, minHeight: 300)
    }
}
