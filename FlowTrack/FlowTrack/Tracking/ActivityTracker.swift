import Foundation
import AppKit
import Combine
import IOKit.ps
import UserNotifications
import OSLog

private let trackerLogger = Logger(subsystem: "com.flowtrack", category: "ActivityTracker")

@MainActor
final class ActivityTracker: ObservableObject {
    static let shared = ActivityTracker()

    @Published var isTracking = false
    @Published var currentApp: String = "" {
        didSet { if currentApp != oldValue { currentAppSince = Date() } }
    }
    @Published var currentTitle: String = ""
    private(set) var currentAppSince: Date = Date()
    /// App switches today — a proxy for context-switching / fragmentation
    private(set) var todaySwitchCount: Int = 0

    // MARK: - Private State
    private var heartbeatTimer: Timer?
    private var batteryMonitorTimer: Timer?
    private var lastActivity: Date = Date()
    private var idleThreshold: TimeInterval { TimeInterval(AppSettings.shared.idleThresholdSeconds) }
    private var consecutiveIdleCount = 0
    private var cachedOnBattery: Bool = false
    private var isScreenAsleep = false

    // Deduplication state — skip redundant DB writes
    private var lastSavedBundleID: String = ""
    private var lastSavedTitle: String = ""
    private var lastSavedURL: String? = nil
    private var lastSavedIsIdle: Bool = false

    // Browser URL cache — only re-fetch AppleScript when title actually changes
    private var lastBrowserTitle: String = ""
    private var cachedBrowserURL: String? = nil

    // App Nap exemption token
    private var activityToken: NSObjectProtocol?

    // NSWorkspace notification observers
    private var appSwitchObserver: Any?
    private var screenSleepObserver: Any?
    private var screenWakeObserver: Any?
    private var systemSleepObserver: Any?
    private var systemWakeObserver: Any?

    // Switch count reset
    private var lastSwitchResetDate: Date = Calendar.current.startOfDay(for: Date())

    // Distraction alert tracking
    private var distractionStartTime: Date?
    private var lastDistractionAlertFired: Date?

    private let knownBrowsers = ["Safari", "Google Chrome", "Firefox", "Arc", "Brave Browser", "Microsoft Edge", "Opera"]

    private init() {}

    // MARK: - Start / Stop

    func startTracking() {
        guard !isTracking else { return }
        isTracking = true
        cachedOnBattery = isOnBattery()

        // Prevent App Nap from throttling background timers
        activityToken = ProcessInfo.processInfo.beginActivity(
            options: .background,
            reason: "FlowTrack background activity tracking"
        )

        // Event-driven app switch detection — zero CPU between switches
        appSwitchObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] notification in
            Task { @MainActor [weak self] in self?.handleAppSwitch(notification) }
        }

        // Screen sleep/wake — pause tracking when display is off
        screenSleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.screensDidSleepNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.handleScreenSleep() }
        }
        screenWakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.handleScreenWake() }
        }
        systemSleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.handleScreenSleep() }
        }
        systemWakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.handleScreenWake() }
        }

        scheduleHeartbeat()
        scheduleBatteryMonitor()
        captureCurrentApp()
        Database.shared.autoCleanupIfNeeded()
    }

    func stopTracking() {
        isTracking = false
        heartbeatTimer?.invalidate(); heartbeatTimer = nil
        batteryMonitorTimer?.invalidate(); batteryMonitorTimer = nil
        if let token = activityToken { ProcessInfo.processInfo.endActivity(token) }
        activityToken = nil
        if let obs = appSwitchObserver { NSWorkspace.shared.notificationCenter.removeObserver(obs) }
        if let obs = screenSleepObserver { NSWorkspace.shared.notificationCenter.removeObserver(obs) }
        if let obs = screenWakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(obs) }
        if let obs = systemSleepObserver { NSWorkspace.shared.notificationCenter.removeObserver(obs) }
        if let obs = systemWakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(obs) }
        appSwitchObserver = nil; screenSleepObserver = nil; screenWakeObserver = nil
        systemSleepObserver = nil; systemWakeObserver = nil
    }

    // MARK: - Heartbeat (30s interval for duration + title change detection)

    private func scheduleHeartbeat() {
        heartbeatTimer?.invalidate()
        let interval: TimeInterval = cachedOnBattery ? 45 : 30
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            Task { @MainActor [weak self] in self?.heartbeat() }
        }
    }

    private func heartbeat() {
        guard !isScreenAsleep else { return }
        guard let frontApp = NSWorkspace.shared.frontmostApplication else { return }
        let appName = frontApp.localizedName ?? "Unknown"
        let bundleID = frontApp.bundleIdentifier ?? ""

        if AppSettings.shared.excludedBundleIDs.contains(bundleID) { return }

        let isIdle = checkIdle()
        if isIdle { consecutiveIdleCount += 1 } else { consecutiveIdleCount = 0; lastActivity = Date() }

        let idleDuration = Date().timeIntervalSince(lastActivity)
        let recordIsIdle = idleDuration > idleThreshold

        if recordIsIdle && consecutiveIdleCount > 3 { return }

        // Title change detection (AX API — lightweight, no AppleScript)
        let newTitle = AppSettings.shared.captureWindowTitles ? getWindowTitle(for: frontApp) : ""
        let titleChanged = newTitle != lastSavedTitle
        if titleChanged { currentTitle = newTitle }

        let duration: TimeInterval = cachedOnBattery ? 45 : 30
        let isBrowser = knownBrowsers.contains(where: { appName.contains($0) })

        // Deduplication: skip write if nothing changed
        let stateChanged = bundleID != lastSavedBundleID || titleChanged || recordIsIdle != lastSavedIsIdle

        if isBrowser {
            let urlFetchNeeded = titleChanged || cachedBrowserURL == nil
            if urlFetchNeeded {
                let capturedTitle = newTitle
                Task.detached(priority: .utility) {
                    let url = ActivityTracker.fetchBrowserURL(appName: appName)
                    await MainActor.run { [weak self] in
                        guard let self else { return }
                        self.cachedBrowserURL = url
                        self.lastBrowserTitle = capturedTitle
                        let cat = self.resolveCategory(appName: appName, bundleID: bundleID, title: capturedTitle, url: url, isIdle: recordIsIdle)
                        self.checkDistractionAlert(category: cat)
                        self.writeRecord(appName: appName, bundleID: bundleID, title: capturedTitle, url: url, category: cat, isIdle: recordIsIdle, duration: duration)
                        self.lastSavedBundleID = bundleID; self.lastSavedTitle = capturedTitle
                        self.lastSavedURL = url; self.lastSavedIsIdle = recordIsIdle
                    }
                }
            } else {
                // Same tab — write heartbeat with cached URL (proves presence), skip AppleScript
                let cat = resolveCategory(appName: appName, bundleID: bundleID, title: newTitle, url: cachedBrowserURL, isIdle: recordIsIdle)
                checkDistractionAlert(category: cat)
                writeRecord(appName: appName, bundleID: bundleID, title: newTitle, url: cachedBrowserURL, category: cat, isIdle: recordIsIdle, duration: duration)
                lastSavedBundleID = bundleID; lastSavedTitle = newTitle; lastSavedIsIdle = recordIsIdle
            }
        } else {
            cachedBrowserURL = nil
            let cat = resolveCategory(appName: appName, bundleID: bundleID, title: newTitle, url: nil, isIdle: recordIsIdle)
            checkDistractionAlert(category: cat)
            if stateChanged {
                writeRecord(appName: appName, bundleID: bundleID, title: newTitle, url: nil, category: cat, isIdle: recordIsIdle, duration: duration)
                lastSavedBundleID = bundleID; lastSavedTitle = newTitle; lastSavedIsIdle = recordIsIdle
            } else {
                // Same state — just write heartbeat (proves presence)
                writeRecord(appName: appName, bundleID: bundleID, title: newTitle, url: nil, category: cat, isIdle: recordIsIdle, duration: duration)
            }
        }
    }

    // MARK: - App Switch Handler (event-driven, instant)

    private func handleAppSwitch(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        let bundleID = app.bundleIdentifier ?? ""
        let appName = app.localizedName ?? "Unknown"

        if AppSettings.shared.excludedBundleIDs.contains(bundleID) { return }
        guard bundleID != lastSavedBundleID else { return } // same app, skip

        // Track app switches for context-switching metric
        resetSwitchCountIfNewDay()
        todaySwitchCount += 1
        trackerLogger.debug("App switch: \(appName, privacy: .public) (#\(self.todaySwitchCount))")

        currentApp = appName
        consecutiveIdleCount = 0
        cachedBrowserURL = nil
        lastBrowserTitle = ""

        let title = AppSettings.shared.captureWindowTitles ? getWindowTitle(for: app) : ""
        currentTitle = title

        let isBrowser = knownBrowsers.contains(where: { appName.contains($0) })
        if isBrowser {
            Task.detached(priority: .utility) {
                let url = ActivityTracker.fetchBrowserURL(appName: appName)
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.cachedBrowserURL = url
                    self.lastBrowserTitle = title
                    let cat = self.resolveCategory(appName: appName, bundleID: bundleID, title: title, url: url, isIdle: false)
                    self.checkDistractionAlert(category: cat)
                    self.writeRecord(appName: appName, bundleID: bundleID, title: title, url: url, category: cat, isIdle: false, duration: 0)
                    self.lastSavedBundleID = bundleID; self.lastSavedTitle = title
                    self.lastSavedURL = url; self.lastSavedIsIdle = false
                }
            }
        } else {
            let cat = resolveCategory(appName: appName, bundleID: bundleID, title: title, url: nil, isIdle: false)
            checkDistractionAlert(category: cat)
            writeRecord(appName: appName, bundleID: bundleID, title: title, url: nil, category: cat, isIdle: false, duration: 0)
            lastSavedBundleID = bundleID; lastSavedTitle = title
            lastSavedURL = nil; lastSavedIsIdle = false
        }
    }

    // MARK: - Screen Sleep / Wake

    private func handleScreenSleep() {
        isScreenAsleep = true
        heartbeatTimer?.invalidate(); heartbeatTimer = nil
        lastSavedBundleID = "" // force fresh write on wake
        trackerLogger.info("Screen/system sleep — tracking paused")
    }

    private func handleScreenWake() {
        isScreenAsleep = false
        scheduleHeartbeat()
        captureCurrentApp()
        trackerLogger.info("Screen/system wake — tracking resumed")
    }

    // MARK: - Initial capture

    private func captureCurrentApp() {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else { return }
        let appName = frontApp.localizedName ?? "Unknown"
        let bundleID = frontApp.bundleIdentifier ?? ""
        guard !AppSettings.shared.excludedBundleIDs.contains(bundleID) else { return }
        currentApp = appName
        currentTitle = AppSettings.shared.captureWindowTitles ? getWindowTitle(for: frontApp) : ""
        lastSavedBundleID = "" // will be set after first write
    }

    // MARK: - Helpers

    private func resolveCategory(appName: String, bundleID: String, title: String, url: String?, isIdle: Bool) -> Category {
        if isIdle { return .idle }
        return RuleEngine.shared.categorize(appName: appName, bundleID: bundleID, windowTitle: title, url: url) ?? .uncategorized
    }

    private func writeRecord(appName: String, bundleID: String, title: String, url: String?, category: Category, isIdle: Bool, duration: TimeInterval) {
        let record = ActivityRecord(
            timestamp: Date(), appName: appName, bundleID: bundleID,
            windowTitle: title, url: url, category: category,
            isIdle: isIdle, duration: duration
        )
        Task(priority: .utility) {
            try? await Database.shared.saveActivity(record)
        }
    }

    private func resetSwitchCountIfNewDay() {
        let today = Calendar.current.startOfDay(for: Date())
        if today > lastSwitchResetDate {
            todaySwitchCount = 0
            lastSwitchResetDate = today
        }
    }

    private func scheduleBatteryMonitor() {
        batteryMonitorTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let newBattery = self.isOnBattery()
                if newBattery != self.cachedOnBattery {
                    self.cachedOnBattery = newBattery
                    self.scheduleHeartbeat() // re-schedule with new interval
                }
            }
        }
    }

    private func getWindowTitle(for app: NSRunningApplication) -> String {
        let pid = app.processIdentifier
        let appElement = AXUIElementCreateApplication(pid)
        var value: AnyObject?
        let result = AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &value)
        guard result == .success, let rawValue = value else { return "" }
        let axElement = rawValue as! AXUIElement
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
        guard alertMinutes > 0 else { distractionStartTime = nil; return }

        if category == .distraction || category == .entertainment {
            if distractionStartTime == nil { distractionStartTime = Date() }
            let elapsed = Date().timeIntervalSince(distractionStartTime!)
            let threshold = TimeInterval(alertMinutes * 60)
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
