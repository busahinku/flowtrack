import Foundation
import AppKit
import UserNotifications
import OSLog

private let monitorLog = Logger(subsystem: "com.flowtrack", category: "AppBlockerMonitor")

// MARK: - AppBlockerMonitor
/// Ticks every 5s, enforces BlockCard time limits by terminating apps or blocking websites.
@MainActor
final class AppBlockerMonitor {
    static let shared = AppBlockerMonitor()

    private var tickTimer: Timer?
    private var lastTickDate: Date = Date()

    private var store:   AppBlockerStore  { AppBlockerStore.shared }
    private var tracker: ActivityTracker  { ActivityTracker.shared }

    private init() {}

    func start() {
        guard tickTimer == nil else { return }
        tickTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.tick() }
        }
        monitorLog.info("AppBlockerMonitor started")
    }

    func stop() { tickTimer?.invalidate(); tickTimer = nil }

    // MARK: - Tick

    private func tick() {
        let now     = Date()
        let elapsed = Int(now.timeIntervalSince(lastTickDate))
        lastTickDate = now

        let currentBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""

        for card in store.cards where card.isEnabled {
            // --- App enforcement ---
            if !card.apps.isEmpty, !currentBundleID.isEmpty {
                let matchedApp = card.apps.first {
                    $0.bundleID.lowercased() == currentBundleID.lowercased()
                }
                if let matched = matchedApp {
                    if card.isAlwaysBlock {
                        terminateApp(bundleID: currentBundleID, cardName: card.name, limitMinutes: 0)
                    } else {
                        store.recordUsage(cardId: card.id, addSeconds: elapsed)
                        let used  = store.usageToday(for: card.id)
                        let limit = card.dailyLimitMinutes * 60
                        if used >= limit {
                            terminateApp(bundleID: currentBundleID, cardName: card.name, limitMinutes: card.dailyLimitMinutes)
                        }
                        _ = matched // suppress unused-var warning
                    }
                }
            }

            // --- Website time-limit enforcement ---
            if !card.websites.isEmpty && !card.isAlwaysBlock {
                let used  = store.usageToday(for: card.id)
                let limit = card.dailyLimitMinutes * 60
                if used >= limit {
                    store.blockCardNow(cardId: card.id)
                    sendBlockNotification(name: card.name, limitMinutes: card.dailyLimitMinutes)
                }
            }
        }
    }

    // MARK: - Enforcement

    private func terminateApp(bundleID: String, cardName: String, limitMinutes: Int) {
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID) {
            app.forceTerminate()
        }
        sendBlockNotification(name: cardName, limitMinutes: limitMinutes)
        monitorLog.info("Terminated \(bundleID) (card: \(cardName))")
    }

    private func sendBlockNotification(name: String, limitMinutes: Int) {
        let content = UNMutableNotificationContent()
        content.title = "Blocked by FlowTrack"
        content.body  = limitMinutes == 0
            ? "\(name) is blocked to keep you focused."
            : "\(name) reached its \(limitMinutes)-minute daily limit."
        content.sound = .default
        let req = UNNotificationRequest(
            identifier: "blocker-\(name)-\(Date().timeIntervalSince1970)",
            content: content, trigger: nil
        )
        UNUserNotificationCenter.current().add(req) { err in
            if let err { monitorLog.error("Notification error: \(err.localizedDescription)") }
        }
    }
}
