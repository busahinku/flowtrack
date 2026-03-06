import Foundation

// MARK: - ContentMetadata
struct ContentMetadata: Codable, Sendable {
    let siteName: String?       // "YouTube", "Reddit", "GitHub", etc.
    let contentTitle: String?   // extracted content title (video name, post title, etc.)
    let contentType: String?    // "video", "post", "repository", "search", "article", "documentation", "pr", "issue"
    let subcategory: String?    // subreddit name, repo path, search query, etc.
    let detail: String?         // extra AI context ("educational", "entertainment", etc.)
}

// MARK: - ContentMetadataExtractor
struct ContentMetadataExtractor {

    /// Extract structured metadata from a browser activity. Returns nil for non-browser or unrecognized URLs.
    static func extract(url: String?, windowTitle: String, appName: String) -> ContentMetadata? {
        guard let urlString = url, let components = URLComponents(string: urlString),
              let host = components.host?.lowercased() else {
            return nil
        }
        let domain = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        let path = components.path
        let title = windowTitle

        if domain.hasSuffix("youtube.com") || domain == "youtu.be" {
            return parseYouTube(components: components, title: title, domain: domain)
        }
        if domain.hasSuffix("reddit.com") {
            return parseReddit(path: path, title: title)
        }
        if domain == "github.com" {
            return parseGitHub(path: path, title: title)
        }
        if domain.hasSuffix("stackoverflow.com") || domain.hasSuffix("stackexchange.com") {
            return parseStackOverflow(title: title)
        }
        if domain == "twitter.com" || domain == "x.com" {
            return parseTwitter(path: path, title: title)
        }
        if domain.hasSuffix("google.com") && path.hasPrefix("/search") {
            return parseGoogleSearch(components: components)
        }
        if domain.hasSuffix("linkedin.com") {
            return parseLinkedIn(path: path, title: title)
        }
        if domain.hasSuffix("medium.com") || domain.hasSuffix("substack.com") {
            return parseMediumSubstack(domain: domain, title: title)
        }
        if domain.hasPrefix("docs.") || domain == "developer.apple.com"
            || domain.hasSuffix("mozilla.org") && path.contains("/docs/") {
            return parseDocs(domain: domain, title: title)
        }
        if domain == "news.ycombinator.com" {
            return parseHackerNews(title: title)
        }
        if isNewsSite(domain) {
            return parseNews(domain: domain, title: title)
        }

        return nil
    }

    // MARK: - Site Parsers

    private static func parseYouTube(components: URLComponents, title: String, domain: String) -> ContentMetadata {
        // Extract video title from window title (format: "Video Title - YouTube")
        let videoTitle = title.replacingOccurrences(of: " - YouTube", with: "")
            .replacingOccurrences(of: " | YouTube", with: "")

        let videoID = components.queryItems?.first(where: { $0.name == "v" })?.value

        let isEducational = isEducationalContent(videoTitle)
        let detail = isEducational ? "educational" : "entertainment"

        let contentType: String
        if components.path.hasPrefix("/results") || components.path.hasPrefix("/search") {
            contentType = "search"
        } else if videoID != nil || domain == "youtu.be" {
            contentType = "video"
        } else if components.path.hasPrefix("/@") || components.path.hasPrefix("/channel") {
            contentType = "channel"
        } else {
            contentType = "browse"
        }

        return ContentMetadata(
            siteName: "YouTube",
            contentTitle: videoTitle.isEmpty ? nil : videoTitle,
            contentType: contentType,
            subcategory: videoID,
            detail: detail
        )
    }

    private static func parseReddit(path: String, title: String) -> ContentMetadata {
        // Extract subreddit from path: /r/subreddit/...
        let pathComponents = path.split(separator: "/")
        var subreddit: String? = nil
        if pathComponents.count >= 2 && pathComponents[0] == "r" {
            subreddit = String(pathComponents[1])
        }

        let postTitle = title.replacingOccurrences(of: " : r/\\w+", with: "", options: .regularExpression)
            .replacingOccurrences(of: " - Reddit", with: "")

        let isWorkSubreddit = subreddit.map { isWorkRedditSubreddit($0) } ?? false
        let detail = isWorkSubreddit ? "work-related" : "distraction"

        let contentType: String
        if pathComponents.count >= 4 && pathComponents[2] == "comments" {
            contentType = "post"
        } else if subreddit != nil {
            contentType = "subreddit"
        } else {
            contentType = "feed"
        }

        return ContentMetadata(
            siteName: "Reddit",
            contentTitle: postTitle.isEmpty ? nil : postTitle,
            contentType: contentType,
            subcategory: subreddit,
            detail: detail
        )
    }

    private static func parseGitHub(path: String, title: String) -> ContentMetadata {
        let pathComponents = path.split(separator: "/").map(String.init)

        var repoPath: String? = nil
        if pathComponents.count >= 2 {
            repoPath = "\(pathComponents[0])/\(pathComponents[1])"
        }

        let contentType: String
        if pathComponents.count >= 3 {
            switch pathComponents[2] {
            case "pull", "pulls": contentType = "pr"
            case "issues": contentType = "issue"
            case "actions": contentType = "actions"
            case "blob", "tree": contentType = "code"
            case "wiki": contentType = "documentation"
            case "settings": contentType = "settings"
            default: contentType = "repository"
            }
        } else if pathComponents.count == 2 {
            contentType = "repository"
        } else {
            contentType = "feed"
        }

        let pageTitle = title.replacingOccurrences(of: " . GitHub", with: "")
            .replacingOccurrences(of: " - GitHub", with: "")

        return ContentMetadata(
            siteName: "GitHub",
            contentTitle: pageTitle.isEmpty ? nil : pageTitle,
            contentType: contentType,
            subcategory: repoPath,
            detail: "work"
        )
    }

    private static func parseStackOverflow(title: String) -> ContentMetadata {
        let questionTitle = title.replacingOccurrences(of: " - Stack Overflow", with: "")
            .replacingOccurrences(of: " - Stack Exchange", with: "")

        return ContentMetadata(
            siteName: "Stack Overflow",
            contentTitle: questionTitle.isEmpty ? nil : questionTitle,
            contentType: "question",
            subcategory: nil,
            detail: "work"
        )
    }

    private static func parseTwitter(path: String, title: String) -> ContentMetadata {
        let pathComponents = path.split(separator: "/")

        let contentType: String
        if path == "/" || path == "/home" {
            contentType = "feed"
        } else if pathComponents.count >= 3 && pathComponents[1] == "status" {
            contentType = "post"
        } else if pathComponents.count == 1 {
            contentType = "profile"
        } else if path.hasPrefix("/search") {
            contentType = "search"
        } else {
            contentType = "browse"
        }

        return ContentMetadata(
            siteName: "Twitter/X",
            contentTitle: nil,
            contentType: contentType,
            subcategory: nil,
            detail: "distraction"
        )
    }

    private static func parseGoogleSearch(components: URLComponents) -> ContentMetadata {
        let query = components.queryItems?.first(where: { $0.name == "q" })?.value

        return ContentMetadata(
            siteName: "Google",
            contentTitle: query.map { "Search: \($0)" },
            contentType: "search",
            subcategory: query,
            detail: nil
        )
    }

    private static func parseLinkedIn(path: String, title: String) -> ContentMetadata {
        let contentType: String
        let detail: String
        if path.hasPrefix("/jobs") {
            contentType = "jobs"
            detail = "work"
        } else if path.hasPrefix("/messaging") {
            contentType = "messaging"
            detail = "work"
        } else if path.hasPrefix("/in/") {
            contentType = "profile"
            detail = "work"
        } else if path.hasPrefix("/feed") || path == "/" {
            contentType = "feed"
            detail = "distraction"
        } else {
            contentType = "browse"
            detail = "distraction"
        }

        return ContentMetadata(
            siteName: "LinkedIn",
            contentTitle: nil,
            contentType: contentType,
            subcategory: nil,
            detail: detail
        )
    }

    private static func parseMediumSubstack(domain: String, title: String) -> ContentMetadata {
        let siteName = domain.hasSuffix("medium.com") ? "Medium" : "Substack"
        let articleTitle = title.replacingOccurrences(of: " | Medium", with: "")
            .replacingOccurrences(of: " - Medium", with: "")

        return ContentMetadata(
            siteName: siteName,
            contentTitle: articleTitle.isEmpty ? nil : articleTitle,
            contentType: "article",
            subcategory: nil,
            detail: nil
        )
    }

    private static func parseDocs(domain: String, title: String) -> ContentMetadata {
        return ContentMetadata(
            siteName: "Documentation",
            contentTitle: title.isEmpty ? nil : title,
            contentType: "documentation",
            subcategory: domain,
            detail: "work"
        )
    }

    private static func parseHackerNews(title: String) -> ContentMetadata {
        let postTitle = title.replacingOccurrences(of: " | Hacker News", with: "")

        return ContentMetadata(
            siteName: "Hacker News",
            contentTitle: postTitle.isEmpty ? nil : postTitle,
            contentType: "post",
            subcategory: nil,
            detail: "distraction"
        )
    }

    private static func parseNews(domain: String, title: String) -> ContentMetadata {
        return ContentMetadata(
            siteName: newsSiteName(domain),
            contentTitle: title.isEmpty ? nil : title,
            contentType: "article",
            subcategory: nil,
            detail: "distraction"
        )
    }

    // MARK: - Helpers

    private static func isEducationalContent(_ title: String) -> Bool {
        let t = title.lowercased()
        let indicators = [
            "tutorial", "course", "lecture", "lesson", "how to",
            "learn ", "learning", "programming", "coding", "bootcamp",
            "conference", "talk", "keynote", "introduction to",
            "getting started", "crash course", "full course", "explained",
            "walkthrough", "guide to", "build a", "building", "develop",
            "implement", "architecture", "design pattern", "algorithm",
            "data structure", "system design", "interview prep",
            "documentation", "deep dive", "masterclass"
        ]
        return indicators.contains(where: { t.contains($0) })
    }

    private static func isWorkRedditSubreddit(_ subreddit: String) -> Bool {
        let workSubs: Set<String> = [
            "programming", "swift", "swiftui", "webdev", "javascript",
            "typescript", "python", "rust", "golang", "java", "kotlin",
            "csharp", "dotnet", "cpp", "haskell", "elixir",
            "devops", "aws", "azure", "googlecloud", "docker", "kubernetes",
            "linux", "macos", "ios", "iosprogramming", "androiddev",
            "reactjs", "vuejs", "angular", "nextjs", "svelte",
            "node", "django", "flask", "rails",
            "machinelearning", "datascience", "artificial",
            "compsci", "learnprogramming", "askprogramming",
            "experienceddevs", "cscareerquestions", "softwareengineering",
            "startups", "entrepreneur", "sideproject",
            "uxdesign", "userexperience", "design", "figma",
            "math", "physics", "science", "academia"
        ]
        return workSubs.contains(subreddit.lowercased())
    }

    private static let newsDomains: Set<String> = [
        "cnn.com", "bbc.com", "bbc.co.uk", "nytimes.com",
        "theverge.com", "techcrunch.com", "wired.com",
        "arstechnica.com", "engadget.com", "mashable.com",
        "theguardian.com", "reuters.com", "bloomberg.com",
        "wsj.com", "washingtonpost.com", "apnews.com",
        "venturebeat.com", "zdnet.com", "cnet.com"
    ]

    private static func isNewsSite(_ domain: String) -> Bool {
        newsDomains.contains(where: { domain.hasSuffix($0) })
    }

    private static func newsSiteName(_ domain: String) -> String {
        let nameMap: [String: String] = [
            "cnn.com": "CNN", "bbc.com": "BBC", "bbc.co.uk": "BBC",
            "nytimes.com": "NYTimes", "theverge.com": "The Verge",
            "techcrunch.com": "TechCrunch", "wired.com": "Wired",
            "arstechnica.com": "Ars Technica", "theguardian.com": "The Guardian",
            "reuters.com": "Reuters", "bloomberg.com": "Bloomberg",
            "wsj.com": "WSJ", "washingtonpost.com": "Washington Post",
        ]
        for (key, name) in nameMap {
            if domain.hasSuffix(key) { return name }
        }
        return "News"
    }

    // MARK: - Native App Metadata Extraction

    /// Extract structured metadata from native (non-browser) app window titles.
    /// Returns nil if the app is unrecognized or the title doesn't yield useful structure.
    static func extractNativeApp(windowTitle: String, appName: String, bundleID: String) -> ContentMetadata? {
        let title = windowTitle.trimmingCharacters(in: .whitespaces)
        let bundle = bundleID.lowercased()
        let app = appName.lowercased()
        guard !title.isEmpty else { return nil }

        // Xcode: "AppState.swift — FlowTrack" or "FlowTrack — Running"
        if bundle.contains("com.apple.dt.xcode") || app.contains("xcode") {
            return parseXcode(title: title)
        }

        // VS Code / Cursor / Zed / Windsurf / other editors: "file.ext — project"
        if bundle.contains("com.microsoft.vscode") || app.contains("code") || app.contains("cursor") || app.contains("zed") || app.contains("windsurf") || bundle.contains("zed.dev") {
            return parseVSCodeStyle(title: title, appName: appName)
        }

        // JetBrains IDEs (IntelliJ, WebStorm, PyCharm, GoLand, etc.)
        if bundle.contains("com.jetbrains") || app.contains("intellij") || app.contains("webstorm") || app.contains("pycharm") || app.contains("goland") || app.contains("android studio") {
            return parseJetBrains(title: title, appName: appName)
        }

        // Terminal emulators: Terminal, iTerm2, Warp, Alacritty
        if bundle == "com.apple.terminal" || bundle.contains("com.googlecode.iterm2") || bundle.contains("dev.warp") || app.contains("terminal") || app.contains("iterm") || app.contains("warp") {
            return parseTerminal(title: title, appName: appName)
        }

        // Figma
        if bundle.contains("com.figma") || app.contains("figma") {
            return parseDesignApp(title: title, appName: "Figma", suffix: "Figma")
        }

        // Sketch
        if bundle.contains("com.bohemiancoding.sketch") || app.contains("sketch") {
            return parseDesignApp(title: title, appName: "Sketch", suffix: "Sketch")
        }

        // Slack
        if bundle.contains("com.tinyspeck.slackmacgap") || app.contains("slack") {
            return parseSlack(title: title)
        }

        // Discord
        if bundle.contains("com.hnc.discord") || app.contains("discord") {
            return parseDiscord(title: title)
        }

        // Notion
        if bundle.contains("notion") || app.contains("notion") {
            return parseNotionStyle(title: title, siteName: "Notion", suffix: "Notion")
        }

        // Obsidian
        if bundle.contains("md.obsidian") || app.contains("obsidian") {
            return parseNotionStyle(title: title, siteName: "Obsidian", suffix: "Obsidian")
        }

        // Linear
        if bundle.contains("linear") || app.contains("linear") {
            return parseLinearApp(title: title)
        }

        // Zoom
        if bundle.contains("us.zoom") || app.contains("zoom") {
            return parseVideoCall(title: title, appName: "Zoom")
        }

        // Microsoft Teams
        if bundle.contains("com.microsoft.teams") || app.contains("teams") {
            return parseVideoCall(title: title, appName: "Microsoft Teams")
        }

        // Mail / Apple Mail
        if bundle == "com.apple.mail" || app == "mail" {
            return parseMail(title: title)
        }

        // Outlook
        if bundle.contains("com.microsoft.outlook") || app.contains("outlook") {
            return parseMail(title: title)
        }

        // Pages / Word
        if bundle.contains("com.apple.iwork.pages") || bundle.contains("com.microsoft.word") || app == "pages" || app.contains("word") {
            let filename = cleanDocumentTitle(title, suffixes: ["Pages", "Word", "Microsoft Word"])
            return ContentMetadata(siteName: "Document", contentTitle: filename.isEmpty ? title : filename, contentType: "document", subcategory: nil, detail: "work")
        }

        // Numbers / Excel
        if bundle.contains("com.apple.iwork.numbers") || bundle.contains("com.microsoft.excel") || app == "numbers" || app.contains("excel") {
            let filename = cleanDocumentTitle(title, suffixes: ["Numbers", "Excel", "Microsoft Excel"])
            return ContentMetadata(siteName: "Spreadsheet", contentTitle: filename.isEmpty ? title : filename, contentType: "spreadsheet", subcategory: nil, detail: "work")
        }

        // Keynote / PowerPoint
        if bundle.contains("com.apple.iwork.keynote") || bundle.contains("com.microsoft.powerpoint") || app == "keynote" || app.contains("powerpoint") {
            let filename = cleanDocumentTitle(title, suffixes: ["Keynote", "PowerPoint", "Microsoft PowerPoint"])
            return ContentMetadata(siteName: "Presentation", contentTitle: filename.isEmpty ? title : filename, contentType: "presentation", subcategory: nil, detail: "work")
        }

        // iOS Simulator
        if bundle.contains("com.apple.iphonesimulator") || app.contains("simulator") {
            return ContentMetadata(siteName: "Simulator", contentTitle: title, contentType: "development", subcategory: nil, detail: "work")
        }

        // Spotify / Music
        if bundle.contains("com.spotify") || app.contains("spotify") || bundle == "com.apple.music" || app == "music" {
            let trackInfo = title.contains(" – ") ? title : title
            return ContentMetadata(siteName: app.contains("spotify") ? "Spotify" : "Music", contentTitle: trackInfo, contentType: "music", subcategory: nil, detail: "entertainment")
        }

        return nil
    }

    // MARK: - Native App Parsers

    private static func parseXcode(title: String) -> ContentMetadata {
        // Patterns: "Filename.swift — ProjectName", "ProjectName — Running on iPhone"
        let parts = title.components(separatedBy: " — ")
        let filename = parts.first?.trimmingCharacters(in: .whitespaces)
        let project = parts.count >= 2 ? parts[1].trimmingCharacters(in: .whitespaces) : nil

        // Detect if running/debugging
        let isRunning = title.lowercased().contains("running") || title.lowercased().contains("building")

        // Guess language from file extension
        let lang: String?
        if let f = filename {
            if f.hasSuffix(".swift") { lang = "Swift" }
            else if f.hasSuffix(".m") || f.hasSuffix(".mm") { lang = "Objective-C" }
            else if f.hasSuffix(".c") || f.hasSuffix(".cpp") { lang = "C/C++" }
            else { lang = nil }
        } else { lang = nil }

        return ContentMetadata(
            siteName: "Xcode",
            contentTitle: filename,
            contentType: isRunning ? "debugging" : "code_editor",
            subcategory: project ?? lang,
            detail: "work"
        )
    }

    private static func parseVSCodeStyle(title: String, appName: String) -> ContentMetadata {
        // Patterns: "file.ts — projectName", "● file.ts — projectName" (unsaved indicator)
        let cleaned = title.hasPrefix("●") ? String(title.dropFirst(1)).trimmingCharacters(in: .whitespaces) : title
        let parts = cleaned.components(separatedBy: " — ")
        let filename = parts.first?.trimmingCharacters(in: .whitespaces)
        let project = parts.count >= 2 ? parts[1].trimmingCharacters(in: .whitespaces) : nil

        return ContentMetadata(
            siteName: appName.isEmpty ? "VS Code" : appName,
            contentTitle: filename,
            contentType: "code_editor",
            subcategory: project,
            detail: "work"
        )
    }

    private static func parseJetBrains(title: String, appName: String) -> ContentMetadata {
        // Patterns: "filename.kt [Project] – IntelliJ IDEA"
        // Or just: "Project – IntelliJ IDEA"
        let parts = title.components(separatedBy: " – ")
        let fileAndProject = parts.first?.trimmingCharacters(in: .whitespaces) ?? title

        var filename: String? = nil
        var project: String? = nil
        // "[ProjectName]" pattern
        if let bracketRange = fileAndProject.range(of: #"\[.+\]"#, options: .regularExpression) {
            project = String(fileAndProject[bracketRange]).trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            filename = fileAndProject.replacingCharacters(in: bracketRange, with: "").trimmingCharacters(in: .whitespaces)
        } else {
            filename = fileAndProject
        }

        return ContentMetadata(
            siteName: appName.isEmpty ? "JetBrains IDE" : appName,
            contentTitle: filename.flatMap { $0.isEmpty ? nil : $0 },
            contentType: "code_editor",
            subcategory: project,
            detail: "work"
        )
    }

    private static func parseTerminal(title: String, appName: String) -> ContentMetadata {
        // Common patterns: "bash — ~/Projects/flowtrack", "vim AppState.swift", "npm run dev"
        var command: String? = nil
        var directory: String? = nil

        if title.contains(" — ") {
            let parts = title.components(separatedBy: " — ")
            command = parts.first?.trimmingCharacters(in: .whitespaces)
            directory = parts.count >= 2 ? parts[1].trimmingCharacters(in: .whitespaces) : nil
        } else if title.contains(":") {
            // "user@host:/path/to/dir"
            let idx = title.lastIndex(of: ":") ?? title.endIndex
            directory = String(title[title.index(after: idx)...]).trimmingCharacters(in: .whitespaces)
        } else {
            command = title
        }

        return ContentMetadata(
            siteName: appName.isEmpty ? "Terminal" : appName,
            contentTitle: command,
            contentType: "terminal",
            subcategory: directory,
            detail: "work"
        )
    }

    private static func parseDesignApp(title: String, appName: String, suffix: String) -> ContentMetadata {
        let document = cleanDocumentTitle(title, suffixes: [suffix, "– \(suffix)", "— \(suffix)"])
        return ContentMetadata(
            siteName: appName,
            contentTitle: document.isEmpty ? title : document,
            contentType: "design",
            subcategory: nil,
            detail: "work"
        )
    }

    private static func parseSlack(title: String) -> ContentMetadata {
        // Patterns: "#channel | Workspace", "Thread in #channel | Workspace", "Direct Message | Name"
        var channel: String? = nil
        var workspace: String? = nil

        let pipeIndex = title.lastIndex(of: "|")
        if let idx = pipeIndex {
            workspace = String(title[title.index(after: idx)...]).trimmingCharacters(in: .whitespaces)
            let left = String(title[..<idx]).trimmingCharacters(in: .whitespaces)
            if left.contains("#") {
                // Extract channel name
                if let hashIdx = left.lastIndex(of: "#") {
                    channel = "#" + String(left[left.index(after: hashIdx)...]).trimmingCharacters(in: .whitespaces)
                }
            } else {
                channel = left
            }
        }

        let contentType: String
        if title.hasPrefix("Thread") { contentType = "thread" }
        else if title.lowercased().contains("direct message") || title.lowercased().contains("dm") { contentType = "direct_message" }
        else { contentType = "channel" }

        return ContentMetadata(
            siteName: "Slack",
            contentTitle: channel,
            contentType: contentType,
            subcategory: workspace,
            detail: "work"
        )
    }

    private static func parseDiscord(title: String) -> ContentMetadata {
        // Patterns: "#general | ServerName", "@ Username | Discord"
        var channel: String? = nil
        var server: String? = nil

        if let pipeIdx = title.lastIndex(of: "|") {
            server = String(title[title.index(after: pipeIdx)...]).trimmingCharacters(in: .whitespaces)
            let left = String(title[..<pipeIdx]).trimmingCharacters(in: .whitespaces)
            channel = left.isEmpty ? nil : left
        }

        return ContentMetadata(
            siteName: "Discord",
            contentTitle: channel,
            contentType: "messaging",
            subcategory: server,
            detail: nil
        )
    }

    private static func parseNotionStyle(title: String, siteName: String, suffix: String) -> ContentMetadata {
        let pageTitle = cleanDocumentTitle(title, suffixes: [suffix, "– \(suffix)", "— \(suffix)"])
        return ContentMetadata(
            siteName: siteName,
            contentTitle: pageTitle.isEmpty ? title : pageTitle,
            contentType: "document",
            subcategory: nil,
            detail: "work"
        )
    }

    private static func parseLinearApp(title: String) -> ContentMetadata {
        // Detect ticket IDs like "FT-123" or "ENG-456"
        let ticketPattern = #"([A-Z]{2,}-\d+)"#
        let ticketID = title.range(of: ticketPattern, options: .regularExpression)
            .map { String(title[$0]) }
        return ContentMetadata(
            siteName: "Linear",
            contentTitle: title,
            contentType: "issue_tracker",
            subcategory: ticketID,
            detail: "work"
        )
    }

    private static func parseVideoCall(title: String, appName: String) -> ContentMetadata {
        let meetingName = cleanDocumentTitle(title, suffixes: [appName, "Zoom", "Microsoft Teams", "Google Meet"])
        return ContentMetadata(
            siteName: appName,
            contentTitle: meetingName.isEmpty ? nil : meetingName,
            contentType: "video_call",
            subcategory: nil,
            detail: "work"
        )
    }

    private static func parseMail(title: String) -> ContentMetadata {
        // Mail titles are often the subject line or "Inbox" etc.
        let cleaned = cleanDocumentTitle(title, suffixes: ["Mail", "Outlook", "Microsoft Outlook"])
        let isInbox = cleaned.lowercased().contains("inbox") || cleaned.isEmpty
        return ContentMetadata(
            siteName: "Mail",
            contentTitle: isInbox ? nil : cleaned,
            contentType: isInbox ? "inbox" : "email",
            subcategory: nil,
            detail: "work"
        )
    }

    /// Strip common app name suffixes from a window title to get the document/content name.
    private static func cleanDocumentTitle(_ title: String, suffixes: [String]) -> String {
        var result = title
        for suffix in suffixes {
            for sep in [" – ", " — ", " - ", " | "] {
                let pattern = sep + suffix
                if result.hasSuffix(pattern) {
                    result = String(result.dropLast(pattern.count)).trimmingCharacters(in: .whitespaces)
                    break
                }
            }
        }
        return result
    }
}
