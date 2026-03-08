import Foundation
import AppKit
import UserNotifications
import OSLog

private nonisolated let focusLog = Logger(subsystem: "com.flowtrack", category: "FocusMode")

// MARK: - FocusModeEngine

/// Real-time focus enforcement.
///
/// When Focus Mode is active, `checkActivity` is called after every category resolution.
/// If a distraction persists beyond the grace period, an intervention fires:
/// the current browser tab is **redirected** to the motivation video (not a new tab).
///
/// Grace escalation: first offense uses 3 s, repeat offenses within 60 s use 1 s.
/// Cooldown between interventions: 10 s.
/// After each intervention `distractionSince` is set to a fresh `Date()` (not nil),
/// so the next `checkActivity` call (~5 s later) already has 5 s elapsed and can
/// immediately re-intervene if the user is still on a distraction page.
@MainActor @Observable
final class FocusModeEngine {
    static let shared = FocusModeEngine()

    // MARK: - Public State

    private(set) var isActive: Bool = false
    private(set) var startedAt: Date? = nil
    /// How many interventions have fired in the current session.
    private(set) var interventionCount: Int = 0

    var sessionDuration: TimeInterval {
        startedAt.map { Date().timeIntervalSince($0) } ?? 0
    }

    // MARK: - Configuration

    /// Seconds of continuous distraction before first intervention fires.
    private let gracePeriod: TimeInterval = 2
    /// Shorter grace for repeat offenses (intervention fired within `repeatWindow`).
    private let repeatGracePeriod: TimeInterval = 0.5
    /// Window in which a previous intervention counts as "repeat".
    private let repeatWindow: TimeInterval = 120
    /// Minimum seconds between consecutive interventions.
    private let cooldown: TimeInterval = 4
    /// The motivation video — redirected into the current tab (replaces distraction page).
    private let motivationURL = URL(string: "https://www.youtube.com/watch?v=zSkFFW--Ma0")!

    // MARK: - Internal State

    private var distractionSince: Date? = nil
    private var lastInterventionAt: Date? = nil
    private var pendingInterventionTask: Task<Void, Never>? = nil
    /// The most recent distraction app name — used to pick the right AppleScript redirect.
    private var lastDistractionApp: String = ""

    // MARK: - Init

    private init() {
        isActive = UserDefaults.standard.bool(forKey: "focusModeActive")
    }

    // MARK: - Toggle

    func enable() {
        guard !isActive else { return }
        pendingInterventionTask?.cancel()
        pendingInterventionTask = nil
        isActive = true
        startedAt = Date()
        interventionCount = 0
        distractionSince = nil
        lastInterventionAt = nil
        UserDefaults.standard.set(true, forKey: "focusModeActive")
        focusLog.info("Focus Mode enabled")
    }

    func disable() {
        guard isActive else { return }
        isActive = false
        startedAt = nil
        pendingInterventionTask?.cancel()
        pendingInterventionTask = nil
        distractionSince = nil
        UserDefaults.standard.set(false, forKey: "focusModeActive")
        focusLog.info("Focus Mode disabled — \(self.interventionCount) intervention(s) this session")
    }

    func toggle() {
        isActive ? disable() : enable()
    }

    // MARK: - Activity Check

    /// Called by ActivityTracker after every category resolution.
    /// Fires on every app switch and browser tab change — reacts within seconds.
    func checkActivity(category: Category, appName: String, windowTitle: String = "", url: String? = nil) {
        guard isActive else { return }

        if category == .distraction {
            lastDistractionApp = appName

            if distractionSince == nil {
                // Fresh distraction — start tracking
                distractionSince = Date()
                schedulePendingIntervention(appName: appName, windowTitle: windowTitle, url: url)
            } else {
                // Still distracted — always re-schedule so that navigating away from
                // the motivation video back to distraction triggers immediately.
                schedulePendingIntervention(appName: appName, windowTitle: windowTitle, url: url)
            }
        } else {
            distractionSince = nil
            pendingInterventionTask?.cancel()
            pendingInterventionTask = nil
        }
    }

    // MARK: - Scheduling

    private func schedulePendingIntervention(appName: String, windowTitle: String, url: String?) {
        pendingInterventionTask?.cancel()

        // For YouTube: kick off AI classification immediately, in parallel with the grace period.
        let isYouTube = url?.contains("youtube") == true || appName.lowercased().contains("youtube")
        let aiTask: Task<Bool, Never>? = isYouTube && !windowTitle.isEmpty
            ? Task { await ContentAIClassifier.shared.isEducational(videoTitle: windowTitle) }
            : nil

        // Escalating grace: shorter if we recently intervened
        let isRepeat = lastInterventionAt.map { Date().timeIntervalSince($0) < repeatWindow } ?? false
        let grace = isRepeat ? repeatGracePeriod : gracePeriod

        pendingInterventionTask = Task {
            do {
                try await Task.sleep(for: .seconds(grace))
            } catch {
                aiTask?.cancel()
                return  // cancelled — user went back to productive work
            }

            guard distractionSince != nil else {
                aiTask?.cancel()
                return
            }

            // Check AI verdict — it almost always resolves during the grace period.
            if let aiTask {
                let isEducational = await aiTask.value
                if isEducational {
                    focusLog.info("AI override: '\(windowTitle.prefix(50))' is educational — skipping")
                    distractionSince = nil
                    return
                }
            }

            // Cooldown guard
            if let last = lastInterventionAt, Date().timeIntervalSince(last) < cooldown {
                focusLog.debug("Intervention skipped — cooldown active (\(String(format: "%.1f", Date().timeIntervalSince(last)))s / \(Int(self.cooldown))s)")
                // Keep distractionSince so next checkActivity re-triggers
                pendingInterventionTask = nil
                return
            }

            intervene(appName: lastDistractionApp)
        }
    }

    // MARK: - Intervention

    private func intervene(appName: String) {
        lastInterventionAt = Date()
        interventionCount += 1
        focusLog.info("Intervention #\(self.interventionCount) — \(appName)")

        // Redirect the CURRENT browser tab to the motivation video.
        redirectCurrentBrowserTab(appName: appName)

        sendNotification()

        // Set to fresh Date (NOT nil) so the next checkActivity call (~5s later) sees
        // elapsed time > repeat grace and can immediately re-intervene if still distracted.
        distractionSince = Date()
        pendingInterventionTask = nil
    }

    // MARK: - Browser Redirect via AppleScript

    /// Replaces the URL of the active browser tab with the motivation video.
    /// Falls back to opening a new tab for unsupported browsers (e.g. Firefox).
    /// Retries once on failure and falls back to NSWorkspace.open if both attempts fail.
    private func redirectCurrentBrowserTab(appName: String) {
        let urlStr = motivationURL.absoluteString
        let app = appName.lowercased()
        let motivURL = motivationURL

        let script: String
        if app.contains("safari") {
            script = """
            tell application "Safari"
                if (count windows) > 0 then set URL of current tab of front window to "\(urlStr)"
            end tell
            """
        } else if app.contains("chrome") {
            script = """
            tell application "Google Chrome"
                if (count windows) > 0 then set URL of active tab of front window to "\(urlStr)"
            end tell
            """
        } else if app.contains("brave") {
            script = """
            tell application "Brave Browser"
                if (count windows) > 0 then set URL of active tab of front window to "\(urlStr)"
            end tell
            """
        } else if app.contains("edge") {
            script = """
            tell application "Microsoft Edge"
                if (count windows) > 0 then set URL of active tab of front window to "\(urlStr)"
            end tell
            """
        } else if app.contains("arc") {
            script = """
            tell application "Arc"
                if (count windows) > 0 then set URL of active tab of front window to "\(urlStr)"
            end tell
            """
        } else {
            // Firefox and others don't support tab URL setting via AppleScript.
            NSWorkspace.shared.open(motivURL)
            return
        }

        // Run osascript on a background thread to avoid blocking the MainActor.
        Task.detached(priority: .userInitiated) {
            let success = await Self.runAppleScript(script)
            if !success {
                focusLog.debug("First redirect attempt failed, retrying…")
                let retrySuccess = await Self.runAppleScript(script)
                if !retrySuccess {
                    focusLog.debug("Redirect retry failed — falling back to NSWorkspace.open")
                    await MainActor.run { NSWorkspace.shared.open(motivURL) }
                }
            }
        }
    }

    /// Runs an AppleScript string via osascript on a background thread. Returns true on success.
    private nonisolated static func runAppleScript(_ script: String) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                proc.arguments = ["-e", script]
                proc.standardOutput = FileHandle.nullDevice
                proc.standardError = FileHandle.nullDevice
                do {
                    try proc.run()
                    proc.waitUntilExit()
                    continuation.resume(returning: proc.terminationStatus == 0)
                } catch {
                    continuation.resume(returning: false)
                }
            }
        }
    }

    // MARK: - Notification

    private func sendNotification() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "Stay on Track! 🎯"
            content.body  = "Distraction blocked. Back to the mission 💪"
            content.sound = .default
            let req = UNNotificationRequest(
                identifier: "focus-\(Int(Date().timeIntervalSince1970))",
                content: content,
                trigger: nil
            )
            UNUserNotificationCenter.current().add(req)
        }
    }
}
