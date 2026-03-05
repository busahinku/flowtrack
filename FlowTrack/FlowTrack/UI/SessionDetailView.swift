import SwiftUI

// MARK: - Session Detail View
struct SessionDetailView: View {
    let slot: TimeSlot
    @Environment(\.dismiss) private var dismiss
    @Bindable var appState = AppState.shared

    private var theme: AppTheme { AppSettings.shared.appTheme }
    private var catColor: Color { Theme.color(for: slot.category) }

    var body: some View {
        VStack(spacing: 0) {
            headerStrip
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 12) {
                    if let summary = appState.sessionSummaries[slot.id] {
                        summaryCard(summary)
                    }
                    appsCard
                }
                .padding(16)
            }
        }
        .frame(width: 420)
        .background(theme.timelineBg)
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - Header strip
    private var headerStrip: some View {
        ZStack(alignment: .topTrailing) {
            // Category color gradient bar at very top
            catColor.opacity(0.12)
                .frame(height: 4)
                .frame(maxWidth: .infinity)
                .offset(y: -1)     // hidden under clipShape, just tints top edge

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 5) {
                        // Category pill
                        HStack(spacing: 5) {
                            Image(systemName: slot.category.icon)
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(catColor)
                            Text(slot.category.rawValue.uppercased())
                                .font(.system(size: 10, weight: .bold, design: .rounded))
                                .foregroundStyle(catColor)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(catColor.opacity(0.12), in: Capsule())

                        // Title
                        Text(appState.sessionTitle(for: slot))
                            .font(.system(size: 17, weight: .semibold))
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer()

                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.secondary)
                            .frame(width: 24, height: 24)
                            .background(.secondary.opacity(0.1), in: Circle())
                    }
                    .buttonStyle(.plain)
                }

                // Meta row: time range · duration
                HStack(spacing: 8) {
                    Label(Theme.formatTimeRange(slot.startTime, slot.endTime), systemImage: "clock")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)

                    Text("·")
                        .foregroundStyle(.tertiary)

                    Text(Theme.formatDuration(slot.duration))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 14)
        }
        .overlay(alignment: .bottom) {
            Divider().opacity(0.5)
        }
    }

    // MARK: - AI Summary card
    private func summaryCard(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                Image(systemName: "sparkles")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.purple)
                Text("AI Summary")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(.primary.opacity(0.85))
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.purple.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.purple.opacity(0.12), lineWidth: 1)
        )
    }

    // MARK: - Apps card
    private var appsCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Apps Used")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 8)

            ForEach(Array(slot.activities.enumerated()), id: \.element.id) { idx, activity in
                if idx > 0 {
                    Divider()
                        .padding(.leading, 44)
                        .opacity(0.4)
                }
                AppDetailRow(
                    activity: activity,
                    totalDuration: slot.duration,
                    catColor: catColor
                )
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
        }
        .background(theme.cardBg, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(.primary.opacity(0.06), lineWidth: 1)
        )
    }
}

// MARK: - App Detail Row
struct AppDetailRow: View {
    let activity: ActivitySummary
    var totalDuration: TimeInterval = 0
    var catColor: Color = .blue
    @State private var expanded = false

    private var fraction: Double {
        guard totalDuration > 0 else { return 0 }
        return min(activity.duration / totalDuration, 1.0)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() } } label: {
                HStack(spacing: 10) {
                    AppIconImage(bundleID: activity.bundleID, size: 28)
                        .clipShape(RoundedRectangle(cornerRadius: 6))

                    VStack(alignment: .leading, spacing: 2) {
                        Text(activity.appName)
                            .font(.system(size: 13, weight: .medium))
                            .lineLimit(1)

                        // Duration bar
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(.primary.opacity(0.06))
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(catColor.opacity(0.5))
                                    .frame(width: geo.size.width * fraction)
                            }
                        }
                        .frame(height: 3)
                    }

                    Spacer(minLength: 8)

                    Text(Theme.formatDuration(activity.duration))
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()

                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
            }
            .buttonStyle(.plain)

            if expanded {
                VStack(alignment: .leading, spacing: 4) {
                    if !activity.title.isEmpty {
                        Text(activity.title)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    if let url = activity.url {
                        Text(url)
                            .font(.system(size: 11))
                            .foregroundStyle(.blue.opacity(0.8))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .padding(.leading, 38)
                .padding(.top, 6)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}
