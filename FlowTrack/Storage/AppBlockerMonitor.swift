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
    /// Cards for which we've already sent a notification today — resets on new day.
    private var notifiedCardIds: Set<String> = []
    private var lastNotifResetDay: Int = Calendar.current.component(.day, from: Date())

    private var store:   AppBlockerStore  { AppBlockerStore.shared }
    private var tracker: ActivityTracker  { ActivityTracker.shared }

    private init() {}

    func start() {
        store.applyBlocking()
        updateActive()
        monitorLog.info("AppBlockerMonitor started")
    }

    /// Call after any change to store.cards (add/remove/enable) to start/stop the timer appropriately.
    func updateActive() {
        let needsLiveMonitoring = store.cards.contains { card in
            card.isEnabled && (!card.apps.isEmpty || (!card.isAlwaysBlock && !card.websites.isEmpty))
        }
        if needsLiveMonitoring && tickTimer == nil {
            lastTickDate = Date()
            let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
                guard let self else { return }
                Task { @MainActor in self.tick() }
            }
            timer.tolerance = 1
            RunLoop.main.add(timer, forMode: .common)
            tickTimer = timer
        } else if !needsLiveMonitoring {
            stop()
        }
    }

    func stop() { tickTimer?.invalidate(); tickTimer = nil }

    // MARK: - Tick

    private func tick() {
        let now     = Date()
        // Cap elapsed to the tick interval to prevent sleep-wake time inflation
        let elapsed = min(Int(now.timeIntervalSince(lastTickDate)), 10)
        lastTickDate = now

        // Reset per-day notification dedup set when the calendar day rolls over
        let today = Calendar.current.component(.day, from: now)
        if today != lastNotifResetDay {
            notifiedCardIds.removeAll()
            lastNotifResetDay = today
            store.applyBlocking()
        }

        let currentBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        let currentURL = tracker.currentURL ?? ""

        for card in store.cards where card.isEnabled {
            // --- App enforcement ---
            if !card.apps.isEmpty, !currentBundleID.isEmpty {
                let matchedApp = card.apps.first {
                    $0.bundleID.lowercased() == currentBundleID.lowercased()
                }
                if matchedApp != nil {
                    if card.isAlwaysBlock {
                        terminateApp(bundleID: currentBundleID, cardId: card.id, cardName: card.name, limitMinutes: 0)
                    } else {
                        store.recordUsage(cardId: card.id, addSeconds: elapsed)
                        let used  = store.usageToday(for: card.id)
                        let limit = card.dailyLimitMinutes * 60
                        if used >= limit {
                            terminateApp(bundleID: currentBundleID, cardId: card.id, cardName: card.name, limitMinutes: card.dailyLimitMinutes)
                        }
                    }
                }
            }

            // --- Website enforcement ---
            if !card.websites.isEmpty && !currentURL.isEmpty {
                let onBlockedSite = card.websites.contains { domain in
                    DomainMatcher.url(currentURL, matches: domain)
                }
                if onBlockedSite && !card.isAlwaysBlock {
                    // Track time spent on time-limited websites
                    store.recordUsage(cardId: card.id, addSeconds: elapsed)
                    let used  = store.usageToday(for: card.id)
                    let limit = card.dailyLimitMinutes * 60
                    if used >= limit {
                        store.blockCardNow(cardId: card.id)
                        if !notifiedCardIds.contains(card.id) {
                            notifiedCardIds.insert(card.id)
                            sendBlockNotification(name: card.name, limitMinutes: card.dailyLimitMinutes)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Enforcement

    private func terminateApp(bundleID: String, cardId: String, cardName: String, limitMinutes: Int) {
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID) {
            app.forceTerminate()
        }
        if !notifiedCardIds.contains(cardId) {
            notifiedCardIds.insert(cardId)
            sendBlockNotification(name: cardName, limitMinutes: limitMinutes)
        }
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
