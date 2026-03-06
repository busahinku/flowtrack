import Foundation

// Browser bundleIDs that must never be learned at the app level.
// These apps change category per URL/tab — only domain rules are valid.
private let browserBundleIDs: Set<String> = [
    "com.apple.safari",
    "com.apple.safaritechnologypreview",
    "com.google.chrome",
    "com.google.chrome.canary",
    "org.mozilla.firefox",
    "org.mozilla.nightly",
    "company.thebrowser.browser",   // Arc
    "com.brave.browser",
    "com.microsoft.edgemac",
    "com.opera.opera",
    "com.vivaldi.vivaldi",
    "com.kagi.orion",
    "com.duckduckgo.macos.browser",
    "com.chromium.chromium",
]

private func isBrowserBundleID(_ bundleID: String) -> Bool {
    browserBundleIDs.contains(bundleID.lowercased())
}

final class RuleEngine: @unchecked Sendable {
    static let shared = RuleEngine()

    private var defaultRules: [Rule] = []
    private var customRules: [Rule] = []
    private var learnedRules: [Rule] = []
    private let customRulesURL: URL
    private let learnedRulesURL: URL
    private let lock = NSLock()

    // Cache: bundleID → category (from AI learning) — never populated for browsers
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
        cleanBrowserLearnedRules()  // Remove any poisoned browser bundleID entries
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

    private static func extractDomain(from urlString: String) -> String {
        guard let components = URLComponents(string: urlString), let host = components.host else { return "" }
        let h = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        return h
    }

    private func loadLearnedRules() {
        guard let data = try? Data(contentsOf: learnedRulesURL),
              let rules = try? JSONDecoder().decode([Rule].self, from: data) else {
            learnedRules = []
            return
        }
        learnedRules = rules
        // Populate cache from learned rules (browsers are excluded by cleanBrowserLearnedRules)
        for rule in learnedRules where rule.matchType == .bundleID {
            categoryCache[rule.pattern.lowercased()] = Category(rawValue: rule.category)
        }
    }

    /// Remove any learned bundleID rules for browsers — they cause all browsing to show as one category.
    private func cleanBrowserLearnedRules() {
        let before = learnedRules.count
        learnedRules.removeAll { rule in
            rule.matchType == .bundleID && isBrowserBundleID(rule.pattern)
        }
        // Also clean category cache entries for browsers
        for bid in browserBundleIDs { categoryCache.removeValue(forKey: bid) }
        if learnedRules.count < before { saveLearnedRules() }
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
        lock.lock()
        let customSnap = customRules
        let defaultSnap = defaultRules
        let learnedSnap = learnedRules
        let cached = categoryCache[bundleID.lowercased()]
        lock.unlock()

        // 1. Custom rules (user-defined, highest priority)
        if let cat = matchRules(customSnap, appName: appName, bundleID: bundleID, windowTitle: windowTitle, url: url) {
            return cat
        }
        // 2. Default rules (built-in)
        if let cat = matchRules(defaultSnap, appName: appName, bundleID: bundleID, windowTitle: windowTitle, url: url) {
            return cat
        }
        // 3. AI-learned rules + cache
        if let cat = matchRules(learnedSnap, appName: appName, bundleID: bundleID, windowTitle: windowTitle, url: url) {
            return cat
        }
        // 4. Cache lookup by bundle ID
        if let cached { return cached }
        // 5. Smart fallback based on bundle ID patterns + window title heuristics
        if let cat = smartCategorize(appName: appName, bundleID: bundleID, windowTitle: windowTitle) {
            return cat
        }
        return nil
    }

    // MARK: - Smart Categorization Fallback
    private func smartCategorize(appName: String, bundleID: String, windowTitle: String = "") -> Category? {
        let bid = bundleID.lowercased()
        let name = appName.lowercased()
        let title = windowTitle.lowercased()

        // ── 1. Window title heuristics (highest signal when URL is unavailable) ─────────────
        // These fire for any app (browsers, native apps, electron wrappers)
        if !title.isEmpty {
            if let cat = titleHeuristic(title) { return cat }
        }

        // ── 2. Apple system apps ──────────────────────────────────────────────────────────────
        if bid.hasPrefix("com.apple.") {
            let suffix = bid.replacingOccurrences(of: "com.apple.", with: "")
            if ["dt.xcode", "instruments", "filesmerge", "accessibilityinspector", "simulator", "dt.instruments"].contains(where: { suffix.contains($0) }) { return .work }
            if ["mail", "messages", "facetime"].contains(where: { suffix.hasPrefix($0) }) { return .work }
            if ["notes", "reminders", "calendar", "pages", "numbers", "keynote", "iwork", "shortcuts", "freeform"].contains(where: { suffix.hasPrefix($0) }) { return .work }
            if ["garageband", "imovie", "photos", "preview"].contains(where: { suffix.hasPrefix($0) }) { return .creative }
            if ["music", "tv", "podcasts", "books"].contains(where: { suffix.hasPrefix($0) }) { return .entertainment }
            if suffix.hasPrefix("maps") { return .personal }
            return .personal
        }

        // ── 3. JetBrains IDEs ──────────────────────────────────────────────────────────────────
        if bid.hasPrefix("com.jetbrains.") { return .work }

        // ── 4. Microsoft apps ─────────────────────────────────────────────────────────────────
        if bid.hasPrefix("com.microsoft.") {
            if bid.contains("teams") || bid.contains("outlook") { return .work }
            if bid.contains("word") || bid.contains("excel") || bid.contains("powerpoint") || bid.contains("onenote") { return .work }
            if bid.contains("vscode") || bid.contains("visual-studio") { return .work }
            return .work
        }

        // ── 5. Adobe / Design apps ───────────────────────────────────────────────────────────
        if bid.hasPrefix("com.adobe.") {
            if bid.contains("lightroom") || bid.contains("photoshop") || bid.contains("premiere") ||
               bid.contains("illustrator") || bid.contains("indesign") || bid.contains("aftereffects") ||
               bid.contains("xd") { return .creative }
            if bid.contains("acrobat") || bid.contains("reader") { return .work }
            return .creative
        }

        // ── 6. Electron / known productivity apps by name ────────────────────────────────────
        let workAppNames = ["slack", "notion", "linear", "jira", "figma", "sketch", "1password",
                            "bitwarden", "tableplus", "sequel", "proxyman", "charles", "paw",
                            "insomnia", "postman", "sourcetree", "tower", "fork", "github desktop",
                            "datagrip", "sequel pro", "sequel ace", "dbeaver", "transmit", "cyberduck",
                            "filezilla", "robo 3t", "mongodbcompass", "snowflake", "datadog",
                            "zoom", "teams", "webex", "whereby", "loom", "cleanmymac", "alfred",
                            "raycast", "obsidian", "logseq", "bear", "craft", "drafts", "devonthink",
                            "toggl", "harvest", "timing", "rescuetime", "screenflow", "davinci",
                            "final cut", "logic pro", "ableton", "blender", "cinema 4d", "unity",
                            "unreal", "godot", "rider", "clion", "goland", "rubymine", "appcode",
                            "cursor", "zed", "neovim", "vim", "emacs", "sublimetext", "nova",
                            "bbedit", "textmate", "coderunner", "dash", "kaleidoscope", "reveal",
                            "instruments", "hopper", "charles proxy", "little snitch", "gas mask"]
        if workAppNames.contains(where: { name.contains($0) }) { return .work }

        let entertainmentAppNames = ["vlc", "iina", "infuse", "jellyfin", "plex", "kodi", "stremio",
                                     "steamlink", "openemu", "retroarch", "dolphin emulator",
                                     "spotify", "vox", "cog", "swinsian", "doppler", "capo"]
        if entertainmentAppNames.contains(where: { name.contains($0) }) { return .entertainment }

        let creativeAppNames = ["procreate", "pixelmator", "affinity", "canva", "sketch",
                                "principle", "protopie", "rive", "hype", "webflow"]
        if creativeAppNames.contains(where: { name.contains($0) }) { return .creative }

        // ── 7. Development tools by bundle ID fragments ───────────────────────────────────────
        let devBIDs = ["terminal", "iterm", "warp", "ghostty", "alacritty", "kitty", "hyper",
                       "continueddev.cursor", "zed.dev", "nova", "sublimetext", "textmate"]
        if devBIDs.contains(where: { bid.contains($0) }) { return .work }

        // ── 8. Browsers — return nil, title heuristic (step 1) handles the rest ──────────────
        if isBrowser(appName: name, bundleID: bid) { return nil }

        // ── 9. Generic app name patterns ──────────────────────────────────────────────────────
        if name.contains("code") || name.contains("studio") || name.contains("editor") || name.contains("debug") { return .work }
        if name.contains("chat") || name.contains("messenger") || name.contains("meet") { return .work }

        return nil
    }

    /// Infer category from window/page title alone — works even without a URL.
    /// This is the key heuristic for browser tabs and native apps without explicit rules.
    private func titleHeuristic(_ title: String) -> Category? {
        // ── Entertainment: Video streaming ────────────────────────────────────────────────────
        let entertainmentSuffixes = ["- youtube", "| youtube", "on youtube",
                                     "| netflix", "on netflix", "| disney+", "| disney plus",
                                     "| hulu", "| hbo max", "| max", "| prime video",
                                     "| amazon prime", "- twitch", "| twitch",
                                     "| crunchyroll", "| peacock", "| paramount+"]
        if entertainmentSuffixes.contains(where: { title.contains($0) }) {
            // Refine: YouTube tutorials/courses/lectures are learning, not entertainment
            let learningIndicators = ["tutorial", "course", "lecture", "lesson", "how to",
                                      "learn ", "learning", "programming", "coding", "bootcamp",
                                      "conference", "talk", "keynote", "introduction to",
                                      "getting started", "crash course", "full course", "explained",
                                      "walkthrough", "guide to"]
            if title.contains("- youtube") || title.contains("| youtube") {
                if learningIndicators.contains(where: { title.contains($0) }) { return .learning }
            }
            return .entertainment
        }
        // Streaming services mentioned anywhere in title
        let streamingApps = ["netflix", "disney+", "disneyplus", "hulu", "hbomax", " hbo ", "prime video", "crunchyroll"]
        if streamingApps.contains(where: { title.contains($0) }) { return .entertainment }

        // ── Learning / Educational content ────────────────────────────────────────────────────
        let learningDomains = ["- udemy", "| udemy", "- coursera", "| coursera",
                               "- pluralsight", "| pluralsight", "- skillshare",
                               "- khanacademy", "| khan academy",
                               "- freecodecamp", "| freecodecamp", "freecodecamp.org",
                               "| edx", "- edx", "| brilliant"]
        if learningDomains.contains(where: { title.contains($0) }) { return .work }

        // Documentation / MDN / official docs
        let docSuffixes = ["| mdn web docs", "- mdn web docs", "- mdn",
                           "- apple developer", "| apple developer",
                           "| swift documentation", "- swift.org",
                           "| developer.android", "- android developers",
                           "- w3schools", "| w3schools",
                           "- devdocs", "- dash"]
        if docSuffixes.contains(where: { title.contains($0) }) { return .work }

        // ── Work: Development & professional tools ────────────────────────────────────────────
        let workSuffixes = ["- github", "| github", "· github",
                            "- gitlab", "| gitlab", "· gitlab",
                            "- bitbucket", "| bitbucket",
                            "- stack overflow", "| stack overflow",
                            "- linear", "| linear",
                            "- jira", "| jira", "jira software",
                            "- notion", "| notion",
                            "- confluence", "| confluence",
                            "- trello", "| trello",
                            "- figma", "| figma",
                            "- asana", "| asana",
                            "- atlassian", "| atlassian",
                            "| postman", "| swagger",
                            "- aws", "| aws", "aws console",
                            "- azure", "| azure",
                            "- google cloud", "| google cloud",
                            "| supabase", "| vercel", "| netlify",
                            "| render", "| railway",
                            "- npm", "| npm",
                            "google docs", "google sheets", "google slides",
                            "- google docs", "- google sheets"]
        if workSuffixes.contains(where: { title.contains($0) }) { return .work }

        // Code/terminal window titles
        let codeIndicators = [".swift", ".py", ".js", ".ts", ".go", ".rs", ".java", ".kt",
                              ".cpp", ".c ", ".h ", ".rb", ".php", ".vue", ".jsx", ".tsx",
                              "xcode", "— vs code", "- vs code", "visual studio code",
                              "jetbrains", "intellij", "pycharm", "webstorm",
                              "$ ", "% ", "~ ", "zsh", "bash", "terminal"]
        if codeIndicators.contains(where: { title.contains($0) }) { return .work }

        // ── Distraction: Social media ─────────────────────────────────────────────────────────
        let distractionSuffixes = ["| twitter", "/ twitter", "on twitter",
                                   "| x.com", "/ x.com",
                                   "| instagram", "on instagram",
                                   "| facebook", "| tiktok", "on tiktok",
                                   "| reddit", "on reddit",
                                   "- reddit", "· reddit",
                                   "| linkedin",
                                   "| hacker news", "| hackernews",
                                   "| product hunt",
                                   "| pinterest", "| snapchat",
                                   "| tumblr", "| mastodon",
                                   "| threads"]
        if distractionSuffixes.contains(where: { title.contains($0) }) { return .distraction }

        // News sites in title
        let newsSuffixes = ["| the verge", "- the verge",
                            "| techcrunch", "- techcrunch",
                            "| wired", "- wired",
                            "| ars technica", "- ars technica",
                            "| engadget", "- engadget",
                            "| the guardian", "- the guardian",
                            "| bbc news", "- bbc news",
                            "| cnn", "| nytimes", "- the new york times",
                            "| bloomberg", "| reuters",
                            "| wsj", "- wsj",
                            "| mashable", "| venturebeat"]
        if newsSuffixes.contains(where: { title.contains($0) }) { return .distraction }

        // ── Chat / Communication ───────────────────────────────────────────────────────────────
        if title.contains("| slack") || title.contains("- slack") ||
           title.contains("| discord") || title.contains("- discord") ||
           title.contains("| telegram") || title.contains("| whatsapp") {
            return .work
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
    /// Called when AI categorizes an app. Learns domain rules for browsers, bundleID rules for other apps.
    func learnFromAI(appName: String, bundleID: String, category: Category, url: String? = nil) {
        guard !bundleID.isEmpty, category != .uncategorized, category != .idle else { return }

        let bid = bundleID.lowercased()

        // For browsers: learn the domain, not the bundleID.
        // Learning bundleID for a browser would poison ALL future browsing to one category.
        if isBrowserBundleID(bid) {
            if let url = url {
                let domain = RuleEngine.extractDomain(from: url)
                if !domain.isEmpty && domain != "unknown" {
                    learnDomainFromAI(domain: domain, category: category)
                }
            }
            // If no URL available, don't learn anything — can't associate a browser app with a single category
            return
        }

        // For non-browsers: don't learn if already covered by custom or default rules
        lock.lock()
        let customSnap = customRules
        let defaultSnap = defaultRules
        lock.unlock()
        if matchRules(customSnap, appName: appName, bundleID: bundleID, windowTitle: "", url: nil) != nil { return }
        if matchRules(defaultSnap, appName: appName, bundleID: bundleID, windowTitle: "", url: nil) != nil { return }

        lock.lock()
        defer { lock.unlock() }
        guard categoryCache[bid] == nil else { return }
        let rule = Rule(matchType: .bundleID, pattern: bundleID, category: category.rawValue)
        learnedRules.append(rule)
        categoryCache[bid] = category
        saveLearnedRules()
    }

    /// Learn a domain → category mapping from AI results.
    private func learnDomainFromAI(domain: String, category: Category) {
        let d = domain.lowercased()
        // Don't learn if already covered by default/custom domain rules
        let fakeURL = "https://\(d)"
        lock.lock()
        let customSnap = customRules
        let defaultSnap = defaultRules
        lock.unlock()
        if matchRules(customSnap, appName: "", bundleID: "", windowTitle: "", url: fakeURL) != nil { return }
        if matchRules(defaultSnap, appName: "", bundleID: "", windowTitle: "", url: fakeURL) != nil { return }

        lock.lock()
        defer { lock.unlock() }
        // Check if this domain already has a learned rule
        guard !learnedRules.contains(where: { $0.matchType == .domain && $0.pattern.lowercased() == d }) else { return }
        let rule = Rule(matchType: .domain, pattern: domain, category: category.rawValue)
        learnedRules.append(rule)
        saveLearnedRules()
    }

    // MARK: - Custom Rules CRUD
    var allCustomRules: [Rule] { lock.lock(); defer { lock.unlock() }; return customRules }
    var allLearnedRules: [Rule] { lock.lock(); defer { lock.unlock() }; return learnedRules }
    var defaultRuleCount: Int { lock.lock(); defer { lock.unlock() }; return defaultRules.count }
    var learnedRuleCount: Int { lock.lock(); defer { lock.unlock() }; return learnedRules.count }

    func addRule(_ rule: Rule) {
        lock.lock()
        customRules.append(rule)
        lock.unlock()
        saveCustomRules()
    }

    func removeRule(at index: Int) {
        lock.lock()
        guard index < customRules.count else { lock.unlock(); return }
        customRules.remove(at: index)
        lock.unlock()
        saveCustomRules()
    }

    func removeRule(withId id: String) {
        lock.lock()
        customRules.removeAll { $0.id == id }
        lock.unlock()
        saveCustomRules()
    }

    func clearLearnedRules() {
        lock.lock()
        defer { lock.unlock() }
        learnedRules.removeAll()
        categoryCache.removeAll()
        saveLearnedRules()
    }
}
