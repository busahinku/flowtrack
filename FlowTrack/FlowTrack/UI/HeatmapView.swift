import SwiftUI

struct HeatmapView: View {
    @Bindable var appState = AppState.shared
    @State private var heatmapData: [Date: Double] = [:]

    private var theme: AppTheme { AppSettings.shared.appTheme }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Weekly Productivity Heatmap")
                .font(.title2.bold())
                .padding(.horizontal)

            HStack(spacing: 8) {
                ForEach(weekDays, id: \.self) { day in
                    VStack(spacing: 8) {
                        Text(dayLabel(day))
                            .font(.caption2.bold())
                            .foregroundStyle(.secondary)

                        let hours = heatmapData[Calendar.current.startOfDay(for: day)] ?? 0
                        let intensity = min(hours / 28800, 1.0) // 8 hours max

                        RoundedRectangle(cornerRadius: 8)
                            .fill(theme.accentColor.opacity(max(0.05, intensity)))
                            .frame(height: 80)
                            .overlay {
                                VStack(spacing: 4) {
                                    Text(Theme.formatDuration(hours))
                                        .font(.caption.bold())
                                    Text("productive")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal)

            // Legend
            HStack(spacing: 16) {
                ForEach(CategoryManager.shared.selectableCategories, id: \.name) { cat in
                    HStack(spacing: 4) {
                        Circle()
                            .fill(cat.color)
                            .frame(width: 8, height: 8)
                        Text(cat.name)
                            .font(.caption2)
                    }
                }
            }
            .padding(.horizontal)

            Spacer()
        }
        .padding(.top)
        .background(theme.timelineBg)
        .onAppear { loadHeatmap() }
    }

    private func loadHeatmap() {
        heatmapData = (try? Database.shared.heatmapForWeek(containing: appState.selectedDate)) ?? [:]
    }

    private var weekDays: [Date] {
        let cal = Calendar.current
        let weekday = cal.component(.weekday, from: appState.selectedDate)
        let start = cal.date(byAdding: .day, value: -(weekday - 1), to: cal.startOfDay(for: appState.selectedDate))!
        return (0..<7).map { cal.date(byAdding: .day, value: $0, to: start)! }
    }

    private func dayLabel(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "EEE"
        return f.string(from: date)
    }
}
