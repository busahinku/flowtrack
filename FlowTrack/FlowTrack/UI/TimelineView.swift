import SwiftUI

struct TimelineView: View {
    @Bindable var appState = AppState.shared

    private var theme: AppTheme { AppSettings.shared.appTheme }
    private let hourHeight: CGFloat = 160

    var body: some View {
        VStack(spacing: 0) {
            headerView
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    ZStack(alignment: .topLeading) {
                        hourGrid
                        sessionOverlay
                        nowIndicator
                        Color.clear.frame(height: 1)
                            .id("now-anchor")
                            .padding(.top, currentTimeY)
                    }
                    .frame(width: nil, height: 24 * hourHeight)
                }
                .onAppear {
                    Task { await appState.refreshData() }
                    // Scroll instantly — no animation from top
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        proxy.scrollTo("now-anchor", anchor: .center)
                    }
                }
                .onChange(of: appState.selectedDate) {
                    Task { await appState.refreshData() }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        proxy.scrollTo("now-anchor", anchor: .center)
                    }
                }
                .onChange(of: appState.timeSlots.count) {
                    proxy.scrollTo("now-anchor", anchor: .center)
                }
            }
        }
        .background(theme.timelineBg)
    }

    // MARK: - Header
    private var headerView: some View {
        HStack {
            Button(action: {
                Task { await appState.runAINow() }
            }) {
                HStack(spacing: 4) {
                    if appState.isRunningAI {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "sparkles")
                    }
                    Text("Run AI")
                }
                .font(.caption)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(theme.accentColor.opacity(0.15))
                .cornerRadius(6)
            }
            .buttonStyle(.plain)
            .disabled(appState.isRunningAI)

            VStack(alignment: .leading, spacing: 2) {
                Text("Timeline")
                    .font(.title2.bold())
                if let nextRun = appState.aiNextRunTime {
                    let remaining = max(0, nextRun.timeIntervalSince(Date()))
                    Text("AI in \(Int(remaining / 60))m \(Int(remaining) % 60)s")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            HStack(spacing: 8) {
                Button(action: {
                    appState.selectedDate = Calendar.current.date(byAdding: .day, value: -1, to: appState.selectedDate)!
                }) {
                    Image(systemName: "chevron.left")
                        .font(.body.bold())
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.bordered)

                Text(dateLabel)
                    .font(.headline)
                    .frame(minWidth: 100)

                Button(action: {
                    appState.selectedDate = Calendar.current.date(byAdding: .day, value: 1, to: appState.selectedDate)!
                }) {
                    Image(systemName: "chevron.right")
                        .font(.body.bold())
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.bordered)

                if !Calendar.current.isDateInToday(appState.selectedDate) {
                    Button("Today") {
                        appState.selectedDate = Date()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
        .padding()
    }

    private var dateLabel: String {
        if Calendar.current.isDateInToday(appState.selectedDate) {
            return "Today"
        }
        let f = DateFormatter()
        f.dateFormat = "MMM d, yyyy"
        return f.string(from: appState.selectedDate)
    }

    // MARK: - Hour Grid
    private var hourGrid: some View {
        ZStack(alignment: .topLeading) {
            ForEach(0..<24, id: \.self) { hour in
                let y = CGFloat(hour) * hourHeight
                HStack(spacing: 8) {
                    Text(hourLabel(hour))
                        .font(.caption2)
                        .foregroundStyle(theme.hourLabelColor)
                        .frame(width: 50, alignment: .trailing)
                    Rectangle()
                        .fill(theme.gridLineColor)
                        .frame(height: 0.5)
                }
                .offset(y: y)
            }
        }
    }

    private func hourLabel(_ hour: Int) -> String {
        let h = hour % 12 == 0 ? 12 : hour % 12
        let ampm = hour < 12 ? "AM" : "PM"
        return "\(h) \(ampm)"
    }

    // MARK: - Session Overlay
    private var sessionOverlay: some View {
        let sortedSlots = appState.timeSlots.sorted { $0.startTime < $1.startTime }
        return ZStack(alignment: .topLeading) {
            ForEach(Array(sortedSlots.enumerated()), id: \.element.id) { index, slot in
                if !slot.isIdle {
                    sessionCard(slot, index: index, allSlots: sortedSlots)
                }
            }
        }
        .padding(.leading, 64)
    }

    @ViewBuilder
    private func sessionCard(_ slot: TimeSlot, index: Int, allSlots: [TimeSlot]) -> some View {
        let y = yPosition(for: slot.startTime)
        let naturalHeight = slotHeight(for: slot)
        let nextY: CGFloat = {
            if index + 1 < allSlots.count {
                return yPosition(for: allSlots[index + 1].startTime)
            }
            return y + naturalHeight
        }()
        let availableSpace = nextY - y - 2
        let height = max(min(max(naturalHeight, 50), availableSpace), 20)

        SessionCardView(slot: slot, title: appState.sessionTitle(for: slot))
            .frame(minHeight: height)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.trailing, 16)
            .offset(y: y)
    }

    // MARK: - Now Indicator
    @ViewBuilder
    private var nowIndicator: some View {
        if Calendar.current.isDateInToday(appState.selectedDate) {
            let y = currentTimeY
            HStack(spacing: 0) {
                Circle()
                    .fill(.red)
                    .frame(width: 8, height: 8)
                Rectangle()
                    .fill(.red)
                    .frame(height: 1.5)
            }
            .padding(.leading, 56)
            .offset(y: y)
        }
    }

    private var currentTimeY: CGFloat {
        yPosition(for: Date())
    }

    // MARK: - Geometry Helpers
    private func yPosition(for date: Date) -> CGFloat {
        let cal = Calendar.current
        let hour = CGFloat(cal.component(.hour, from: date))
        let minute = CGFloat(cal.component(.minute, from: date))
        return (hour + minute / 60.0) * hourHeight
    }

    private func slotHeight(for slot: TimeSlot) -> CGFloat {
        let duration = slot.endTime.timeIntervalSince(slot.startTime)
        return CGFloat(duration / 3600.0) * hourHeight
    }
}

// MARK: - Session Card View
struct SessionCardView: View {
    let slot: TimeSlot
    let title: String
    @State private var isExpanded = false
    @Bindable var appState = AppState.shared

    private var theme: AppTheme { AppSettings.shared.appTheme }
    private var categoryColor: Color { Theme.color(for: slot.category) }

    var body: some View {
        Button(action: { withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() } }) {
            HStack(spacing: 0) {
                // Category color bar
                RoundedRectangle(cornerRadius: 2)
                    .fill(categoryColor)
                    .frame(width: 4)

                VStack(alignment: .leading, spacing: 0) {
                    compactContent
                    if isExpanded {
                        expandedContent
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
            .background(categoryColor.opacity(0.04))
            .background(theme.cardBg)
            .cornerRadius(8)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.06), radius: 3, y: 1)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Compact Content (always visible)
    private var compactContent: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: slot.category.icon)
                    .font(.caption)
                    .foregroundStyle(categoryColor)

                Text(title)
                    .font(.caption.bold())
                    .lineLimit(1)

                Spacer()

                Text(Theme.formatTimeRange(slot.startTime, slot.endTime))
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Text(Theme.formatDuration(slot.duration))
                    .font(.caption2.bold())
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 6) {
                // App icons row
                HStack(spacing: 3) {
                    ForEach(slot.activities.prefix(3)) { app in
                        HStack(spacing: 3) {
                            AppIconImage(bundleID: app.bundleID, size: 12)
                            Text(app.appName)
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    if slot.activities.count > 3 {
                        Text("+\(slot.activities.count - 3)")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                }

                Spacer()

                // AI summary preview or uncategorized badge
                if let summary = appState.sessionSummaries[slot.id] {
                    Text(summary)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .frame(maxWidth: 200, alignment: .trailing)
                } else if slot.category == .uncategorized {
                    Text("Uncategorized")
                        .font(.system(size: 9).bold())
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.orange.opacity(0.1))
                        .cornerRadius(3)
                }
            }
        }
    }

    // MARK: - Expanded Content (shown on click)
    private var expandedContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()
                .padding(.vertical, 4)

            // AI Summary
            if let summary = appState.sessionSummaries[slot.id] {
                VStack(alignment: .leading, spacing: 4) {
                    Label("AI Summary", systemImage: "sparkles")
                        .font(.caption.bold())
                        .foregroundStyle(categoryColor)
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            // All apps with durations
            VStack(alignment: .leading, spacing: 4) {
                Text("Apps Used")
                    .font(.caption.bold())

                ForEach(slot.activities) { activity in
                    HStack(spacing: 6) {
                        AppIconImage(bundleID: activity.bundleID, size: 16)
                        Text(activity.appName)
                            .font(.caption)
                        Spacer()
                        Text(activity.title)
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .frame(maxWidth: 200, alignment: .trailing)
                        Text(Theme.formatDuration(activity.duration))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 1)
                }
            }
        }
    }
}
