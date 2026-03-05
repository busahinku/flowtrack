import Foundation
import AppKit
import Combine
import IOKit.ps
import UserNotifications

@MainActor
final class ActivityTracker: ObservableObject {
    static let shared = ActivityTracker()

    @Published var isTracking = false
    @Published var currentApp: String = "" {
        didSet { if currentApp != oldValue { currentAppSince = Date() } }
    }
    @Published var currentTitle: String = ""
    private(set) var currentAppSince: Date = Date()

    private var timer: Timer?
    private var batteryMonitorTimer: Timer?
    private var lastActivity: Date = Date()
    private var idleThreshold: TimeInterval { TimeInterval(AppSettings.shared.idleThresholdSeconds) }
    private var consecutiveIdleCount = 0
    // Cached battery state — refreshed every 60s to avoid IOKit overhead on every poll
    private var cachedOnBattery: Bool = false
    // Distraction alert tracking
    private var distractionStartTime: Date?
    private var lastDistractionAlertFired: Date?

    private init() {}

    func startTracking() {
        guard !isTracking else { return }
        isTracking = true
        cachedOnBattery = isOnBattery()
        scheduleTimer()
        scheduleBatteryMonitor()
        poll()
        Database.shared.autoCleanupIfNeeded()
    }

    func stopTracking() {
        isTracking = false
        timer?.invalidate()
        timer = nil
        batteryMonitorTimer?.invalidate()
        batteryMonitorTimer = nil
    }

    private func scheduleBatteryMonitor() {
        batteryMonitorTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let newBattery = self.isOnBattery()
                if newBattery != self.cachedOnBattery {
                    self.cachedOnBattery = newBattery
                    self.scheduleTimer()
                }
            }
        }
    }

    private func scheduleTimer() {
        timer?.invalidate()
        let interval: TimeInterval
        if consecutiveIdleCount > 6 {
            interval = 15
        } else if cachedOnBattery {
            interval = 10
        } else {
            interval = 5
        }
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            Task { @MainActor [weak self] in
                self?.poll()
            }
        }
    }

    private func poll() {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else { return }
        let appName = frontApp.localizedName ?? "Unknown"
        let bundleID = frontApp.bundleIdentifier ?? ""

        // Skip excluded apps
        if AppSettings.shared.excludedBundleIDs.contains(bundleID) { return }

        let rawTitle = AppSettings.shared.captureWindowTitles ? getWindowTitle(for: frontApp) : ""
        let windowTitle = rawTitle
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

        if recordIsIdle && consecutiveIdleCount > 2 {
            if consecutiveIdleCount == 3 { scheduleTimer() }
            return
        }

        let category: Category
        if recordIsIdle {
            category = .idle
        } else if let ruleCat = RuleEngine.shared.categorize(appName: appName, bundleID: bundleID, windowTitle: windowTitle, url: nil) {
            category = ruleCat
        } else {
            category = .uncategorized
        }

        let duration: TimeInterval = consecutiveIdleCount > 6 ? 15 : (cachedOnBattery ? 10 : 5)
        let timestamp = Date()

        // Distraction alert tracking
        checkDistractionAlert(category: category)

        let knownBrowsers = ["Safari", "Google Chrome", "Firefox", "Arc", "Brave Browser", "Microsoft Edge", "Opera"]
        let isBrowser = knownBrowsers.contains(where: { appName.contains($0) })

        if isBrowser {
            // Fetch URL off the main actor — AppleScript blocks for 100–300ms
            Task.detached(priority: .utility) {
                let url = ActivityTracker.fetchBrowserURL(appName: appName)
                let finalCategory: Category
                if !recordIsIdle, let url,
                   let urlCat = await RuleEngine.shared.categorize(appName: appName, bundleID: bundleID, windowTitle: windowTitle, url: url) {
                    finalCategory = urlCat
                } else {
                    finalCategory = category
                }
                let record = ActivityRecord(
                    timestamp: timestamp, appName: appName, bundleID: bundleID,
                    windowTitle: windowTitle, url: url, category: finalCategory,
                    isIdle: recordIsIdle, duration: duration
                )
                try? await Database.shared.saveActivity(record)
            }
        } else {
            let record = ActivityRecord(
                timestamp: timestamp, appName: appName, bundleID: bundleID,
                windowTitle: windowTitle, url: nil, category: category,
                isIdle: recordIsIdle, duration: duration
            )
            try? Database.shared.saveActivity(record)
        }
    }

    private func getWindowTitle(for app: NSRunningApplication) -> String {
        let pid = app.processIdentifier
        let appElement = AXUIElementCreateApplication(pid)
        var value: AnyObject?
        let result = AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &value)
        // Nil-check value before force-casting: AXUIElement is a CF type so as? always succeeds
        // and triggers a compiler error; force-cast after nil/success guard is safe.
        guard result == .success, let rawValue = value else { return "" }
        let axElement = rawValue as! AXUIElement // safe: kAXFocusedWindowAttribute always yields AXUIElement
        var titleValue: AnyObject?
        AXUIElementCopyAttributeValue(axElement, kAXTitleAttribute as CFString, &titleValue)
        return titleValue as? String ?? ""
    }

    /// Runs AppleScript to get the active browser tab URL.
    /// Must be called off the main actor — executeAndReturnError blocks for 100–300ms.
    nonisolated static func fetchBrowserURL(appName: String) -> String? {
        let script: String
        if appName.contains("Safari") {
            script = "tell application \"Safari\" to get URL of current tab of front window"
        } else if appName.contains("Chrome") {
            script = "tell application \"Google Chrome\" to get URL of active tab of front window"
        } else if appName.contains("Brave") {
            script = "tell application \"Brave Browser\" to get URL of active tab of front window"
        } else if appName.contains("Edge") {
            script = "tell application \"Microsoft Edge\" to get URL of active tab of front window"
        } else if appName.contains("Opera") {
            script = "tell application \"Opera\" to get URL of active tab of front window"
        } else if appName.contains("Arc") {
            script = "tell application \"Arc\" to get URL of active tab of front window"
        } else if appName.contains("Firefox") {
            script = "tell application \"Firefox\" to get URL of active tab of front window"
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

    private func checkDistractionAlert(category: Category) {
        let alertMinutes = AppSettings.shared.distractionAlertMinutes
        guard alertMinutes > 0 else {
            distractionStartTime = nil
            return
        }

        if category == .distraction || category == .entertainment {
            if distractionStartTime == nil { distractionStartTime = Date() }
            let elapsed = Date().timeIntervalSince(distractionStartTime!)
            let threshold = TimeInterval(alertMinutes * 60)
            // Only fire once per threshold period
            let canFire = lastDistractionAlertFired.map { Date().timeIntervalSince($0) > threshold } ?? true
            if elapsed >= threshold && canFire {
                lastDistractionAlertFired = Date()
                fireDistractionNotification(minutes: alertMinutes)
            }
        } else {
            distractionStartTime = nil
        }
    }

    private func fireDistractionNotification(minutes: Int) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "Distraction Alert"
            content.body = "You've been on a distraction app for \(minutes)+ minutes. Time to refocus?"
            content.sound = .default
            let request = UNNotificationRequest(identifier: "distraction-\(Date().timeIntervalSince1970)", content: content, trigger: nil)
            UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
        }
    }
}
