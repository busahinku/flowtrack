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
    private let flowTrackBundleID = "com.flowtrack.app"

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
    private var pendingRedirectTask: Task<Void, Never>? = nil
    private var sessionGeneration: UInt64 = 0

    // MARK: - Init

    private init() {
        isActive = false
    }

    // MARK: - Toggle

    func enable() {
        guard !isActive else { return }
        cancelPendingWork(bumpGeneration: true)
        isActive = true
        startedAt = Date()
        interventionCount = 0
        distractionSince = nil
        lastInterventionAt = nil
        UserDefaults.standard.set(true, forKey: "focusModeActive")
        focusLog.info("Focus Mode enabled")
    }

    func disable() {
        let wasActive = isActive
        isActive = false
        startedAt = nil
        cancelPendingWork(bumpGeneration: true)
        UserDefaults.standard.set(false, forKey: "focusModeActive")
        if wasActive {
            focusLog.info("Focus Mode disabled — \(self.interventionCount) intervention(s) this session")
        }
    }

    func toggle() {
        isActive ? disable() : enable()
    }

    func handleTrackingStopped() {
        disable()
    }

    // MARK: - Activity Check

    /// Called by ActivityTracker after every category resolution.
    /// Fires on every app switch and browser tab change — reacts within seconds.
    func checkActivity(category: Category, appName: String, windowTitle: String = "", url: String? = nil) {
        guard isActive else { return }
        guard !isFlowTrackForegroundApp(appName: appName) else {
            distractionSince = nil
            cancelPendingRedirects()
            return
        }

        if category == .distraction {
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
            cancelPendingRedirects()
        }
    }

    // MARK: - Scheduling

    private func schedulePendingIntervention(appName: String, windowTitle: String, url: String?) {
        pendingInterventionTask?.cancel()
        let generation = sessionGeneration

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

            guard self.isActive, self.sessionGeneration == generation else {
                aiTask?.cancel()
                self.pendingInterventionTask = nil
                return
            }

            let currentFrontmostName = NSWorkspace.shared.frontmostApplication?.localizedName ?? ""
            guard currentFrontmostName.caseInsensitiveCompare(appName) == .orderedSame ||
                  currentFrontmostName.localizedCaseInsensitiveContains(appName) ||
                  appName.localizedCaseInsensitiveContains(currentFrontmostName) else {
                focusLog.debug("Intervention skipped — frontmost app changed to \(currentFrontmostName, privacy: .public)")
                self.pendingInterventionTask = nil
                return
            }

            intervene(appName: appName, generation: generation)
        }
    }

    // MARK: - Intervention

    private func intervene(appName: String, generation: UInt64) {
        guard isActive, sessionGeneration == generation else { return }
        guard !isFlowTrackForegroundApp(appName: appName) else { return }
        lastInterventionAt = Date()
        interventionCount += 1
        focusLog.info("Intervention #\(self.interventionCount) — \(appName)")

        // Step 1.0: For browsers, only replace the active distraction tab.
        // For native apps, quit the distraction app before opening the reset video.
        interveneAgainstFrontmostDistraction(appName: appName, generation: generation)

        sendNotification()

        // Set to fresh Date (NOT nil) so the next checkActivity call (~5s later) sees
        // elapsed time > repeat grace and can immediately re-intervene if still distracted.
        distractionSince = Date()
        pendingInterventionTask = nil
    }

    // MARK: - Intervention Redirect

    private func interveneAgainstFrontmostDistraction(appName: String, generation: UInt64) {
        pendingRedirectTask?.cancel()
        let expectedName = appName
        let motivURL = motivationURL

        pendingRedirectTask = Task { [weak self] in
            guard let self else { return }
            guard let frontmostApp = NSWorkspace.shared.frontmostApplication,
                  let frontmostName = frontmostApp.localizedName,
                  frontmostName.caseInsensitiveCompare(expectedName) == .orderedSame ||
                  frontmostName.localizedCaseInsensitiveContains(expectedName) ||
                  expectedName.localizedCaseInsensitiveContains(frontmostName) else {
                self.pendingRedirectTask = nil
                return
            }

            let bundleID = frontmostApp.bundleIdentifier?.lowercased() ?? ""
            if self.isSupportedBrowser(bundleID: bundleID, appName: frontmostName) {
                await self.replaceBrowserDistractionTab(appName: frontmostName, targetURL: motivURL, generation: generation)
                return
            }

            guard bundleID != self.flowTrackBundleID else {
                self.pendingRedirectTask = nil
                return
            }

            _ = frontmostApp.terminate()
            try? await Task.sleep(for: .milliseconds(700))

            guard !Task.isCancelled, self.isActive, self.sessionGeneration == generation else {
                self.pendingRedirectTask = nil
                return
            }

            NSWorkspace.shared.open(motivURL)
            self.pendingRedirectTask = nil
        }
    }

    private func cancelPendingWork(bumpGeneration: Bool) {
        if bumpGeneration {
            sessionGeneration &+= 1
        }
        cancelPendingRedirects()
        distractionSince = nil
    }

    private func cancelPendingRedirects() {
        pendingInterventionTask?.cancel()
        pendingInterventionTask = nil
        pendingRedirectTask?.cancel()
        pendingRedirectTask = nil
    }

    private func isFlowTrackForegroundApp(appName: String) -> Bool {
        if appName.caseInsensitiveCompare("FlowTrack") == .orderedSame {
            return true
        }
        return NSWorkspace.shared.frontmostApplication?.bundleIdentifier?.lowercased() == flowTrackBundleID
    }

    private func isSupportedBrowser(bundleID: String, appName: String) -> Bool {
        if ["com.apple.safari", "com.apple.safaritechnologypreview", "com.google.chrome",
            "com.google.chrome.canary", "com.brave.browser", "com.microsoft.edgemac",
            "com.opera.opera", "com.vivaldi.vivaldi", "company.thebrowser.browser",
            "com.chromium.chromium"].contains(bundleID) {
            return true
        }

        let name = appName.lowercased()
        return ["safari", "chrome", "brave", "edge", "opera", "vivaldi", "arc", "chromium"]
            .contains(where: { name.contains($0) })
    }

    private func replaceBrowserDistractionTab(appName: String, targetURL: URL, generation: UInt64) async {
        let urlStr = targetURL.absoluteString.replacingOccurrences(of: "\"", with: "\\\"")
        guard let script = browserReplaceTabScript(appName: appName, urlString: urlStr) else {
            guard !Task.isCancelled, isActive, sessionGeneration == generation else {
                pendingRedirectTask = nil
                return
            }
            NSWorkspace.shared.open(targetURL)
            pendingRedirectTask = nil
            return
        }

        let success = await Self.runAppleScript(script)
        guard !Task.isCancelled, isActive, sessionGeneration == generation else {
            pendingRedirectTask = nil
            return
        }

        if !success {
            NSWorkspace.shared.open(targetURL)
        }
        pendingRedirectTask = nil
    }

    private func browserReplaceTabScript(appName: String, urlString: String) -> String? {
        let lowerName = appName.lowercased()
        if lowerName.contains("safari") {
            return """
            tell application "\(appName)"
                if (count windows) = 0 then
                    make new document with properties {URL:"\(urlString)"}
                else
                    tell front window
                        set current tab to (make new tab with properties {URL:"\(urlString)"})
                        if (count tabs) > 1 then close tab -2
                    end tell
                end if
                activate
            end tell
            """
        }

        if ["chrome", "brave", "edge", "opera", "vivaldi", "arc", "chromium"].contains(where: { lowerName.contains($0) }) {
            return """
            tell application "\(appName)"
                if (count windows) = 0 then
                    make new window
                    set URL of active tab of front window to "\(urlString)"
                else
                    tell front window
                        set oldIndex to active tab index
                        make new tab with properties {URL:"\(urlString)"}
                        set active tab index to (count tabs)
                        if (count tabs) > 1 then close tab oldIndex
                    end tell
                end if
                activate
            end tell
            """
        }

        return nil
    }

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
