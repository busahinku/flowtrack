import SwiftUI

// MARK: - Session Detail View (popup from StatsView sessions)
struct SessionDetailView: View {
    let slot: TimeSlot
    @Environment(\.dismiss) private var dismiss
    @Bindable var appState = AppState.shared

    private var theme: AppTheme { AppSettings.shared.appTheme }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Header
                HStack {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Theme.color(for: slot.category))
                        .frame(width: 6, height: 40)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(appState.sessionTitle(for: slot))
                            .font(.title2.bold())
                        HStack(spacing: 8) {
                            Image(systemName: slot.category.icon)
                                .foregroundStyle(Theme.color(for: slot.category))
                            Text(slot.category.rawValue)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Text("•")
                                .foregroundStyle(.secondary)
                            Text(Theme.formatTimeRange(slot.startTime, slot.endTime))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Text("•")
                                .foregroundStyle(.secondary)
                            Text(Theme.formatDuration(slot.duration))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
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

                // AI Summary
                if let summary = appState.sessionSummaries[slot.id] {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("AI Summary", systemImage: "sparkles")
                            .font(.headline)
                        Text(summary)
                            .font(.body)
                            .foregroundStyle(.secondary)
                    }
                    .padding()
                    .background(theme.cardBg)
                    .cornerRadius(10)
                }

                // Apps Used
                VStack(alignment: .leading, spacing: 8) {
                    Text("Apps Used")
                        .font(.headline)

                    ForEach(slot.activities) { activity in
                        AppDetailRow(activity: activity)
                    }
                }
                .padding()
                .background(theme.cardBg)
                .cornerRadius(10)
            }
            .padding()
        }
        .frame(minWidth: 500, minHeight: 350)
        .background(theme.timelineBg)
    }
}

// MARK: - App Detail Row
struct AppDetailRow: View {
    let activity: ActivitySummary
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button(action: { expanded.toggle() }) {
                HStack {
                    AppIconImage(bundleID: activity.bundleID, size: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(activity.appName)
                            .font(.subheadline.bold())
                        Text(Theme.formatDuration(activity.duration))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)

            if expanded {
                VStack(alignment: .leading, spacing: 4) {
                    Text(activity.title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                    if let url = activity.url {
                        Text(url)
                            .font(.caption2)
                            .foregroundStyle(.blue)
                            .lineLimit(1)
                    }
                }
                .padding(.leading, 32)
            }
        }
        .padding(.vertical, 4)
    }
}
