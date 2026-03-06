import SwiftUI
import Foundation

// MARK: - Layout constants
private enum TL {
    static let hourHeight: CGFloat = 140
    static let labelWidth: CGFloat = 58
    static let cardLeading: CGFloat = 8   // gap between label column and cards
    static let cardTrailing: CGFloat = 10 // right padding so cards don't touch the edge
    static let colGap: CGFloat = 3        // gap between concurrent columns
    static let minHeight: CGFloat = 22
    static let cornerRadius: CGFloat = 7
    static let totalHours: Int = 24
}

// MARK: - Card layout result
private struct CardLayout: Identifiable {
    let index: Int      // unique index within the layout array
    let slot: TimeSlot
    let col: Int        // 0-based column index within overlap group
    let totalCols: Int  // total columns in this overlap group
    var id: String { "\(slot.id)-\(index)" }
}

// MARK: - Google-Calendar-style layout engine
// Guarantees zero visual overlap: events are grouped by time overlap (connected
// components), columns are assigned greedily within each group, and every event
// in the same group shares the same totalCols so widths tile perfectly.
private enum CalendarLayoutEngine {

    static func compute(_ slots: [TimeSlot]) -> [CardLayout] {
        // Only show non-idle sessions
        let events = slots
            .filter { !$0.isIdle }
            .sorted {
                $0.startTime != $1.startTime
                    ? $0.startTime < $1.startTime
                    : $0.endTime > $1.endTime   // longer event first for better column fill
            }
        guard !events.isEmpty else { return [] }

        // Step 1: Greedy column assignment
        var colEnds: [Date] = []
        var assigned: [(slot: TimeSlot, col: Int)] = []

        for e in events {
            if let idx = colEnds.firstIndex(where: { $0 <= e.startTime }) {
                colEnds[idx] = e.endTime
                assigned.append((e, idx))
            } else {
                assigned.append((e, colEnds.count))
                colEnds.append(e.endTime)
            }
        }

        // Step 2: Connected-component grouping
        // Two events are in the same component when their intervals overlap.
        // All events in a component share the same totalCols value.
        var groupID = Array(repeating: -1, count: assigned.count)
        var nextGroup = 0

        for i in assigned.indices where groupID[i] == -1 {
            groupID[i] = nextGroup
            var stack = [i]
            while let cur = stack.popLast() {
                let a = assigned[cur].slot
                for j in assigned.indices where groupID[j] == -1 {
                    let b = assigned[j].slot
                    if a.startTime < b.endTime && a.endTime > b.startTime {
                        groupID[j] = nextGroup
                        stack.append(j)
                    }
                }
            }
            nextGroup += 1
        }

        // Step 3: Max column index per group -> totalCols for that group
        var groupMaxCol = [Int: Int]()
        for (i, a) in assigned.enumerated() {
            let g = groupID[i]
            groupMaxCol[g] = max(groupMaxCol[g, default: 0], a.col)
        }

        return assigned.enumerated().map { i, a in
            CardLayout(
                index: i,
                slot: a.slot,
                col: a.col,
                totalCols: (groupMaxCol[groupID[i], default: 0]) + 1
            )
        }
    }
}

// MARK: - Timeline View
struct TimelineView: View {
    @Bindable var appState = AppState.shared
    @State private var showDatePicker = false

    private var theme: AppTheme { AppSettings.shared.appTheme }

    var body: some View {
        GeometryReader { geo in
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    timelineBody(width: geo.size.width)
                }
                .onAppear {
                    Task { await appState.refreshData() }
                    scrollToNow(proxy, delay: 0.15)
                }
                .onChange(of: appState.selectedDate) {
                    Task { await appState.refreshData() }
                    scrollToNow(proxy, delay: 0.35)
                }
            }
        }
        .background(theme.timelineBg)
        .toolbarBackground(.hidden, for: .windowToolbar)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await appState.runAINow() }
                } label: {
                    HStack(spacing: 5) {
                        if appState.isRunningAI {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "sparkles")
                        }
                        Text(appState.isRunningAI ? "Processing…" : "Run AI")
                            .fontWeight(.medium)
                    }
                }
                .disabled(appState.isRunningAI)
            }
            ToolbarItemGroup(placement: .principal) {
                dateNavToolbar
            }
        }
    }

    private var dateNavToolbar: some View {
        HStack(spacing: 2) {
            Button {
                appState.selectedDate = Calendar.current.date(byAdding: .day, value: -1, to: appState.selectedDate) ?? appState.selectedDate
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(theme.secondaryText)

            Button { showDatePicker.toggle() } label: {
                Text(dateLabel)
                    .font(.headline)
                    .frame(minWidth: 90)
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showDatePicker) {
                DatePicker("", selection: $appState.selectedDate, displayedComponents: .date)
                    .labelsHidden()
                    .datePickerStyle(.graphical)
                    .padding(8)
                    .frame(width: 300, height: 320)
            }

            Button {
                appState.selectedDate = Calendar.current.date(byAdding: .day, value: 1, to: appState.selectedDate) ?? appState.selectedDate
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(theme.secondaryText)
        }
    }

    // MARK: - Timeline body
    private func timelineBody(width: CGFloat) -> some View {
        let totalH = CGFloat(TL.totalHours) * TL.hourHeight
        let usable = max(1, width - TL.labelWidth - TL.cardLeading - TL.cardTrailing)
        let layouts = CalendarLayoutEngine.compute(appState.timeSlots)

        return ZStack(alignment: .topLeading) {
            hourGrid(width: width, totalH: totalH)

            ForEach(layouts) { item in
                let colW = max(1, (usable - CGFloat(item.totalCols - 1) * TL.colGap) / CGFloat(item.totalCols))
                let xOff = TL.labelWidth + TL.cardLeading + CGFloat(item.col) * (colW + TL.colGap)
                let yOff = timeY(item.slot.startTime)
                let cardH = max(slotH(item.slot), TL.minHeight)

                SessionCardView(
                    slot: item.slot,
                    title: appState.sessionTitle(for: item.slot),
                    isCompact: cardH < 46,
                    cardHeight: cardH
                )
                .frame(width: colW, height: cardH)
                .offset(x: xOff, y: yOff)
            }

            nowLine(width: width)

            Color.clear
                .frame(width: 1, height: 1)
                .id("now-anchor")
                .offset(y: timeY(Date()))
        }
        .frame(width: width, height: totalH)
    }

    // MARK: - Hour grid (Canvas for efficiency + SwiftUI labels for crisp text)
    private func hourGrid(width: CGFloat, totalH: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            Canvas { ctx, size in
                let gridColor = theme.gridLineColor
                let halfColor = theme.gridLineColor.opacity(0.45)

                for h in 0...TL.totalHours {
                    let y = CGFloat(h) * TL.hourHeight
                    var path = Path()
                    path.move(to: CGPoint(x: TL.labelWidth - 4, y: y))
                    path.addLine(to: CGPoint(x: size.width, y: y))
                    ctx.stroke(path, with: .color(gridColor), lineWidth: 0.5)

                    if h < TL.totalHours {
                        let yHalf = y + TL.hourHeight / 2
                        var half = Path()
                        half.move(to: CGPoint(x: TL.labelWidth, y: yHalf))
                        half.addLine(to: CGPoint(x: size.width, y: yHalf))
                        ctx.stroke(half, with: .color(halfColor), lineWidth: 0.4)
                    }
                }
            }
            .frame(width: width, height: totalH)
            .allowsHitTesting(false)

            ForEach(0..<TL.totalHours, id: \.self) { h in
                Text(hourLabel(h))
                    .font(.system(size: 10, weight: .regular, design: .rounded))
                    .foregroundStyle(theme.hourLabelColor)
                    .frame(width: TL.labelWidth - 8, alignment: .trailing)
                    .offset(x: 0, y: CGFloat(h) * TL.hourHeight - 7)
                    .allowsHitTesting(false)
            }
        }
    }

    // MARK: - Now line
    @ViewBuilder
    private func nowLine(width: CGFloat) -> some View {
        if Calendar.current.isDateInToday(appState.selectedDate) {
            let y = timeY(Date())
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [theme.nowLineColor, theme.nowLineColor.opacity(0.4)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(height: 2)
                    .padding(.leading, CGFloat(TL.labelWidth - 4))
                Circle()
                    .fill(theme.nowLineColor)
                    .frame(width: 8, height: 8)
                    .offset(x: TL.labelWidth - 8)
            }
            .frame(width: width, alignment: .leading)
            .offset(y: y - 4)
            .allowsHitTesting(false)
        }
    }

    // MARK: - Helpers
    private var dateLabel: String {
        if Calendar.current.isDateInToday(appState.selectedDate) { return "Today" }
        let f = DateFormatter()
        f.dateFormat = "MMM d, yyyy"
        return f.string(from: appState.selectedDate)
    }

    private func scrollToNow(_ proxy: ScrollViewProxy, delay: Double = 0.1) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            proxy.scrollTo("now-anchor", anchor: .center)
        }
    }

    private func timeY(_ date: Date) -> CGFloat {
        let cal = Calendar.current
        let h = CGFloat(cal.component(.hour, from: date))
        let m = CGFloat(cal.component(.minute, from: date))
        return (h + m / 60.0) * TL.hourHeight
    }

    private func slotH(_ slot: TimeSlot) -> CGFloat {
        // Use activeDuration (actual work time) for card height so cards reflect real effort,
        // not wall-clock span which inflates height when idle gaps exist within a merged card.
        let duration: TimeInterval
        if slot.status == .processed && slot.activeDuration > 0 {
            duration = slot.activeDuration
        } else {
            duration = slot.endTime.timeIntervalSince(slot.startTime)
        }
        return max(0, CGFloat(duration / 3600.0) * TL.hourHeight)
    }

    private func hourLabel(_ h: Int) -> String {
        if AppSettings.shared.use24HourClock {
            return String(format: "%02d:00", h)
        }
        if h == 0  { return "12a" }
        if h == 12 { return "12p" }
        return h < 12 ? "\(h)a" : "\(h - 12)p"
    }
}

// MARK: - Session Card View
struct SessionCardView: View {
    let slot: TimeSlot
    let title: String
    var isCompact: Bool = false
    var cardHeight: CGFloat = 0

    @State private var showDetail = false
    @State private var isHovered = false

    private var theme: AppTheme { AppSettings.shared.appTheme }
    private var catColor: Color { Theme.color(for: slot.category) }

    var body: some View {
        switch slot.status {
        case .processed:
            processedCard
        case .processing:
            placeholderCard(text: "Processing...", color: .gray, pulsing: true)
        case .continuous:
            placeholderCard(text: "Processing continuous", color: catColor, pulsing: false)
        case .pending:
            placeholderCard(text: "Analyzing...", color: .gray.opacity(0.5), pulsing: false, dashed: true)
        }
    }

    // MARK: - Processed Card (full content)

    private var processedCard: some View {
        Button { showDetail = true } label: { processedCardContent }
            .buttonStyle(.plain)
            .onHover { isHovered = $0 }
            .sheet(isPresented: $showDetail) {
                SessionDetailView(slot: slot)
            }
    }

    @ViewBuilder
    private var processedCardContent: some View {
        HStack(alignment: .top, spacing: 0) {
            Rectangle()
                .fill(catColor)
                .frame(width: 3)

            if isCompact {
                HStack(spacing: 5) {
                    if let first = slot.activities.first {
                        AppIconImage(bundleID: first.bundleID, size: 11)
                    }
                    Text(title)
                        .font(.system(size: 10, weight: .semibold))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Text(Theme.formatDuration(slot.activeDuration))
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(catColor.opacity(0.9))
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
            } else {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 4) {
                        Text(title)
                            .font(.system(size: 11, weight: .semibold))
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        Text(Theme.formatTimeRange(slot.startTime, slot.endTime))
                            .font(.system(size: 9))
                            .foregroundStyle(theme.secondaryText)
                            .lineLimit(1)
                    }

                    HStack(spacing: 3) {
                        ForEach(slot.activities.prefix(5)) { app in
                            AppIconImage(bundleID: app.bundleID, size: 12)
                        }
                        if slot.activities.count > 5 {
                            Text("+\(slot.activities.count - 5)")
                                .font(.system(size: 9))
                                .foregroundStyle(.tertiary)
                        }
                        Spacer(minLength: 0)
                        Text(Theme.formatDuration(slot.activeDuration))
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(catColor.opacity(0.9))
                    }

                    if let summary = slot.summary, !summary.isEmpty, cardHeight >= 90 {
                        Divider().opacity(0.4)
                        Text(summary)
                            .font(.system(size: 10))
                            .foregroundStyle(theme.secondaryText)
                            .lineLimit(4)
                            .fixedSize(horizontal: false, vertical: false)
                    }
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 5)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            ZStack {
                theme.cardBg
                catColor.opacity(isHovered ? 0.18 : 0.08)
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: TL.cornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: TL.cornerRadius)
                .stroke(catColor.opacity(isHovered ? 0.55 : 0.22), lineWidth: 1)
        )
        .shadow(color: catColor.opacity(isHovered ? 0.2 : 0.0), radius: 6, y: 2)
        .shadow(color: theme.shadowColor.opacity(0.06), radius: 2, y: 1)
        .animation(.easeOut(duration: 0.1), value: isHovered)
    }

    // MARK: - Placeholder Cards (processing / continuous / pending)

    private func placeholderCard(text: String, color: Color, pulsing: Bool, dashed: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 0) {
            Rectangle()
                .fill(color)
                .frame(width: 3)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    if pulsing {
                        Circle()
                            .fill(color)
                            .frame(width: 6, height: 6)
                            .opacity(0.7)
                            .modifier(PulseModifier())
                    }
                    Text(text)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(theme.secondaryText)
                    Spacer(minLength: 0)
                    Text(Theme.formatTimeRange(slot.startTime, slot.endTime))
                        .font(.system(size: 9))
                        .foregroundStyle(theme.secondaryText.opacity(0.6))
                }
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(theme.cardBg.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: TL.cornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: TL.cornerRadius)
                .stroke(color.opacity(0.25), lineWidth: 1)
                .strokeBorder(style: dashed ? StrokeStyle(lineWidth: 1, dash: [4, 3]) : StrokeStyle(lineWidth: 1))
        )
    }
}

/// Subtle pulse animation modifier for processing indicator
private struct PulseModifier: ViewModifier {
    @State private var isPulsing = false
    func body(content: Content) -> some View {
        content
            .scaleEffect(isPulsing ? 1.3 : 1.0)
            .opacity(isPulsing ? 0.4 : 1.0)
            .animation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true), value: isPulsing)
            .onAppear { isPulsing = true }
    }
}
