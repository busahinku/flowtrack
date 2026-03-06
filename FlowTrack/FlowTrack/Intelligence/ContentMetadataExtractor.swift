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
}
