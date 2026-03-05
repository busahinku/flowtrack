import Foundation
import AppKit
import Combine

@MainActor
final class ActivityTracker: ObservableObject {
    static let shared = ActivityTracker()

    @Published var isTracking = false
    @Published var currentApp: String = ""
    @Published var currentTitle: String = ""

    private var timer: Timer?
    private var lastActivity: Date = Date()
    private let idleThreshold: TimeInterval = 120 // 2 minutes

    private init() {}

    func startTracking() {
        guard !isTracking else { return }
        isTracking = true
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.poll()
            }
        }
        poll()
    }

    func stopTracking() {
        isTracking = false
        timer?.invalidate()
        timer = nil
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
        }

        let idleDuration = Date().timeIntervalSince(lastActivity)
        let recordIsIdle = idleDuration > idleThreshold

        // Categorize
        let category: Category
        if recordIsIdle {
            category = .idle
        } else if let ruleCat = RuleEngine.shared.categorize(appName: appName, bundleID: bundleID, windowTitle: windowTitle, url: url) {
            category = ruleCat
        } else {
            category = .uncategorized
        }

        let record = ActivityRecord(
            timestamp: Date(),
            appName: appName,
            bundleID: bundleID,
            windowTitle: windowTitle,
            url: url,
            category: category,
            isIdle: recordIsIdle,
            duration: 5
        )

        try? Database.shared.saveActivity(record)
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
}
