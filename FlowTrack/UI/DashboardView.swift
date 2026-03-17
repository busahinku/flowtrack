import SwiftUI

enum DashboardTab: String, CaseIterable, Hashable {
    case timeline = "Timeline"
    case stats = "Statistics"
    case heatmap = "Heatmap"
    case chat = "AI Chat"
    case todos = "Tasks"
    case timer = "Timer"
    case journal = "Journal"
    case blocker = "Blocker"

    var icon: String {
        switch self {
        case .timeline: return "calendar.day.timeline.leading"
        case .stats:    return "chart.bar.fill"
        case .heatmap:  return "square.grid.3x3.fill"
        case .chat:     return "sparkles"
        case .todos:    return "checklist"
        case .timer:    return "timer"
        case .journal:  return "book.closed.fill"
        case .blocker:  return "shield.fill"
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// DashboardView owns only navigation state — it never re-renders due to
// AppState / ActivityTracker changes.
// ─────────────────────────────────────────────────────────────────────────────
struct DashboardView: View {
    @State private var selectedTab: DashboardTab? = .timeline
    @Bindable private var appState = AppState.shared

    @Environment(Theme.self) private var theme

    var body: some View {
        NavigationSplitView {
            SidebarView(selectedTab: $selectedTab)
                .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 280)
        } detail: {
            detailContent
        }
        .preferredColorScheme(theme.colorScheme)
        .onChange(of: appState.requestedTab) { _, tab in
            if let tab { selectedTab = tab; appState.requestedTab = nil }
        }
    }

    @ViewBuilder
    private var detailContent: some View {
        switch selectedTab {
        case .timeline: TimelineView()
        case .stats:    StatsView()
        case .heatmap:  HeatmapView()
        case .chat:     ChatView()
        case .todos:    TodoView()
        case .timer:    TimerView()
        case .journal:  JournalView()
        case .blocker:  AppBlockerView()
        case nil:       TimelineView()
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// SidebarView re-renders only when AppState / ActivityTracker change.
// Isolated from DashboardView so the detail pane is unaffected by updates.
// ─────────────────────────────────────────────────────────────────────────────
private struct SidebarView: View {
    @Binding var selectedTab: DashboardTab?
    @Bindable private var appState  = AppState.shared
    @Bindable private var todoStore = TodoStore.shared
    @ObservedObject private var tracker = ActivityTracker.shared

    @Environment(Theme.self) private var theme

    var body: some View {
        List(selection: $selectedTab) {
            statusSection
            todaySection
            focusModeSection
            viewsSection
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) { bottomBar }
    }

    // MARK: Sections

    private var statusSection: some View {
        Section("Status") {
            Label {
                HStack {
                    Text(tracker.isTracking ? "Tracking" : "Paused")
                    Spacer()
                    if !tracker.currentApp.isEmpty {
                        Text(tracker.currentApp)
                            .font(.caption2)
                            .foregroundStyle(theme.secondaryTextColor)
                            .lineLimit(1)
                    }
                }
            } icon: {
                Circle()
                    .fill(tracker.isTracking ? theme.successColor : theme.errorColor)
                    .frame(width: 8, height: 8)
            }
            .font(.subheadline)
            .foregroundStyle(theme.secondaryTextColor)
            .listRowSeparator(.hidden)
            .selectionDisabled()
        }
    }

    private var todaySection: some View {
        Section("Today") {
            HStack(spacing: 14) {
                focusRing
                VStack(alignment: .leading, spacing: 4) {
                    statRow("Distraction", distractionTime)
                    statRow("Active",      totalActiveTime)
                    statRow("Timer",       todayTrackedTime)
                }
                Spacer()
            }
            .padding(.vertical, 2)
            .listRowSeparator(.hidden)
            .selectionDisabled()
        }
    }

    private var focusModeSection: some View {
        let engine = FocusModeEngine.shared
        return Section {
            Button(action: { engine.toggle() }) {
                Label {
                    HStack {
                        Text("Focus Mode")
                        Spacer()
                        if engine.isActive {
                            Text("ON")
                                .font(.caption2.weight(.heavy))
                                .foregroundStyle(theme.successColor)
                        }
                    }
                } icon: {
                    Image(systemName: engine.isActive ? "shield.fill" : "shield")
                        .foregroundStyle(engine.isActive ? theme.successColor : .secondary)
                }
            }
            .buttonStyle(.plain)
            .listRowSeparator(.hidden)
            .selectionDisabled()
        }
    }

    private var viewsSection: some View {
        Section("Views") {
            ForEach(DashboardTab.allCases, id: \.self) { tab in
                Label(tab.rawValue, systemImage: tab.icon)
                    .tag(tab as DashboardTab?)
            }
        }
    }

    // MARK: Focus ring

    private var focusRing: some View {
        ZStack {
            Circle()
                .stroke(theme.secondaryTextColor.opacity(0.15), lineWidth: 5)
            Circle()
                .trim(from: 0, to: focusScorePercent)
                .stroke(theme.accentColor, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut(duration: 0.6), value: focusScorePercent)
            VStack(spacing: 0) {
                Text("\(Int(focusScorePercent * 100))%")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                Text("Focus")
                    .font(.system(size: 8))
                    .foregroundStyle(theme.secondaryTextColor)
            }
        }
        .frame(width: 46, height: 46)
    }

    // MARK: Bottom bar (AI status + Settings)

    private var bottomBar: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 6) {
                Image(systemName: appState.isRunningAI ? "sparkles" : "sparkle")
                    .font(.system(size: 11))
                    .foregroundStyle(appState.isRunningAI ? theme.warningColor : .secondary)
                Text(appState.isRunningAI ? "AI Processing…" : "AI Idle")
                    .font(.caption)
                    .foregroundStyle(theme.secondaryTextColor)
                Spacer()
                if let nextRun = appState.aiNextRunTime {
                    let rem = max(0, nextRun.timeIntervalSince(Date()))
                    Text("\(Int(rem / 60))m")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)

            SettingsLink {
                Label("Settings", systemImage: "gear")
                    .font(.subheadline)
                    .foregroundStyle(theme.secondaryTextColor)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .background(.regularMaterial)
    }

    // MARK: Helpers

    private func statRow(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
            Text(label)
                .font(.caption2)
                .foregroundStyle(theme.secondaryTextColor)
        }
    }

    private var focusScorePercent: Double {
        let productive = appState.categoryStats
            .filter { $0.category.isProductive }
            .reduce(0) { $0 + $1.totalSeconds }
        let total = appState.categoryStats.reduce(0) { $0 + $1.totalSeconds }
        guard total > 0 else { return 0 }
        return productive / total
    }

    private var totalActiveTime: String {
        let secs = appState.timeSlots.filter { !$0.isIdle }.reduce(0.0) { $0 + $1.activeDuration }
        return secs.formattedDuration()
    }

    private var distractionTime: String {
        let secs = appState.timeSlots
            .filter { $0.category.rawValue == "Distraction" }
            .reduce(0.0) { $0 + $1.activeDuration }
        guard secs > 0 else { return "—" }
        return secs.formattedDuration()
    }

    private var todayTrackedTime: String {
        let sessions = todoStore.timerSessions.filter {
            Calendar.current.isDateInToday($0.startedAt)
        }
        let total = sessions.reduce(0.0) { $0 + $1.duration }
        guard total >= 60 else { return "—" }
        return total.formattedDuration()
    }
}

