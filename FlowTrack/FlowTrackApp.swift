import SwiftUI
import AppKit
import Sparkle

@main
struct FlowTrackApp: App {
    @NSApplicationDelegateAdaptor(FlowTrackAppDelegate.self) var appDelegate
    @State private var showOnboarding = !UserDefaults.standard.bool(forKey: "hasCompletedOnboarding")
    @Environment(\.openWindow) private var openWindow
    private let updater = AppUpdater.shared

    var body: some Scene {
        // Menu Bar
        MenuBarExtra {
            MenuBarView()
                .preferredColorScheme(AppSettings.shared.appTheme.colorScheme)
        } label: {
            MenuBarLabelView()
        }
        .menuBarExtraStyle(.window)

        // Dashboard Window
        Window("FlowTrack", id: "dashboard") {
            DashboardView()
                .preferredColorScheme(AppSettings.shared.appTheme.colorScheme)
                .sheet(isPresented: $showOnboarding) {
                    OnboardingView(isPresented: $showOnboarding)
                }
                .onAppear {
                    AppBlockerMonitor.shared.start()
                    // Capture openWindow in delegate so dock-click can reopen after close
                    appDelegate.reopenDashboard = { openWindow(id: "dashboard") }
                }
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: false))

        // Settings
        Settings {
            SettingsView()
                .preferredColorScheme(AppSettings.shared.appTheme.colorScheme)
        }
    }
}

// MARK: - App Delegate
@MainActor
class FlowTrackAppDelegate: NSObject, NSApplicationDelegate {
    /// Set by the dashboard view on first appear; safe to call even after the window is closed.
    var reopenDashboard: (() -> Void)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Start activity tracking immediately on launch
        TrackingLifecycle.shared.startTracking()
        // Ensure the dashboard window is visible and focused on every launch
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            // Temporarily show dock icon so macOS creates/activates the window
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            if let win = NSApp.windows.first(where: { $0.identifier?.rawValue == "dashboard" }) {
                win.makeKeyAndOrderFront(nil)
            } else {
                self.reopenDashboard?()
            }
            // Restore user's dock preference after the window is visible
            if !AppSettings.shared.showDockIcon {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    NSApp.setActivationPolicy(.accessory)
                }
            }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        TrackingLifecycle.shared.stopTracking()
        return .terminateNow
    }

    // Dock icon clicked — show existing window or recreate it
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showDashboard()
        return true
    }

    /// Show the dashboard window, temporarily enabling dock icon if needed.
    func showDashboard() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "dashboard" }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            reopenDashboard?()
        }
        // Restore accessory mode if user disabled dock icon
        if !AppSettings.shared.showDockIcon {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }
}

@MainActor
final class TrackingLifecycle {
    static let shared = TrackingLifecycle()

    private init() {}

    func startTracking() {
        StudyTrackerEngine.shared.handleTrackingStarted()
        ActivityTracker.shared.startTracking()
    }

    func stopTracking() {
        FocusModeEngine.shared.handleTrackingStopped()
        StudyTrackerEngine.shared.handleTrackingStopped()
        ActivityTracker.shared.stopTracking()
    }

    func toggleTracking() {
        if ActivityTracker.shared.isTracking {
            stopTracking()
        } else {
            startTracking()
        }
    }
}
