import SwiftUI
import AppKit

extension Notification.Name {
    static let openDashboard = Notification.Name("openDashboard")
}

@main
struct FlowTrackApp: App {
    @NSApplicationDelegateAdaptor(FlowTrackAppDelegate.self) var appDelegate
    @State private var showOnboarding = !UserDefaults.standard.bool(forKey: "hasCompletedOnboarding")
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        // Menu Bar (theme-aware custom icon)
        MenuBarExtra {
            MenuBarView()
                .preferredColorScheme(AppSettings.shared.appTheme.colorScheme)
        } label: {
            MenuBarIconView(size: 18)
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
                    ActivityTracker.shared.startTracking()
                }
                .onReceive(NotificationCenter.default.publisher(for: .openDashboard)) { _ in
                    openWindow(id: "dashboard")
                    NSApp.activate(ignoringOtherApps: true)
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
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Set dock icon visibility
        let showDock = AppSettings.shared.showDockIcon
        NSApp.setActivationPolicy(showDock ? .regular : .accessory)
        // Clear stale quit flag
        UserDefaults.standard.removeObject(forKey: "reallyQuit")
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if UserDefaults.standard.bool(forKey: "reallyQuit") {
            return .terminateNow
        }
        // Close windows instead of quitting (app stays in menu bar)
        for window in NSApp.windows {
            window.close()
        }
        NSApp.setActivationPolicy(.accessory)
        return .terminateCancel
    }

    // Dock icon clicked — always bring the dashboard forward
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "dashboard" }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            // Window was fully deallocated — ask the SwiftUI scene to recreate it
            NotificationCenter.default.post(name: .openDashboard, object: nil)
        }
        return true
    }
}
