import Foundation

final class RuleEngine: @unchecked Sendable {
    static let shared = RuleEngine()

    private var defaultRules: [Rule] = []
    private var customRules: [Rule] = []
    private var learnedRules: [Rule] = []
    private let customRulesURL: URL
    private let learnedRulesURL: URL

    // Cache: bundleID → category (from AI learning)
    private var categoryCache: [String: Category] = [:]

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let folder = appSupport.appendingPathComponent("FlowTrack")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        customRulesURL = folder.appendingPathComponent("custom_rules.json")
        learnedRulesURL = folder.appendingPathComponent("learned_rules.json")

        loadDefaultRules()
        loadCustomRules()
        loadLearnedRules()
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

    private func loadLearnedRules() {
        guard let data = try? Data(contentsOf: learnedRulesURL),
              let rules = try? JSONDecoder().decode([Rule].self, from: data) else {
            learnedRules = []
            return
        }
        learnedRules = rules
        // Populate cache from learned rules
        for rule in learnedRules where rule.matchType == .bundleID {
            categoryCache[rule.pattern.lowercased()] = Category(rawValue: rule.category)
        }
    }

    private func saveCustomRules() {
        if let data = try? JSONEncoder().encode(customRules) {
            try? data.write(to: customRulesURL, options: .atomic)
        }
    }

    private func saveLearnedRules() {
        if let data = try? JSONEncoder().encode(learnedRules) {
            try? data.write(to: learnedRulesURL, options: .atomic)
        }
    }

    // MARK: - Categorize
    func categorize(appName: String, bundleID: String, windowTitle: String, url: String?) -> Category? {
        // 1. Custom rules (user-defined, highest priority)
        if let cat = matchRules(customRules, appName: appName, bundleID: bundleID, windowTitle: windowTitle, url: url) {
            return cat
        }
        // 2. Default rules (built-in)
        if let cat = matchRules(defaultRules, appName: appName, bundleID: bundleID, windowTitle: windowTitle, url: url) {
            return cat
        }
        // 3. AI-learned rules (from previous AI categorizations)
        if let cat = matchRules(learnedRules, appName: appName, bundleID: bundleID, windowTitle: windowTitle, url: url) {
            return cat
        }
        // 4. Cache lookup by bundle ID
        if let cached = categoryCache[bundleID.lowercased()] {
            return cached
        }
        // 5. Smart fallback based on bundle ID patterns
        if let cat = smartCategorize(appName: appName, bundleID: bundleID) {
            return cat
        }
        return nil
    }

    // MARK: - Smart Categorization Fallback
    private func smartCategorize(appName: String, bundleID: String) -> Category? {
        let bid = bundleID.lowercased()
        let name = appName.lowercased()

        // Apple system apps
        if bid.hasPrefix("com.apple.") {
            let suffix = bid.replacingOccurrences(of: "com.apple.", with: "")
            // Development
            if ["dt.xcode", "instruments", "filesmerge", "accessibilityinspector"].contains(where: { suffix.contains($0) }) {
                return .work
            }
            // Communication
            if ["mail", "messages", "facetime"].contains(where: { suffix.hasPrefix($0) }) {
                return .communication
            }
            // Productivity
            if ["notes", "reminders", "calendar", "pages", "numbers", "keynote", "iwork", "shortcuts"].contains(where: { suffix.hasPrefix($0) }) {
                return .productivity
            }
            // Creative
            if ["garageband", "imovie", "photos", "preview"].contains(where: { suffix.hasPrefix($0) }) {
                return .creative
            }
            // Entertainment
            if ["music", "tv", "podcasts", "books"].contains(where: { suffix.hasPrefix($0) }) {
                return .entertainment
            }
            // Personal (system utilities and default)
            return .personal
        }

        // JetBrains IDEs
        if bid.hasPrefix("com.jetbrains.") {
            return .work
        }

        // Microsoft apps
        if bid.hasPrefix("com.microsoft.") {
            if bid.contains("teams") { return .communication }
            if bid.contains("outlook") { return .communication }
            if bid.contains("word") || bid.contains("excel") || bid.contains("powerpoint") || bid.contains("onenote") { return .productivity }
            if bid.contains("vscode") || bid.contains("visual-studio") { return .work }
            return .productivity
        }

        // Google apps
        if bid.hasPrefix("com.google.") {
            if bid.contains("chrome") { return nil } // Let browser URL rules handle it
            return .productivity
        }

        // Common development tools by bundle ID
        if bid.contains("terminal") || bid.contains("iterm") || bid.contains("warp") || bid.contains("ghostty") ||
           bid.contains("alacritty") || bid.contains("kitty") || bid.contains("hyper") {
            return .work
        }

        // Browsers — categorize as Personal by default (URL-based rules override if URL available)
        if isBrowser(appName: name, bundleID: bid) {
            return .personal
        }

        // Common app name patterns
        if name.contains("code") || name.contains("studio") || name.contains("editor") || name.contains("debug") {
            return .work
        }
        if name.contains("chat") || name.contains("messenger") || name.contains("meet") {
            return .communication
        }

        return nil
    }

    private func isBrowser(appName: String, bundleID: String) -> Bool {
        let browserNames = ["safari", "chrome", "firefox", "arc", "brave", "edge", "opera", "vivaldi", "chromium", "orion", "duckduckgo"]
        let browserBIDs = ["webkit", "chrome", "firefox", "browser", "arc"]
        return browserNames.contains(where: { appName.contains($0) }) ||
               browserBIDs.contains(where: { bundleID.lowercased().contains($0) })
    }

    // MARK: - Rule Matching
    private func matchRules(_ rules: [Rule], appName: String, bundleID: String, windowTitle: String, url: String?) -> Category? {
        for rule in rules {
            let matched: Bool
            switch rule.matchType {
            case .appName:
                matched = appName.lowercased().contains(rule.pattern.lowercased())
            case .bundleID:
                let bid = bundleID.lowercased()
                let pattern = rule.pattern.lowercased()
                matched = bid == pattern || bid.hasPrefix(pattern + ".")
            case .domain:
                if let url = url?.lowercased() {
                    let pattern = rule.pattern.lowercased()
                    // Match domain anywhere in URL (handles https://, subdomains, paths)
                    matched = url.contains(pattern)
                } else {
                    matched = false
                }
            case .titleContains:
                matched = windowTitle.lowercased().contains(rule.pattern.lowercased())
            }
            if matched {
                return Category(rawValue: rule.category)
            }
        }
        return nil
    }

    // MARK: - AI Learning
    /// Called when AI categorizes an app. Learns the bundleID → category mapping.
    func learnFromAI(appName: String, bundleID: String, category: Category) {
        guard !bundleID.isEmpty, category != .uncategorized, category != .idle else { return }
        let bid = bundleID.lowercased()

        // Don't learn if already in custom or default rules
        if matchRules(customRules, appName: appName, bundleID: bundleID, windowTitle: "", url: nil) != nil { return }
        if matchRules(defaultRules, appName: appName, bundleID: bundleID, windowTitle: "", url: nil) != nil { return }

        // Check if already learned
        if categoryCache[bid] != nil { return }

        // Learn it
        let rule = Rule(matchType: .bundleID, pattern: bundleID, category: category.rawValue)
        learnedRules.append(rule)
        categoryCache[bid] = category
        saveLearnedRules()
    }

    // MARK: - Custom Rules CRUD
    var allCustomRules: [Rule] { customRules }
    var allLearnedRules: [Rule] { learnedRules }
    var defaultRuleCount: Int { defaultRules.count }
    var learnedRuleCount: Int { learnedRules.count }

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

    func clearLearnedRules() {
        learnedRules.removeAll()
        categoryCache.removeAll()
        saveLearnedRules()
    }
}
