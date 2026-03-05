import Foundation

final class RuleEngine: @unchecked Sendable {
    static let shared = RuleEngine()

    private var defaultRules: [Rule] = []
    private var customRules: [Rule] = []
    private let customRulesURL: URL

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let folder = appSupport.appendingPathComponent("FlowTrack")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        customRulesURL = folder.appendingPathComponent("custom_rules.json")

        loadDefaultRules()
        loadCustomRules()
    }

    private func loadDefaultRules() {
        guard let url = Bundle.main.url(forResource: "DefaultRules", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let rules = try? JSONDecoder().decode([Rule].self, from: data) else {
            defaultRules = []
            return
        }
        defaultRules = rules
    }

    private func loadCustomRules() {
        guard let data = try? Data(contentsOf: customRulesURL),
              let rules = try? JSONDecoder().decode([Rule].self, from: data) else {
            customRules = []
            return
        }
        customRules = rules
    }

    private func saveCustomRules() {
        if let data = try? JSONEncoder().encode(customRules) {
            try? data.write(to: customRulesURL, options: .atomic)
        }
    }

    // MARK: - Categorize
    func categorize(appName: String, bundleID: String, windowTitle: String, url: String?) -> Category? {
        // Custom rules take priority
        if let cat = matchRules(customRules, appName: appName, bundleID: bundleID, windowTitle: windowTitle, url: url) {
            return cat
        }
        return matchRules(defaultRules, appName: appName, bundleID: bundleID, windowTitle: windowTitle, url: url)
    }

    private func matchRules(_ rules: [Rule], appName: String, bundleID: String, windowTitle: String, url: String?) -> Category? {
        for rule in rules {
            let matched: Bool
            switch rule.matchType {
            case .appName:
                matched = appName.lowercased().contains(rule.pattern.lowercased())
            case .bundleID:
                matched = bundleID.lowercased() == rule.pattern.lowercased()
            case .domain:
                matched = url?.lowercased().contains(rule.pattern.lowercased()) ?? false
            case .titleContains:
                matched = windowTitle.lowercased().contains(rule.pattern.lowercased())
            }
            if matched {
                return Category(rawValue: rule.category)
            }
        }
        return nil
    }

    // MARK: - Custom Rules CRUD
    var allCustomRules: [Rule] { customRules }

    func addRule(_ rule: Rule) {
        customRules.append(rule)
        saveCustomRules()
    }

    func removeRule(at index: Int) {
        guard index < customRules.count else { return }
        customRules.remove(at: index)
        saveCustomRules()
    }

    func removeRule(withId id: String) {
        customRules.removeAll { $0.id == id }
        saveCustomRules()
    }
}
