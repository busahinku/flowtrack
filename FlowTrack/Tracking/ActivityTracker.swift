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
    private var powerSourceCallback: CFRunLoopSource?
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
    private var lastSavedAppName: String = ""
    private var lastSavedCategory: Category = .uncategorized

    // Accurate duration tracking — time of last DB write per bundleID
    private var lastWriteDate: Date = Date()

    // AX title fetch optimization — skip when app hasn't changed
    private var lastFrontmostPID: pid_t = 0
    private var lastTitleFetchDate: Date = .distantPast

    // Browser URL cache — only re-fetch AppleScript when title actually changes
    private var lastBrowserTitle: String = ""
    private var cachedBrowserURL: String? = nil

    // Browser URL debounce — cancel pending fetch when title changes rapidly
    private var browserURLTask: Task<Void, Never>?

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
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            Task { @MainActor [weak self] in self?.handleAppSwitch(app: app) }
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
        if let source = powerSourceCallback {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode)
            powerSourceCallback = nil
        }
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
        let interval: TimeInterval = cachedOnBattery ? 30 : 15
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            Task { @MainActor [weak self] in self?.heartbeat() }
        }
        heartbeatTimer?.tolerance = interval * 0.1  // allow 10% coalescing to save energy
    }

    private func heartbeat() {
        guard !isScreenAsleep else { return }
        guard let frontApp = NSWorkspace.shared.frontmostApplication else { return }
        let appName = frontApp.localizedName ?? "Unknown"
        let bundleID = frontApp.bundleIdentifier ?? ""

        if AppSettings.shared.excludedBundleIDs.contains(bundleID) { return }

        // loginwindow = macOS screen lock/login screen — treat as idle, don't track as activity
        let isSystemIdle = bundleID == "com.apple.loginwindow" || appName.lowercased() == "loginwindow"

        let isIdle = checkIdle()
        if isIdle { consecutiveIdleCount += 1 } else { consecutiveIdleCount = 0; lastActivity = Date() }

        let idleDuration = Date().timeIntervalSince(lastActivity)
        let recordIsIdle = isSystemIdle || idleDuration > idleThreshold

        if recordIsIdle && consecutiveIdleCount > 3 { return }

        // AX title fetch optimization — skip when PID unchanged and title is fresh
        let pid = frontApp.processIdentifier
        let now = Date()
        let pidChanged = pid != lastFrontmostPID
        let titleStale = now.timeIntervalSince(lastTitleFetchDate) >= 5
        let newTitle: String
        if AppSettings.shared.captureWindowTitles && (pidChanged || titleStale) {
            newTitle = getWindowTitle(for: frontApp)
            lastTitleFetchDate = now
            lastFrontmostPID = pid
        } else if AppSettings.shared.captureWindowTitles {
            newTitle = lastSavedTitle // reuse cached
        } else {
            newTitle = ""
        }

        let titleChanged = newTitle != lastSavedTitle
        if titleChanged { currentTitle = newTitle }

        // Actual elapsed time since last write for this app (accurate duration)
        let elapsed = now.timeIntervalSince(lastWriteDate)
        let isBrowser = knownBrowsers.contains(where: { appName.contains($0) })

        if isBrowser {
            let urlChanged = titleChanged || cachedBrowserURL == nil
            if urlChanged {
                // Debounce browser URL fetch — cancel any pending fetch
                browserURLTask?.cancel()
                let capturedTitle = newTitle
                let capturedElapsed = elapsed
                browserURLTask = Task {
                    try? await Task.sleep(for: .seconds(1.5))
                    guard !Task.isCancelled else { return }
                    let url = await ActivityTracker.fetchBrowserURL(appName: appName)
                    guard !Task.isCancelled else { return }
                    self.cachedBrowserURL = url
                    self.lastBrowserTitle = capturedTitle
                    let metadata = ContentMetadataExtractor.extract(url: url, windowTitle: capturedTitle, appName: appName)
                    let cat = self.resolveCategory(appName: appName, bundleID: bundleID, title: capturedTitle, url: url, isIdle: recordIsIdle, contentMetadata: metadata)
                    self.checkDistractionAlert(category: cat)
                    self.writeRecord(appName: appName, bundleID: bundleID, title: capturedTitle, url: url, category: cat, isIdle: recordIsIdle, duration: capturedElapsed, contentMetadata: metadata)
                    self.lastSavedBundleID = bundleID; self.lastSavedTitle = capturedTitle
                    self.lastSavedAppName = appName; self.lastSavedCategory = cat
                    self.lastSavedURL = url; self.lastSavedIsIdle = recordIsIdle
                    self.lastWriteDate = Date()
                }
            } else {
                // Same tab — dedup: only write if ≥60s since last write (liveness pulse)
                guard elapsed >= 60 else { return }
                let metadata = ContentMetadataExtractor.extract(url: cachedBrowserURL, windowTitle: newTitle, appName: appName)
                let cat = resolveCategory(appName: appName, bundleID: bundleID, title: newTitle, url: cachedBrowserURL, isIdle: recordIsIdle, contentMetadata: metadata)
                checkDistractionAlert(category: cat)
                writeRecord(appName: appName, bundleID: bundleID, title: newTitle, url: cachedBrowserURL, category: cat, isIdle: recordIsIdle, duration: elapsed, contentMetadata: metadata)
                lastSavedBundleID = bundleID; lastSavedTitle = newTitle; lastSavedIsIdle = recordIsIdle
                lastSavedAppName = appName; lastSavedCategory = cat
                lastWriteDate = Date()
            }
        } else {
            cachedBrowserURL = nil
            // Dedup: if nothing changed, only write every 60s as a liveness pulse
            let nothingChanged = bundleID == lastSavedBundleID && newTitle == lastSavedTitle && recordIsIdle == lastSavedIsIdle
            if nothingChanged && elapsed < 60 { return }

            let cat = resolveCategory(appName: appName, bundleID: bundleID, title: newTitle, url: nil, isIdle: recordIsIdle)
            checkDistractionAlert(category: cat)
            writeRecord(appName: appName, bundleID: bundleID, title: newTitle, url: nil, category: cat, isIdle: recordIsIdle, duration: elapsed)
            lastSavedBundleID = bundleID; lastSavedTitle = newTitle; lastSavedIsIdle = recordIsIdle
            lastSavedAppName = appName; lastSavedCategory = cat
            lastWriteDate = Date()
        }
    }

    // MARK: - App Switch Handler (event-driven, instant)

    private func handleAppSwitch(app: NSRunningApplication?) {
        guard let app else { return }
        let bundleID = app.bundleIdentifier ?? ""
        let appName = app.localizedName ?? "Unknown"

        if AppSettings.shared.excludedBundleIDs.contains(bundleID) { return }
        guard bundleID != lastSavedBundleID else { return } // same app, skip

        // Cancel any pending browser URL debounce from previous app
        browserURLTask?.cancel()
        browserURLTask = nil

        // Write closing record for the previous app to capture time since last heartbeat
        let now = Date()
        if !lastSavedBundleID.isEmpty && !lastSavedAppName.isEmpty
            && !AppSettings.shared.excludedBundleIDs.contains(lastSavedBundleID) {
            let elapsed = now.timeIntervalSince(lastWriteDate)
            if elapsed > 1.0 {
                writeRecord(appName: lastSavedAppName, bundleID: lastSavedBundleID,
                            title: lastSavedTitle, url: lastSavedURL,
                            category: lastSavedCategory, isIdle: lastSavedIsIdle,
                            duration: elapsed)
            }
        }

        // Track app switches for context-switching metric
        resetSwitchCountIfNewDay()
        todaySwitchCount += 1
        trackerLogger.debug("App switch: \(appName, privacy: .public) (#\(self.todaySwitchCount))")

        currentApp = appName
        consecutiveIdleCount = 0
        cachedBrowserURL = nil
        lastBrowserTitle = ""
        lastWriteDate = now

        let title = AppSettings.shared.captureWindowTitles ? getWindowTitle(for: app) : ""
        currentTitle = title
        lastFrontmostPID = app.processIdentifier
        lastTitleFetchDate = now

        // Update dedup state immediately so heartbeat doesn't double-record
        lastSavedBundleID = bundleID; lastSavedTitle = title
        lastSavedURL = nil; lastSavedIsIdle = false; lastSavedAppName = appName

        let isBrowser = knownBrowsers.contains(where: { appName.contains($0) })
        if isBrowser {
            // Fetch URL async — don't write a record here (duration: 1 < 5s minimum).
            // The next heartbeat writes the first browser record with accurate duration + URL.
            Task.detached(priority: .utility) {
                let url = await ActivityTracker.fetchBrowserURL(appName: appName)
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.cachedBrowserURL = url
                    self.lastBrowserTitle = title
                    let metadata = ContentMetadataExtractor.extract(url: url, windowTitle: title, appName: appName)
                    let cat = self.resolveCategory(appName: appName, bundleID: bundleID, title: title, url: url, isIdle: false, contentMetadata: metadata)
                    self.checkDistractionAlert(category: cat)
                    self.lastSavedURL = url
                    self.lastSavedCategory = cat
                }
            }
        } else {
            // Non-browser: write immediately so the switch is recorded at the right timestamp
            let cat = resolveCategory(appName: appName, bundleID: bundleID, title: title, url: nil, isIdle: false)
            checkDistractionAlert(category: cat)
            writeRecord(appName: appName, bundleID: bundleID, title: title, url: nil, category: cat, isIdle: false, duration: 1)
            lastSavedCategory = cat
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
        lastWriteDate = Date() // don't count sleep time as app duration
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

    private func resolveCategory(appName: String, bundleID: String, title: String, url: String?, isIdle: Bool, contentMetadata: ContentMetadata? = nil) -> Category {
        if isIdle { return .idle }
        return RuleEngine.shared.categorize(appName: appName, bundleID: bundleID, windowTitle: title, url: url, contentMetadata: contentMetadata) ?? .uncategorized
    }

    private func writeRecord(appName: String, bundleID: String, title: String, url: String?, category: Category, isIdle: Bool, duration: TimeInterval, contentMetadata: ContentMetadata? = nil) {
        guard duration >= 5 || isIdle else { return }  // capture all activity ≥5s for AI window analysis
        let metadataJSON: String?
        if let metadata = contentMetadata, let data = try? JSONEncoder().encode(metadata) {
            metadataJSON = String(data: data, encoding: .utf8)
        } else {
            metadataJSON = nil
        }
        let record = ActivityRecord(
            timestamp: Date(), appName: appName, bundleID: bundleID,
            windowTitle: title, url: url, category: category,
            isIdle: isIdle, duration: duration, contentMetadata: metadataJSON
        )
        Task(priority: .utility) {
            do {
                try Database.shared.saveActivity(record)
            } catch {
                trackerLogger.error("DB write failed: \(error.localizedDescription, privacy: .public)")
            }
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
        // Use IOKit notification instead of polling — fires only when power source changes
        let context = Unmanaged.passUnretained(self).toOpaque()
        if let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let tracker = Unmanaged<ActivityTracker>.fromOpaque(context).takeUnretainedValue()
            Task { @MainActor in
                let newBattery = tracker.isOnBattery()
                if newBattery != tracker.cachedOnBattery {
                    tracker.cachedOnBattery = newBattery
                    tracker.scheduleHeartbeat()
                }
            }
        }, context)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
            powerSourceCallback = source
        }
    }

    private func getWindowTitle(for app: NSRunningApplication) -> String {
        let pid = app.processIdentifier
        let appElement = AXUIElementCreateApplication(pid)
        var value: AnyObject?
        let result = AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &value)
        if result != .success {
            // .cannotComplete is normal during app transitions — only log other failures
            if result != .cannotComplete {
                trackerLogger.debug("AX focused window failed for PID \(pid): \(result.rawValue)")
            }
            return ""
        }
        guard let rawValue = value else { return "" }
        // CoreFoundation bridging: AXUIElement is always an AXUIElement when result == .success
        let axElement = rawValue as! AXUIElement
        var titleValue: AnyObject?
        let titleResult = AXUIElementCopyAttributeValue(axElement, kAXTitleAttribute as CFString, &titleValue)
        if titleResult != .success && titleResult != .cannotComplete {
            trackerLogger.debug("AX title fetch failed for PID \(pid): \(titleResult.rawValue)")
        }
        return titleValue as? String ?? ""
    }

    /// Runs AppleScript to get the active browser tab URL.
    /// Firefox uses AXUIElement instead (no AppleScript support for URL).
    /// Async — suspends the calling task without blocking any thread pool thread.
    nonisolated static func fetchBrowserURL(appName: String) async -> String? {
        // Firefox doesn't expose URL via AppleScript — use AXUIElement address bar
        if appName.contains("Firefox") {
            return fetchFirefoxURL()
        }

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
        } else {
            return nil
        }

        // Use withCheckedContinuation so the calling async task suspends (not blocks a thread).
        // Two GCD dispatches race: the actual AppleScript and a 3-second timeout.
        // A one-shot flag guarantees the continuation is resumed exactly once.
        return await withCheckedContinuation { continuation in
            let once = _Once()
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3) {
                if once.fulfill() {
                    trackerLogger.warning("AppleScript timed out for \(appName, privacy: .public)")
                    continuation.resume(returning: nil)
                }
            }
            DispatchQueue.global(qos: .utility).async {
                let appleScript = NSAppleScript(source: script)
                var error: NSDictionary?
                let output = appleScript?.executeAndReturnError(&error)
                if once.fulfill() {
                    continuation.resume(returning: output?.stringValue)
                }
            }
        }
    }

    /// Reads Firefox URL from the AXUIElement address bar (toolbar item with URL role).
    /// Firefox doesn't support AppleScript URL access, so we use Accessibility API.
    nonisolated private static func fetchFirefoxURL() -> String? {
        guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "org.mozilla.firefox" }) else { return nil }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        var windowRef: AnyObject?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &windowRef) == .success else { return nil }
        let window = windowRef as! AXUIElement
        // Traverse toolbar → address bar (search field with URL value)
        if let url = searchAXForURL(element: window, depth: 0) {
            return url
        }
        return nil
    }

    nonisolated private static func searchAXForURL(element: AXUIElement, depth: Int) -> String? {
        guard depth < 8 else { return nil }
        var roleRef: AnyObject?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
        let role = roleRef as? String ?? ""

        // Check if this element looks like an address bar (text field with a URL value)
        if role == kAXTextFieldRole || role == "AXComboBox" {
            var valueRef: AnyObject?
            AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueRef)
            if let value = valueRef as? String,
               (value.hasPrefix("http://") || value.hasPrefix("https://") || value.hasPrefix("about:")) {
                return value
            }
        }

        // Recurse into children
        var childrenRef: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement] else { return nil }
        for child in children {
            if let found = searchAXForURL(element: child, depth: depth + 1) { return found }
        }
        return nil
    }

    private func checkIdle() -> Bool {
        let idleTime = CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: .mouseMoved)
        let keyIdle = CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: .keyDown)
        // Use a fraction of the user's idle threshold for early detection
        // (recordIsIdle still uses the full idleThreshold for the actual idle decision)
        let earlyDetectThreshold = min(30, idleThreshold / 2)
        return min(idleTime, keyIdle) > earlyDetectThreshold
    }

    private func isOnBattery() -> Bool {
        let snapshot = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let type = IOPSGetProvidingPowerSourceType(snapshot).takeRetainedValue() as String
        return type == kIOPSBatteryPowerValue
    }

    private func checkDistractionAlert(category: Category) {
        let alertMinutes = AppSettings.shared.distractionAlertMinutes
        guard alertMinutes > 0 else { distractionStartTime = nil; return }

        if category == .distraction {
            if distractionStartTime == nil { distractionStartTime = Date() }
            guard let start = distractionStartTime else { return }
            let elapsed = Date().timeIntervalSince(start)
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

// MARK: - _Once (file-level to avoid @MainActor isolation from outer class)
/// Thread-safe one-shot flag — ensures a continuation is resumed exactly once.
private final class _Once: @unchecked Sendable {
    nonisolated init() {}
    private let lock = NSLock()
    private var done = false
    /// Returns true the first time called; false on all subsequent calls.
    func fulfill() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !done else { return false }
        done = true; return true
    }
}
