import SwiftUI

enum DashboardTab: String, CaseIterable {
    case timeline = "Timeline"
    case stats = "Statistics"
    case heatmap = "Heatmap"

    var icon: String {
        switch self {
        case .timeline: return "calendar.day.timeline.leading"
        case .stats: return "chart.bar.fill"
        case .heatmap: return "square.grid.3x3.fill"
        }
    }
}

struct DashboardView: View {
    @Bindable var appState = AppState.shared
    @State private var selectedTab: DashboardTab = .timeline

    private var theme: AppTheme { AppSettings.shared.appTheme }

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detailView
        }
        .preferredColorScheme(theme.colorScheme)
    }

    // MARK: - Sidebar
    private var sidebar: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                ZStack {
                    Circle()
                        .stroke(Color.gray.opacity(0.15), lineWidth: 8)
                    Circle()
                        .trim(from: 0, to: focusScorePercent)
                        .stroke(theme.accentColor, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    VStack(spacing: 2) {
                        Text("\(Int(focusScorePercent * 100))%")
                            .font(.title2.bold())
                        Text("Focus")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 100, height: 100)

                HStack(spacing: 16) {
                    VStack {
                        Text("\(appState.timeSlots.filter { !$0.isIdle }.count)")
                            .font(.headline)
                        Text("Sessions")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    VStack {
                        Text(totalActiveTime)
                            .font(.headline)
                        Text("Active")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding()

            Divider()

            HStack(spacing: 6) {
                Circle()
                    .fill(ActivityTracker.shared.isTracking ? .green : .red)
                    .frame(width: 8, height: 8)
                Text(ActivityTracker.shared.isTracking ? "Tracking" : "Paused")
                    .font(.caption)
                Spacer()
                if !ActivityTracker.shared.currentApp.isEmpty {
                    Text(ActivityTracker.shared.currentApp)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)

            Divider()

            // Tab buttons — entire row clickable
            VStack(spacing: 2) {
                ForEach(DashboardTab.allCases, id: \.self) { tab in
                    Button(action: { selectedTab = tab }) {
                        HStack(spacing: 10) {
                            Image(systemName: tab.icon)
                                .font(.body)
                                .frame(width: 22)
                            Text(tab.rawValue)
                                .font(.subheadline)
                            Spacer()
                            if selectedTab == tab {
                                Circle()
                                    .fill(theme.accentColor)
                                    .frame(width: 6, height: 6)
                            }
                        }
                        .contentShape(Rectangle())
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(selectedTab == tab ? theme.accentColor.opacity(0.15) : Color.clear)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 8)

            Spacer()

            // Settings button
            VStack(spacing: 4) {
                Divider()
                SettingsLink {
                    HStack(spacing: 8) {
                        Image(systemName: "gear")
                            .foregroundStyle(.secondary)
                        Text("Settings")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .contentShape(Rectangle())
                    .padding(.horizontal)
                    .padding(.vertical, 6)
                }
                .buttonStyle(.plain)
            }

            // AI Status
            VStack(spacing: 4) {
                Divider()
                HStack(spacing: 6) {
                    Image(systemName: appState.isRunningAI ? "sparkles" : "sparkle")
                        .foregroundStyle(appState.isRunningAI ? .yellow : .secondary)
                    Text(appState.isRunningAI ? "AI Processing..." : "AI Idle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if let nextRun = appState.aiNextRunTime {
                        let remaining = max(0, nextRun.timeIntervalSince(Date()))
                        Text("\(Int(remaining / 60))m")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
            }
        }
        .background(theme.sidebarBg)
        .frame(minWidth: 210)
    }

    @ViewBuilder
    private var detailView: some View {
        switch selectedTab {
        case .timeline:
            TimelineView()
                .navigationTitle("")
                .toolbar(.hidden, for: .automatic)
        case .stats:
            StatsView()
                .navigationTitle("")
                .toolbar(.hidden, for: .automatic)
        case .heatmap:
            HeatmapView()
                .navigationTitle("")
                .toolbar(.hidden, for: .automatic)
        }
    }

    private var focusScorePercent: Double {
        let productive = appState.categoryStats.filter { $0.category.isProductive }.reduce(0) { $0 + $1.totalSeconds }
        let total = appState.categoryStats.reduce(0) { $0 + $1.totalSeconds }
        guard total > 0 else { return 0 }
        return productive / total
    }

    private var totalActiveTime: String {
        let total = appState.timeSlots.filter { !$0.isIdle }.reduce(0.0) { $0 + $1.duration }
        return Theme.formatDuration(total)
    }
}
