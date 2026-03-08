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
    var reopenDashboard: (() -> Void)?
    private var windowCloseObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        TrackingLifecycle.shared.startTracking()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            self.showDashboard()
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        TrackingLifecycle.shared.stopTracking()
        return .terminateNow
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showDashboard()
        return true
    }

    func showDashboard() {
        FocusModeEngine.shared.pauseForDashboard()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "dashboard" }) {
            window.makeKeyAndOrderFront(nil)
            observeClose(of: window)
        } else {
            reopenDashboard?()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                if let win = NSApp.windows.first(where: { $0.identifier?.rawValue == "dashboard" }) {
                    win.makeKeyAndOrderFront(nil)
                    self?.observeClose(of: win)
                }
            }
        }
        FocusModeEngine.shared.resumeAfterDashboard()
    }

    /// Switch back to .accessory only when the dashboard window actually closes.
    private func observeClose(of window: NSWindow) {
        if let existing = windowCloseObserver {
            NotificationCenter.default.removeObserver(existing)
        }
        windowCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            if !AppSettings.shared.showDockIcon {
                NSApp.setActivationPolicy(.accessory)
            }
            if let obs = self.windowCloseObserver {
                NotificationCenter.default.removeObserver(obs)
                self.windowCloseObserver = nil
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
