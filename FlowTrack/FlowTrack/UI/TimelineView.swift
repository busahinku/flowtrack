import SwiftUI

struct TimelineView: View {
    @Bindable var appState = AppState.shared
    let theme = AppSettings.shared.appTheme

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
                        // Invisible anchor for scrolling to current time
                        Color.clear.frame(height: 1)
                            .id("now-anchor")
                            .padding(.top, currentTimeY)
                    }
                    .frame(width: nil, height: 24 * hourHeight)
                }
                .onAppear {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        withAnimation { proxy.scrollTo("now-anchor", anchor: .center) }
                    }
                }
                .onChange(of: appState.timeSlots.count) {
                    withAnimation { proxy.scrollTo("now-anchor", anchor: .center) }
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
                    Task { await appState.refreshData() }
                }) {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.plain)

                Text(dateLabel)
                    .font(.headline)

                Button(action: {
                    appState.selectedDate = Calendar.current.date(byAdding: .day, value: 1, to: appState.selectedDate)!
                    Task { await appState.refreshData() }
                }) {
                    Image(systemName: "chevron.right")
                }
                .buttonStyle(.plain)

                if !Calendar.current.isDateInToday(appState.selectedDate) {
                    Button("Today") {
                        appState.selectedDate = Date()
                        Task { await appState.refreshData() }
                    }
                    .font(.caption)
                    .buttonStyle(.bordered)
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
        let height = max(min(max(naturalHeight, 40), availableSpace), 16)

        SessionCardView(slot: slot, title: appState.sessionTitle(for: slot))
            .frame(height: height)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.trailing, 16)
            .offset(y: y)
            .clipped()
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
    @State private var showDetail = false

    private var theme: AppTheme { AppSettings.shared.appTheme }

    var body: some View {
        Button(action: { showDetail = true }) {
            HStack(spacing: 0) {
                // Color bar
                RoundedRectangle(cornerRadius: 2)
                    .fill(Theme.color(for: slot.category))
                    .frame(width: 4)

                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        if let first = slot.activities.first {
                            AppIconImage(bundleID: first.bundleID, size: 16)
                        }
                        Text(title)
                            .font(.caption.bold())
                            .lineLimit(1)
                        Spacer()
                        Text(Theme.formatTimeRange(slot.startTime, slot.endTime))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    if slot.activities.count > 1 {
                        HStack(spacing: 4) {
                            ForEach(slot.activities.prefix(4)) { app in
                                AppIconImage(bundleID: app.bundleID, size: 12)
                            }
                            if slot.activities.count > 4 {
                                Text("+\(slot.activities.count - 4)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }
            .background(theme.cardBg)
            .cornerRadius(8)
            .shadow(color: .black.opacity(0.08), radius: 3, y: 1)
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showDetail) {
            SessionDetailView(slot: slot)
        }
    }
}
