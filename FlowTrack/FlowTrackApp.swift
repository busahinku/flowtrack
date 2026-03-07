import SwiftUI
import AppKit

@main
struct FlowTrackApp: App {
    @NSApplicationDelegateAdaptor(FlowTrackAppDelegate.self) var appDelegate
    @State private var showOnboarding = !UserDefaults.standard.bool(forKey: "hasCompletedOnboarding")
    @Environment(\.openWindow) private var openWindow

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
        let showDock = AppSettings.shared.showDockIcon
        NSApp.setActivationPolicy(showDock ? .regular : .accessory)
        UserDefaults.standard.removeObject(forKey: "reallyQuit")
        // Start activity tracking immediately on launch
        ActivityTracker.shared.startTracking()
        // Ensure the dashboard window is visible and focused on every launch
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            if let win = NSApp.windows.first(where: { $0.identifier?.rawValue == "dashboard" }) {
                win.makeKeyAndOrderFront(nil)
            } else {
                self.reopenDashboard?()
            }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if UserDefaults.standard.bool(forKey: "reallyQuit") {
            return .terminateNow
        }
        for window in NSApp.windows { window.close() }
        // Defer activation policy change so SwiftUI's MenuBarExtra finishes processing
        // the termination event before the policy switches — otherwise the menu bar
        // icon stays visible but stops responding to clicks.
        DispatchQueue.main.async {
            NSApp.setActivationPolicy(.accessory)
        }
        return .terminateCancel
    }

    // Dock icon clicked — show existing window or recreate it
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "dashboard" }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            // Window was deallocated — recreate via stored openWindow closure
            reopenDashboard?()
        }
        return true
    }
}
