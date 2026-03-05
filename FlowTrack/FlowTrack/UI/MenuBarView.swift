import SwiftUI
import Combine

struct MenuBarView: View {
    @Bindable var appState = AppState.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    @State private var currentSessionDuration: String = ""
    private let sessionTimer = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 12) {
            // Status header
            HStack {
                ThemeAwareMenuIcon(size: 20)
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
                    if !currentSessionDuration.isEmpty {
                        Text(currentSessionDuration)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .onReceive(sessionTimer) { _ in updateSessionDuration() }
                .onAppear { updateSessionDuration() }
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

            SettingsLink {
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

    private func updateSessionDuration() {
        let elapsed = Date().timeIntervalSince(ActivityTracker.shared.currentAppSince)
        let minutes = Int(elapsed / 60)
        if minutes < 1 {
            currentSessionDuration = "< 1 min"
        } else if minutes < 60 {
            currentSessionDuration = "\(minutes) min"
        } else {
            let hours = minutes / 60
            let mins = minutes % 60
            currentSessionDuration = mins > 0 ? "\(hours)h \(mins)m" : "\(hours)h"
        }
    }

    private func openDashboard() {
        dismiss()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: "dashboard")
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
