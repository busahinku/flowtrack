import SwiftUI
import AppKit

@main
struct FlowTrackApp: App {
    @NSApplicationDelegateAdaptor(FlowTrackAppDelegate.self) var appDelegate
    @State private var showOnboarding = !UserDefaults.standard.bool(forKey: "hasCompletedOnboarding")

    var body: some Scene {
        // Menu Bar
        MenuBarExtra("FlowTrack", systemImage: "bolt.fill") {
            MenuBarView()
                .preferredColorScheme(AppSettings.shared.appTheme.colorScheme)
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
                    // Make title bar transparent
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        for window in NSApp.windows where window.identifier?.rawValue == "dashboard" || window.title == "FlowTrack" {
                            window.titlebarAppearsTransparent = true
                            window.titleVisibility = .visible
                            window.isMovableByWindowBackground = true
                        }
                    }
                }
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: true))

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
}
