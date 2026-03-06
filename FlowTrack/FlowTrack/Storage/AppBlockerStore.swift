import Foundation
import AppKit
import UserNotifications
import OSLog

private let blockerLog = Logger(subsystem: "com.flowtrack", category: "AppBlocker")

// MARK: - AppBlockerStore
@MainActor @Observable
final class AppBlockerStore {
    static let shared = AppBlockerStore()

    private(set) var cards:  [BlockCard]  = []
    private(set) var usages: [BlockUsage] = []

    private let cardsURL:  URL
    private let usagesURL: URL

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX"); return f
    }()

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FlowTrack", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        cardsURL  = support.appendingPathComponent("block_cards.json")
        usagesURL = support.appendingPathComponent("block_usage.json")
        load()
    }

    // MARK: - Persistence

    private func load() {
        if let d = try? Data(contentsOf: cardsURL),
           let v = try? JSONDecoder().decode([BlockCard].self, from: d) { cards = v }
        if let d = try? Data(contentsOf: usagesURL),
           let v = try? JSONDecoder().decode([BlockUsage].self, from: d) { usages = v }
    }
    private func saveCards()  { if let d = try? JSONEncoder().encode(cards)  { try? d.write(to: cardsURL,  options: .atomic) } }
    private func saveUsages() { if let d = try? JSONEncoder().encode(usages) { try? d.write(to: usagesURL, options: .atomic) } }

    // MARK: - Card Management

    func addCard(_ card: BlockCard) {
        cards.append(card); saveCards()
        if card.isEnabled { applyBlocking() }
    }
    func updateCard(_ card: BlockCard) {
        guard let i = cards.firstIndex(where: { $0.id == card.id }) else { return }
        cards[i] = card; saveCards(); applyBlocking()
    }
    func deleteCard(id: String) { cards.removeAll { $0.id == id }; saveCards(); applyBlocking() }
    func toggleCard(id: String) {
        guard let i = cards.firstIndex(where: { $0.id == id }) else { return }
        cards[i].isEnabled.toggle(); saveCards(); applyBlocking()
    }

    // MARK: - Usage

    var todayKey: String { Self.dateFormatter.string(from: Date()) }

    func usageToday(for cardId: String) -> Int {
        usages.first { $0.cardId == cardId && $0.date == todayKey }?.usedSeconds ?? 0
    }

    func recordUsage(cardId: String, addSeconds: Int) {
        if let i = usages.firstIndex(where: { $0.cardId == cardId && $0.date == todayKey }) {
            usages[i].usedSeconds += addSeconds
        } else {
            usages.append(BlockUsage(cardId: cardId, date: todayKey, usedSeconds: addSeconds))
        }
        let cutoff = Self.dateFormatter.string(from: Calendar.current.date(byAdding: .day, value: -30, to: Date())!)
        usages.removeAll { $0.date < cutoff }
        saveUsages()
    }

    // MARK: - Hosts + pfctl

    /// Apply always-block cards' websites to /etc/hosts and set up pfctl port-redirect.
    func applyBlocking() {
        let domains = cards.filter { $0.isEnabled && $0.isAlwaysBlock }.flatMap(\.websites)
        rewriteHostsBlock(domains: domains)
    }

    /// Immediately block a card's sites (time limit reached).
    func blockCardNow(cardId: String) {
        guard let card = cards.first(where: { $0.id == cardId }) else { return }
        let already = cards.filter { $0.isEnabled && $0.isAlwaysBlock }.flatMap(\.websites)
        rewriteHostsBlock(domains: Array(Set(already + card.websites)))
    }

    private let hostsBegin = "# FlowTrack-Blocked-Begin"
    private let hostsEnd   = "# FlowTrack-Blocked-End"

    private func rewriteHostsBlock(domains: [String]) {
        // Run entirely on a background thread — AppleScript + admin auth can take seconds
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            self._rewriteHostsBlockSync(domains: domains)
        }
    }

    private func _rewriteHostsBlockSync(domains: [String]) {
        let hostsPath = "/etc/hosts"
        guard let current = try? String(contentsOfFile: hostsPath, encoding: .utf8) else { return }

        // Build new FlowTrack section
        var newSection = ""
        if !domains.isEmpty {
            let lines = domains.flatMap { d -> [String] in
                let d = d.lowercased().trimmingCharacters(in: .init(charactersIn: "/ "))
                return ["127.0.0.1 \(d)", "127.0.0.1 www.\(d)"]
            }.joined(separator: "\n")
            newSection = "\(hostsBegin)\n\(lines)\n\(hostsEnd)"
        }

        // Strip existing FlowTrack section
        var cleaned = current
        if let b = cleaned.range(of: hostsBegin), let e = cleaned.range(of: hostsEnd) {
            cleaned.removeSubrange(b.lowerBound ..< cleaned.index(after: e.upperBound))
        }
        let base      = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        let newHosts  = newSection.isEmpty ? base + "\n" : base + "\n" + newSection + "\n"
        guard newHosts != current else { return }

        // Build AppleScript via temp file to avoid quoting hell
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("flowtrack_hosts_\(UUID().uuidString)")
        guard let _ = try? newHosts.write(to: tmp, atomically: true, encoding: .utf8) else { return }
        let tmpPath = tmp.path

        // pfctl redirect rule for custom block page on port 8080
        let pfPart: String
        if domains.isEmpty {
            pfPart = "pfctl -a com.flowtrack -F all 2>/dev/null; true"
        } else {
            // Write pf rule to a temp file too
            let pfTmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("flowtrack_pf_\(UUID().uuidString).conf")
            let pfRule = "rdr pass on lo0 proto tcp from any to 127.0.0.1 port {80,443} -> 127.0.0.1 port 8080\n"
            if let _ = try? pfRule.write(to: pfTmp, atomically: true, encoding: .utf8) {
                pfPart = "pfctl -a com.flowtrack -f \(pfTmp.path) 2>/dev/null; pfctl -e 2>/dev/null; true"
            } else {
                pfPart = "true"
            }
        }

        let shellCmd = "cp \(tmpPath) /etc/hosts && \(pfPart) && dscacheutil -flushcache"
        let script   = "do shell script \"\(shellCmd)\" with administrator privileges"

        var errDict: NSDictionary?
        if let appleScript = NSAppleScript(source: script) {
            appleScript.executeAndReturnError(&errDict)
            if errDict == nil {
                blockerLog.info("Hosts file updated: \(domains.count) domain(s) blocked")
                Task { @MainActor in BlockPageServer.shared.start() }
            } else {
                blockerLog.error("Failed to update hosts/pfctl: \(String(describing: errDict))")
            }
        }
        try? FileManager.default.removeItem(at: tmp)
    }

    func removeAllBlocking() {
        rewriteHostsBlock(domains: [])
    }
}
