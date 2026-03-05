import SwiftUI

struct MenuBarView: View {
    @Bindable var appState = AppState.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 12) {
            // Status header
            HStack {
                Image(systemName: "bolt.fill")
                    .foregroundStyle(.blue)
                Text("FlowTrack")
                    .font(.headline)
                Spacer()
                Circle()
                    .fill(ActivityTracker.shared.isTracking ? .green : .red)
                    .frame(width: 8, height: 8)
            }

            Divider()

            // Current activity
            if !ActivityTracker.shared.currentApp.isEmpty {
                HStack {
                    Text("Current:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(ActivityTracker.shared.currentApp)
                        .font(.caption.bold())
                    Spacer()
                }
            }

            // Quick stats
            HStack(spacing: 16) {
                StatPill(label: "Focus", value: "\(Int(focusScore))%")
                StatPill(label: "Sessions", value: "\(appState.timeSlots.filter { !$0.isIdle }.count)")
                StatPill(label: "Active", value: activeTime)
            }

            Divider()

            // Actions
            Button(action: openDashboard) {
                HStack {
                    Image(systemName: "rectangle.grid.1x2")
                    Text("Open Dashboard")
                    Spacer()
                    Text("⌘D")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)

            Button(action: openSettingsAction) {
                HStack {
                    Image(systemName: "gear")
                    Text("Settings")
                    Spacer()
                    Text("⌘,")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)

            Divider()

            // Tracking toggle
            Button(action: {
                if ActivityTracker.shared.isTracking {
                    ActivityTracker.shared.stopTracking()
                } else {
                    ActivityTracker.shared.startTracking()
                }
            }) {
                HStack {
                    Image(systemName: ActivityTracker.shared.isTracking ? "pause.fill" : "play.fill")
                    Text(ActivityTracker.shared.isTracking ? "Pause Tracking" : "Resume Tracking")
                    Spacer()
                }
            }
            .buttonStyle(.plain)

            Button(action: {
                UserDefaults.standard.set(true, forKey: "reallyQuit")
                NSApp.terminate(nil)
            }) {
                HStack {
                    Image(systemName: "power")
                    Text("Completely Quit FlowTrack")
                    Spacer()
                }
                .foregroundStyle(.red)
            }
            .buttonStyle(.plain)
        }
        .padding()
        .frame(width: 300)
    }

    private func openDashboard() {
        dismiss()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: "dashboard")
        }
    }

    private func openSettingsAction() {
        dismiss()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            // openSettings() doesn't work reliably from MenuBarExtra — use sendAction
            if #available(macOS 14, *) {
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            } else {
                NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
            }
        }
    }

    private var focusScore: Double {
        let productive = appState.categoryStats.filter { $0.category.isProductive }.reduce(0) { $0 + $1.totalSeconds }
        let total = appState.categoryStats.reduce(0) { $0 + $1.totalSeconds }
        guard total > 0 else { return 0 }
        return productive / total * 100
    }

    private var activeTime: String {
        let total = appState.timeSlots.filter { !$0.isIdle }.reduce(0.0) { $0 + $1.duration }
        return Theme.formatDuration(total)
    }
}

struct StatPill: View {
    let label: String
    let value: String

    var body: some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.caption.bold())
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .background(Color.gray.opacity(0.1))
        .cornerRadius(8)
    }
}
