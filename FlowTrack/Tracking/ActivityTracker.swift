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
    private var heartbeatTimer: Timer?  // kept for legacy compatibility; use idleTimer instead
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
    private var browserFetchTask: Task<Void, Never>?

    // Browser URL debounce — cancel pending fetch when title changes rapidly
    private var browserURLTask: Task<Void, Never>?

    // Browser URL race guard — prevents checkpoint/segment writes while initial URL fetch is in-flight
    private var isBrowserFetchPending: Bool = false
    // Generation counter — prevents stale browser fetch results from overwriting newer state
    private var browserFetchGeneration: UInt64 = 0

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
    private var distractionPausedAt: Date?
    private var lastDistractionAlertFired: Date?

    private let knownBrowsers = ["Safari", "Google Chrome", "Firefox", "Arc", "Brave Browser", "Microsoft Edge", "Opera"]

    // MARK: - Segment Tracking State
    /// When the current focus segment started — used as timestamp for the segment's DB record
    private var currentSegmentStart: Date = Date()
    /// Idle timer — lightweight 30s check of CGEventSource only (no AX calls, no AppleScript)
    private var idleTimer: Timer?
    /// Checkpoint timer — writes partial segment every 5 min for crash recovery
    private var checkpointTimer: Timer?
    /// Whether we are currently in an idle period (no user input)
    private var isCurrentlyIdle: Bool = false
    /// Last checkpoint write time — used to make checkpoints incremental (not cumulative)
    private var lastCheckpointDate: Date?

    // Title change debounce — prevents micro-segments from rapid title changes
    private var titleChangeDebounceTask: Task<Void, Never>?

    // MARK: - AXObserver State (event-driven title change detection)
    private var axObserver: AXObserver?
    private var axObserverContext: UnsafeMutableRawPointer?
    private var observedPID: pid_t = 0

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

        scheduleIdleTimer()
        scheduleCheckpointTimer()
        scheduleBatteryMonitor()
        captureCurrentApp()
        Database.shared.autoCleanupIfNeeded()
    }

    func stopTracking() {
        isTracking = false
        idleTimer?.invalidate(); idleTimer = nil
        checkpointTimer?.invalidate(); checkpointTimer = nil
        unregisterAXObserver()
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

    // MARK: - Idle Timer (replaces heartbeat — 30s, only checks CGEventSource, zero AX overhead)

    private func scheduleIdleTimer() {
        idleTimer?.invalidate()
        // 30s interval with 20% tolerance for OS timer coalescing (saves energy)
        idleTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            Task { @MainActor [weak self] in self?.idleTimerFired() }
        }
        idleTimer?.tolerance = 6
    }

    private func idleTimerFired() {
        guard isTracking, !isScreenAsleep else { return }
        let idleSecs = min(
            CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: .mouseMoved),
            CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: .keyDown)
        )
        let nowIdle = idleSecs > idleThreshold

        if nowIdle && !isCurrentlyIdle {
            // Transition: active → idle. End the current active segment.
            isCurrentlyIdle = true
            endCurrentSegment(forceIdle: false)
            trackerLogger.debug("Idle detected after \(Int(idleSecs))s — segment closed")
        } else if !nowIdle && isCurrentlyIdle {
            // Transition: idle → active. Start fresh segment.
            isCurrentlyIdle = false
            currentSegmentStart = Date()
            lastCheckpointDate = nil
            trackerLogger.debug("Activity resumed — new segment started")
        }
        // Update lastActivity for distraction alert timing
        if !nowIdle { lastActivity = Date() }
    }

    // MARK: - Checkpoint Timer (5-min crash recovery writes for long sessions)

    private func scheduleCheckpointTimer() {
        checkpointTimer?.invalidate()
        checkpointTimer = Timer.scheduledTimer(withTimeInterval: 5 * 60, repeats: true) { _ in
            Task { @MainActor [weak self] in self?.writeCheckpoint() }
        }
        checkpointTimer?.tolerance = 30
    }

    /// Write a partial record every 5 minutes for the in-progress segment.
    /// Each checkpoint writes only the time since the last checkpoint (incremental),
    /// then advances currentSegmentStart to avoid double-counting.
    private func writeCheckpoint() {
        guard isTracking, !isScreenAsleep, !isCurrentlyIdle, !isBrowserFetchPending else { return }
        guard !lastSavedBundleID.isEmpty else { return }
        let now = Date()
        let checkpointBase = lastCheckpointDate ?? currentSegmentStart
        let elapsed = now.timeIntervalSince(checkpointBase)
        guard elapsed >= 60 else { return }  // Don't checkpoint very short segments
        writeRecord(appName: lastSavedAppName, bundleID: lastSavedBundleID,
                    title: lastSavedTitle, url: lastSavedURL,
                    category: lastSavedCategory, isIdle: false,
                    duration: elapsed, segmentStart: checkpointBase)
        // Advance segment start so next checkpoint/endSegment only writes incremental time
        currentSegmentStart = now
        lastCheckpointDate = now
        trackerLogger.debug("Checkpoint write for \(self.lastSavedAppName, privacy: .public) (\(Int(elapsed))s)")
    }

    // MARK: - Segment Management

    /// End the current focus segment and write one accurate DB record.
    /// Called on: app switch, AX title change, idle, screen sleep.
    private func endCurrentSegment(forceIdle: Bool = false) {
        let now = Date()
        let elapsed = now.timeIntervalSince(currentSegmentStart)
        guard elapsed >= 5 else { return }  // Ignore sub-5s micro-segments
        guard !lastSavedBundleID.isEmpty, !lastSavedAppName.isEmpty else { return }
        guard !AppSettings.shared.excludedBundleIDs.contains(lastSavedBundleID) else { return }

        writeRecord(appName: lastSavedAppName, bundleID: lastSavedBundleID,
                    title: lastSavedTitle, url: lastSavedURL,
                    category: forceIdle ? .idle : lastSavedCategory,
                    isIdle: forceIdle || lastSavedIsIdle,
                    duration: elapsed, segmentStart: currentSegmentStart)
        // Advance start and clear checkpoint so no double-counting if checkpoint fires before caller sets new start
        currentSegmentStart = now
        lastCheckpointDate = nil
    }

    // MARK: - App Switch Handler (event-driven, instant)

    private func handleAppSwitch(app: NSRunningApplication?) {
        guard let app else { return }
        let bundleID = app.bundleIdentifier ?? ""
        let appName = app.localizedName ?? "Unknown"

        // loginwindow = macOS screen lock — treat as idle, never record as activity
        guard bundleID != "com.apple.loginwindow" && appName.lowercased() != "loginwindow" else { return }
        if AppSettings.shared.excludedBundleIDs.contains(bundleID) { return }
        guard bundleID != lastSavedBundleID else { return } // same app, skip

        // Cancel any pending browser URL debounce from previous app
        browserURLTask?.cancel()
        browserURLTask = nil
        isBrowserFetchPending = false
        titleChangeDebounceTask?.cancel()
        titleChangeDebounceTask = nil

        // End the previous app's segment — write one accurate record
        endCurrentSegment()

        // Track app switches for context-switching metric
        resetSwitchCountIfNewDay()
        todaySwitchCount += 1
        trackerLogger.debug("App switch → \(appName, privacy: .public) (#\(self.todaySwitchCount))")

        // Start new segment
        let now = Date()
        currentSegmentStart = now
        lastCheckpointDate = nil
        isCurrentlyIdle = false
        currentApp = appName
        consecutiveIdleCount = 0
        cachedBrowserURL = nil
        lastBrowserTitle = ""
        lastWriteDate = now

        let title = AppSettings.shared.captureWindowTitles ? getWindowTitle(for: app) : ""
        currentTitle = title
        lastFrontmostPID = app.processIdentifier
        lastTitleFetchDate = now

        // Register AXObserver on new app for instant title change detection
        registerAXTitleObserver(for: app)

        // Update dedup state immediately so checkpoint doesn't double-record
        lastSavedBundleID = bundleID; lastSavedTitle = title
        lastSavedURL = nil; lastSavedIsIdle = false; lastSavedAppName = appName

        let isBrowser = knownBrowsers.contains(where: { appName.contains($0) })
        if isBrowser {
            // Cancel any in-flight fetch from a prior browser switch, then start a fresh one
            browserFetchTask?.cancel()
            isBrowserFetchPending = true
            browserFetchGeneration &+= 1
            let fetchGen = browserFetchGeneration
            browserFetchTask = Task.detached(priority: .utility) {
                let info = await ActivityTracker.fetchBrowserInfo(appName: appName)
                await MainActor.run { [weak self] in
                    guard let self, self.browserFetchGeneration == fetchGen else { return }
                    self.isBrowserFetchPending = false
                    self.cachedBrowserURL = info.url
                    self.lastBrowserTitle = title
                    // Use AppleScript page title if AX title was empty (page was loading)
                    let resolvedTitle = info.pageTitle.flatMap { $0.isEmpty ? nil : $0 } ?? title
                    if self.lastSavedTitle == title || self.lastSavedTitle.isEmpty {
                        self.currentTitle = resolvedTitle
                        self.lastSavedTitle = resolvedTitle
                    }
                    let metadata = ContentMetadataExtractor.extract(url: info.url, windowTitle: resolvedTitle, appName: appName)
                    let cat = self.resolveCategory(appName: appName, bundleID: bundleID, title: resolvedTitle, url: info.url, isIdle: false, contentMetadata: metadata)
                    self.checkDistractionAlert(category: cat)
                    FocusModeEngine.shared.checkActivity(category: cat, appName: appName, windowTitle: resolvedTitle, url: info.url)
                    self.lastSavedCategory = cat
                }
            }
        } else {
            let cat = resolveCategory(appName: appName, bundleID: bundleID, title: title, url: nil, isIdle: false)
            checkDistractionAlert(category: cat)
            FocusModeEngine.shared.checkActivity(category: cat, appName: appName, windowTitle: title)
            lastSavedCategory = cat
        }
    }

    // MARK: - Screen Sleep / Wake

    private func handleScreenSleep() {
        isScreenAsleep = true
        isBrowserFetchPending = false
        idleTimer?.invalidate(); idleTimer = nil
        checkpointTimer?.invalidate(); checkpointTimer = nil
        unregisterAXObserver()
        // End current segment cleanly before sleep
        endCurrentSegment()
        lastSavedBundleID = "" // force fresh write on wake
        trackerLogger.info("Screen/system sleep — segment closed, tracking paused")
    }

    private func handleScreenWake() {
        isScreenAsleep = false
        isCurrentlyIdle = false
        currentSegmentStart = Date() // don't count sleep time in next segment
        lastCheckpointDate = nil
        lastWriteDate = Date()
        scheduleIdleTimer()
        scheduleCheckpointTimer()
        captureCurrentApp()
        trackerLogger.info("Screen/system wake — tracking resumed")
    }

    // MARK: - Initial capture

    private func captureCurrentApp() {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else { return }
        let appName = frontApp.localizedName ?? "Unknown"
        let bundleID = frontApp.bundleIdentifier ?? ""
        guard !AppSettings.shared.excludedBundleIDs.contains(bundleID) else { return }
        guard bundleID != "com.apple.loginwindow" else { return }
        currentApp = appName
        let title = AppSettings.shared.captureWindowTitles ? getWindowTitle(for: frontApp) : ""
        currentTitle = title
        lastSavedBundleID = bundleID
        lastSavedAppName = appName
        lastSavedTitle = title
        currentSegmentStart = Date()
        lastCheckpointDate = nil
        lastWriteDate = Date()
        lastFrontmostPID = frontApp.processIdentifier
        // Register AXObserver for current frontmost app
        registerAXTitleObserver(for: frontApp)
        let cat = resolveCategory(appName: appName, bundleID: bundleID, title: title, url: nil, isIdle: false)
        lastSavedCategory = cat
    }

    // MARK: - AXObserver (event-driven window title change detection)

    private func registerAXTitleObserver(for app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard pid != observedPID else { return }
        unregisterAXObserver()

        var observer: AXObserver?
        // Use unretained since ActivityTracker is a singleton that outlives any observer
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        // Literal non-capturing closure is required for @convention(c) C function pointer
        let err = AXObserverCreate(pid, { _, _, _, userData in
            guard let userData else { return }
            let tracker = Unmanaged<ActivityTracker>.fromOpaque(userData).takeUnretainedValue()
            Task { @MainActor in tracker.handleAXTitleChange() }
        }, &observer)
        guard err == .success, let obs = observer else { return }

        let element = AXUIElementCreateApplication(pid)
        AXObserverAddNotification(obs, element, kAXTitleChangedNotification as CFString, selfPtr)
        AXObserverAddNotification(obs, element, kAXFocusedWindowChangedNotification as CFString, selfPtr)
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)

        axObserver = obs
        axObserverContext = selfPtr
        observedPID = pid
        trackerLogger.debug("AXObserver registered for PID \(pid)")
    }

    private func unregisterAXObserver() {
        if let obs = axObserver {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
        }
        axObserver = nil
        axObserverContext = nil
        observedPID = 0
    }

    /// Called by the AXObserver C callback when window title changes within the same app.
    /// This handles: browser tab switches, file opens in Xcode, document navigation, etc.
    /// Debounces for 2s to avoid micro-segments from rapid title changes (loading states, autosave, etc.).
    func handleAXTitleChange() {
        guard isTracking, !isScreenAsleep, !isCurrentlyIdle else { return }
        guard let frontApp = NSWorkspace.shared.frontmostApplication else { return }

        let newTitle = AppSettings.shared.captureWindowTitles ? getWindowTitle(for: frontApp) : ""
        guard newTitle != lastSavedTitle && !newTitle.isEmpty else { return }

        let appName = frontApp.localizedName ?? "Unknown"
        let bundleID = frontApp.bundleIdentifier ?? ""
        guard !AppSettings.shared.excludedBundleIDs.contains(bundleID) else { return }

        trackerLogger.debug("AX title change: \"\(newTitle.prefix(60), privacy: .private)\"")

        // If the previous title was empty (page was loading when segment started),
        // update title in-place without ending the segment — avoids recording a blank-title record.
        if lastSavedTitle.isEmpty {
            currentTitle = newTitle
            lastSavedTitle = newTitle
            updateBrowserInfo(appName: appName, bundleID: bundleID, title: newTitle)
            return
        }

        // Update UI immediately for responsiveness, but defer the segment split
        currentTitle = newTitle

        // Debounce: cancel any pending title change, wait 2s before splitting
        titleChangeDebounceTask?.cancel()
        titleChangeDebounceTask = Task {
            try? await Task.sleep(for: .seconds(2.0))
            guard !Task.isCancelled else { return }

            // After debounce: if segment is very short (< 15s), update title in-place
            let segmentAge = Date().timeIntervalSince(self.currentSegmentStart)
            if segmentAge < 15 {
                self.lastSavedTitle = newTitle
                self.lastSavedURL = nil
                self.cachedBrowserURL = nil
                self.updateBrowserInfo(appName: appName, bundleID: bundleID, title: newTitle)
                return
            }

            // Segment is long enough — end it and start a new one
            self.endCurrentSegment()
            self.currentSegmentStart = Date()
            self.lastCheckpointDate = nil

            self.lastSavedTitle = newTitle
            self.lastSavedURL = nil
            self.cachedBrowserURL = nil
            self.updateBrowserInfo(appName: appName, bundleID: bundleID, title: newTitle)
        }
    }

    /// Fetch browser URL and update category for a title change. Shared by handleAXTitleChange paths.
    private func updateBrowserInfo(appName: String, bundleID: String, title: String) {
        let isBrowser = knownBrowsers.contains(where: { appName.contains($0) })
        if isBrowser {
            browserURLTask?.cancel()
            let capturedTitle = title
            browserURLTask = Task {
                // Small debounce to avoid AppleScript on rapid tab switches
                try? await Task.sleep(for: .seconds(1.0))
                guard !Task.isCancelled else { return }
                let info = await ActivityTracker.fetchBrowserInfo(appName: appName)
                guard !Task.isCancelled else { return }
                // Use AppleScript page title if AX title was empty or just got replaced
                let resolvedTitle = info.pageTitle.flatMap { $0.isEmpty ? nil : $0 } ?? capturedTitle
                self.cachedBrowserURL = info.url
                self.lastSavedURL = info.url
                if self.lastSavedTitle == capturedTitle {
                    self.currentTitle = resolvedTitle
                    self.lastSavedTitle = resolvedTitle
                }
                let metadata = ContentMetadataExtractor.extract(url: info.url, windowTitle: resolvedTitle, appName: appName)
                let cat = self.resolveCategory(appName: appName, bundleID: bundleID, title: resolvedTitle, url: info.url, isIdle: false, contentMetadata: metadata)
                self.checkDistractionAlert(category: cat)
                FocusModeEngine.shared.checkActivity(category: cat, appName: appName, windowTitle: resolvedTitle, url: info.url)
                self.lastSavedCategory = cat
            }
        } else {
            let cat = resolveCategory(appName: appName, bundleID: bundleID, title: title, url: nil, isIdle: false)
            checkDistractionAlert(category: cat)
            FocusModeEngine.shared.checkActivity(category: cat, appName: appName, windowTitle: title)
            lastSavedCategory = cat
        }
    }

    // MARK: - Helpers

    private func resolveCategory(appName: String, bundleID: String, title: String, url: String?, isIdle: Bool, contentMetadata: ContentMetadata? = nil) -> Category {
        if isIdle { return .idle }
        return RuleEngine.shared.categorize(appName: appName, bundleID: bundleID, windowTitle: title, url: url, contentMetadata: contentMetadata) ?? .uncategorized
    }

    private func writeRecord(appName: String, bundleID: String, title: String, url: String?, category: Category, isIdle: Bool, duration: TimeInterval, segmentStart: Date? = nil, contentMetadata: ContentMetadata? = nil) {
        guard duration >= 5 || isIdle else { return }

        // Resolve contentMetadata if not provided
        let resolvedMetadata: ContentMetadata?
        if let m = contentMetadata {
            resolvedMetadata = m
        } else if let url = url {
            resolvedMetadata = ContentMetadataExtractor.extract(url: url, windowTitle: title, appName: appName)
        } else if !title.isEmpty {
            resolvedMetadata = ContentMetadataExtractor.extractNativeApp(windowTitle: title, appName: appName, bundleID: bundleID)
        } else {
            resolvedMetadata = nil
        }

        let metadataJSON: String?
        if let metadata = resolvedMetadata, let data = try? JSONEncoder().encode(metadata) {
            metadataJSON = String(data: data, encoding: .utf8)
        } else {
            metadataJSON = nil
        }
        let record = ActivityRecord(
            // Use segmentStart as timestamp so the record lands in the correct 30-min window.
            // Previously used Date() (write time = end of segment), which placed long sessions
            // in the wrong window bucket.
            timestamp: segmentStart ?? Date(),
            appName: appName, bundleID: bundleID,
            windowTitle: title, url: url, category: category,
            isIdle: isIdle, duration: duration, contentMetadata: metadataJSON
        )
        Task(priority: .utility) {
            let maxRetries = 3
            let baseDelay: UInt64 = 100_000_000  // 100ms in nanoseconds
            for attempt in 0..<maxRetries {
                do {
                    try Database.shared.saveActivity(record)
                    return
                } catch {
                    if attempt < maxRetries - 1 {
                        let delay = baseDelay * UInt64(1 << attempt)  // 100ms, 200ms, 400ms
                        trackerLogger.warning("DB write retry \(attempt + 1)/\(maxRetries): \(error.localizedDescription, privacy: .public)")
                        try? await Task.sleep(nanoseconds: delay)
                    } else {
                        trackerLogger.error("DB write failed after \(maxRetries) attempts: \(error.localizedDescription, privacy: .public)")
                    }
                }
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
                tracker.cachedOnBattery = tracker.isOnBattery()
                // Battery state changed — idle timer interval is not power-dependent in the new
                // segment model (idle check is always 30s), so no rescheduling needed.
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
        guard let rawValue = value,
              CFGetTypeID(rawValue as CFTypeRef) == AXUIElementGetTypeID() else { return "" }
        let axElement = rawValue as! AXUIElement
        var titleValue: AnyObject?
        let titleResult = AXUIElementCopyAttributeValue(axElement, kAXTitleAttribute as CFString, &titleValue)
        if titleResult != .success && titleResult != .cannotComplete {
            trackerLogger.debug("AX title fetch failed for PID \(pid): \(titleResult.rawValue)")
        }
        return titleValue as? String ?? ""
    }

    /// Fetches both the URL and page title for the active browser tab.
    /// Returns (url, pageTitle) — Firefox only returns url (no AppleScript access).
    nonisolated static func fetchBrowserInfo(appName: String) async -> (url: String?, pageTitle: String?) {
        if appName.contains("Firefox") {
            return (fetchFirefoxURL(), nil)
        }

        // AppleScript that returns "url|||title" in a single call to avoid two round-trips.
        let script: String
        if appName.contains("Safari") {
            script = """
            tell application "Safari"
                set t to current tab of front window
                return (URL of t) & "|||" & (name of t)
            end tell
            """
        } else if appName.contains("Chrome") {
            script = """
            tell application "Google Chrome"
                set t to active tab of front window
                return (URL of t) & "|||" & (title of t)
            end tell
            """
        } else if appName.contains("Brave") {
            script = """
            tell application "Brave Browser"
                set t to active tab of front window
                return (URL of t) & "|||" & (title of t)
            end tell
            """
        } else if appName.contains("Edge") {
            script = """
            tell application "Microsoft Edge"
                set t to active tab of front window
                return (URL of t) & "|||" & (title of t)
            end tell
            """
        } else if appName.contains("Opera") {
            script = """
            tell application "Opera"
                set t to active tab of front window
                return (URL of t) & "|||" & (title of t)
            end tell
            """
        } else if appName.contains("Arc") {
            script = """
            tell application "Arc"
                set t to active tab of front window
                return (URL of t) & "|||" & (title of t)
            end tell
            """
        } else {
            return (nil, nil)
        }

        return await withCheckedContinuation { continuation in
            let once = _Once()
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3) {
                if once.fulfill() {
                    trackerLogger.warning("AppleScript timed out for \(appName, privacy: .public)")
                    continuation.resume(returning: (nil, nil))
                }
            }
            DispatchQueue.global(qos: .utility).async {
                let appleScript = NSAppleScript(source: script)
                var error: NSDictionary?
                let output = appleScript?.executeAndReturnError(&error)
                if once.fulfill() {
                    guard let raw = output?.stringValue else {
                        continuation.resume(returning: (nil, nil)); return
                    }
                    let parts = raw.components(separatedBy: "|||")
                    let url   = parts.count > 0 ? parts[0].trimmingCharacters(in: .whitespaces) : nil
                    let title = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : nil
                    continuation.resume(returning: (url?.isEmpty == true ? nil : url,
                                                    title?.isEmpty == true ? nil : title))
                }
            }
        }
    }

    /// Legacy wrapper — used by code that only needs the URL.
    nonisolated static func fetchBrowserURL(appName: String) async -> String? {
        await fetchBrowserInfo(appName: appName).url
    }

    /// Reads Firefox URL from the AXUIElement address bar (toolbar item with URL role).
    /// Firefox doesn't support AppleScript URL access, so we use Accessibility API.
    nonisolated private static func fetchFirefoxURL() -> String? {
        guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "org.mozilla.firefox" }) else { return nil }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        var windowRef: AnyObject?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &windowRef) == .success,
              let windowRef, CFGetTypeID(windowRef as CFTypeRef) == AXUIElementGetTypeID() else { return nil }
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

        // Recurse into children — CF bridging returns [AnyObject], not [AXUIElement] directly
        var childrenRef: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let childArray = childrenRef as? [AnyObject] else { return nil }
        let axTypeID = AXUIElementGetTypeID()
        for child in childArray {
            guard CFGetTypeID(child as CFTypeRef) == axTypeID else { continue }
            let axChild = child as! AXUIElement
            if let found = searchAXForURL(element: axChild, depth: depth + 1) { return found }
        }
        return nil
    }

    private func checkIdle() -> Bool {
        let idleTime = CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: .mouseMoved)
        let keyIdle = CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: .keyDown)
        return min(idleTime, keyIdle) > idleThreshold
    }

    private func isOnBattery() -> Bool {
        let snapshot = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let type = IOPSGetProvidingPowerSourceType(snapshot).takeRetainedValue() as String
        return type == kIOPSBatteryPowerValue
    }

    private func checkDistractionAlert(category: Category) {
        let alertMinutes = AppSettings.shared.distractionAlertMinutes
        guard alertMinutes > 0 else { distractionStartTime = nil; distractionPausedAt = nil; return }

        if category == .distraction {
            if let paused = distractionPausedAt {
                // Returning to distraction after a break
                if Date().timeIntervalSince(paused) > 60 {
                    // Break was long enough — reset timer
                    distractionStartTime = Date()
                }
                // else: brief break — keep original start time
                distractionPausedAt = nil
            } else if distractionStartTime == nil {
                distractionStartTime = Date()
            }
            guard let start = distractionStartTime else { return }
            let elapsed = Date().timeIntervalSince(start)
            let threshold = TimeInterval(alertMinutes * 60)
            let canFire = lastDistractionAlertFired.map { Date().timeIntervalSince($0) > threshold } ?? true
            if elapsed >= threshold && canFire {
                lastDistractionAlertFired = Date()
                fireDistractionNotification(minutes: alertMinutes)
            }
        } else {
            // Switched away from distraction — start grace period instead of resetting immediately
            if distractionStartTime != nil && distractionPausedAt == nil {
                distractionPausedAt = Date()
            }
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
