import Foundation
import AppKit
import Combine
import IOKit.ps

@MainActor
final class ActivityTracker: ObservableObject {
    static let shared = ActivityTracker()

    @Published var isTracking = false
    @Published var currentApp: String = ""
    @Published var currentTitle: String = ""

    private var timer: Timer?
    private var lastActivity: Date = Date()
    private let idleThreshold: TimeInterval = 120
    private var lastSavedApp: String = ""
    private var lastSavedTitle: String = ""
    private var consecutiveIdleCount = 0

    private init() {}

    func startTracking() {
        guard !isTracking else { return }
        isTracking = true
        scheduleTimer()
        poll()
        // Run auto-cleanup on launch
        Database.shared.autoCleanupIfNeeded()
    }

    func stopTracking() {
        isTracking = false
        timer?.invalidate()
        timer = nil
    }

    private func scheduleTimer() {
        timer?.invalidate()
        // Poll every 5s normally, every 15s when idle, every 10s on battery
        let interval: TimeInterval
        if consecutiveIdleCount > 6 {
            interval = 15
        } else if isOnBattery() {
            interval = 10
        } else {
            interval = 5
        }
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.poll()
            }
        }
    }

    private func poll() {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else { return }
        let appName = frontApp.localizedName ?? "Unknown"
        let bundleID = frontApp.bundleIdentifier ?? ""
        let windowTitle = getWindowTitle(for: frontApp)
        let url = getBrowserURL(appName: appName, bundleID: bundleID)
        let isIdle = checkIdle()

        currentApp = appName
        currentTitle = windowTitle

        if !isIdle {
            lastActivity = Date()
            consecutiveIdleCount = 0
        } else {
            consecutiveIdleCount += 1
        }

        let idleDuration = Date().timeIntervalSince(lastActivity)
        let recordIsIdle = idleDuration > idleThreshold

        // Skip saving if idle and we already recorded idle
        if recordIsIdle && consecutiveIdleCount > 2 {
            // Reschedule with longer interval when idle
            if consecutiveIdleCount == 3 {
                scheduleTimer()
            }
            return
        }

        // Categorize
        let category: Category
        if recordIsIdle {
            category = .idle
        } else if let ruleCat = RuleEngine.shared.categorize(appName: appName, bundleID: bundleID, windowTitle: windowTitle, url: url) {
            category = ruleCat
        } else {
            category = .uncategorized
        }

        let duration: TimeInterval = consecutiveIdleCount > 6 ? 15 : (isOnBattery() ? 10 : 5)

        let record = ActivityRecord(
            timestamp: Date(),
            appName: appName,
            bundleID: bundleID,
            windowTitle: windowTitle,
            url: url,
            category: category,
            isIdle: recordIsIdle,
            duration: duration
        )

        try? Database.shared.saveActivity(record)
        lastSavedApp = appName
        lastSavedTitle = windowTitle
    }

    private func getWindowTitle(for app: NSRunningApplication) -> String {
        let pid = app.processIdentifier
        let appElement = AXUIElementCreateApplication(pid)
        var value: AnyObject?
        let result = AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &value)
        guard result == .success else { return "" }
        var titleValue: AnyObject?
        AXUIElementCopyAttributeValue(value as! AXUIElement, kAXTitleAttribute as CFString, &titleValue)
        return titleValue as? String ?? ""
    }

    private func getBrowserURL(appName: String, bundleID: String) -> String? {
        let browsers = ["Safari", "Google Chrome", "Firefox", "Arc", "Brave Browser", "Microsoft Edge", "Opera"]
        guard browsers.contains(where: { appName.contains($0) }) else { return nil }

        var script: String
        if appName.contains("Safari") {
            script = "tell application \"Safari\" to get URL of current tab of front window"
        } else if appName.contains("Chrome") || appName.contains("Brave") || appName.contains("Edge") || appName.contains("Opera") {
            let appTarget = appName.contains("Chrome") ? "Google Chrome" :
                           appName.contains("Brave") ? "Brave Browser" :
                           appName.contains("Edge") ? "Microsoft Edge" :
                           appName.contains("Opera") ? "Opera" : appName
            script = "tell application \"\(appTarget)\" to get URL of active tab of front window"
        } else if appName.contains("Arc") {
            script = "tell application \"Arc\" to get URL of active tab of front window"
        } else {
            return nil
        }

        let appleScript = NSAppleScript(source: script)
        var error: NSDictionary?
        let result = appleScript?.executeAndReturnError(&error)
        return result?.stringValue
    }

    private func checkIdle() -> Bool {
        let idleTime = CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: .mouseMoved)
        let keyIdle = CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: .keyDown)
        return min(idleTime, keyIdle) > 30
    }

    private func isOnBattery() -> Bool {
        let snapshot = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let type = IOPSGetProvidingPowerSourceType(snapshot).takeRetainedValue() as String
        return type == kIOPSBatteryPowerValue
    }
}
