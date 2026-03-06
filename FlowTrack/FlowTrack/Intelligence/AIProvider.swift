import Foundation
import OSLog

private let aiLogger = Logger(subsystem: "com.flowtrack", category: "AI")

// MARK: - AIError
enum AIError: Error, LocalizedError {
    case noAPIKey
    case networkError(String)
    case invalidResponse(String)
    case modelNotFound(String)
    case rateLimited
    case cliNotFound(String)
    case cliError(String)

    var errorDescription: String? {
        switch self {
        case .noAPIKey: return "No API key configured"
        case .networkError(let msg): return "Network error: \(msg)"
        case .invalidResponse(let msg): return "Invalid response: \(msg)"
        case .modelNotFound(let model): return "Model not found (404). Check model name: \(model)"
        case .rateLimited: return "Rate limited — try again later"
        case .cliNotFound(let cmd): return "CLI not found: \(cmd)"
        case .cliError(let msg): return "CLI error: \(msg)"
        }
    }
}

// MARK: - Batch Categorization Item
struct BatchCategorizeItem: Sendable {
    let index: Int
    let appName: String
    let bundleID: String
    let windowTitle: String
    let url: String?
}

// MARK: - Chat Turn
struct ChatTurn: Sendable {
    let role: String   // "user" or "assistant"
    let content: String
}

// MARK: - AIProvider Protocol
protocol AIProvider: Sendable {
    func categorize(appName: String, bundleID: String, windowTitle: String, url: String?) async throws -> Category
    func categorizeBatch(items: [BatchCategorizeItem]) async throws -> [Int: Category]
    func summarize(activities: [ActivitySummary]) async throws -> String
    func generateTitle(activities: [ActivitySummary], category: Category) async throws -> String
    func checkHealth() async throws -> Bool
    /// Multi-turn chat with a system prompt providing activity context.
    func chat(messages: [ChatTurn], systemPrompt: String) async throws -> String
}

extension AIProvider {
    func summarize(activities: [ActivitySummary]) async throws -> String {
        throw AIError.invalidResponse("Not implemented")
    }
    func generateTitle(activities: [ActivitySummary], category: Category) async throws -> String {
        throw AIError.invalidResponse("Not implemented")
    }
    func checkHealth() async throws -> Bool { true }

    /// Default chat: flatten history + system prompt and forward to `categorize`-style call.
    /// Providers that support native multi-turn chat should override this method.
    func chat(messages: [ChatTurn], systemPrompt: String) async throws -> String {
        guard let last = messages.last(where: { $0.role == "user" }) else {
            throw AIError.invalidResponse("No user message in chat history")
        }
        // Fall back to a single-shot prompt combining system context and the last user message.
        let combined = systemPrompt.isEmpty ? last.content : systemPrompt + "\n\n---\n" + last.content
        return try await categorize(appName: "chat", bundleID: "chat", windowTitle: combined, url: nil).rawValue
    }

    // Default: fall back to individual calls
    func categorizeBatch(items: [BatchCategorizeItem]) async throws -> [Int: Category] {
        var results: [Int: Category] = [:]
        for item in items {
            let cat = try await categorize(appName: item.appName, bundleID: item.bundleID,
                                           windowTitle: item.windowTitle, url: item.url)
            results[item.index] = cat
        }
        return results
    }
}

// MARK: - AIProviderFactory
@MainActor
struct AIProviderFactory {
    static func create(for type: AIProviderType, model: String? = nil) -> any AIProvider {
        let modelName = model ?? AppSettings.shared.modelName(for: type)
        switch type {
        case .claudeCLI: return CLIProvider(command: "claude", model: modelName)
        case .chatgptCLI: return CLIProvider(command: "codex", model: modelName)
        case .claude: return ClaudeProvider(model: modelName)
        case .openai: return OpenAIProvider(model: modelName)
        case .gemini: return GeminiProvider(model: modelName)
        case .ollama: return OllamaProvider(model: modelName)
        case .lmstudio: return LMStudioProvider(model: modelName)
        }
    }
}

// MARK: - AIPromptBuilder
struct AIPromptBuilder {
    // MARK: - URL Sanitization
    /// Strips URL to domain only before sending to external AI providers (avoids leaking tokens/query params).
    static func domainOnly(from urlString: String) -> String {
        guard let components = URLComponents(string: urlString), let host = components.host else {
            return "unknown"  // never leak full URL with tokens/params to AI
        }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    static func categorizationPrompt(appName: String, bundleID: String, windowTitle: String, url: String?) -> String {
        var prompt = """
        You are a productivity tracker AI. Categorize this computer activity into EXACTLY one category.

        Categories and what they mean:
        - Work: coding, writing code, terminal/shell, professional tools, databases, APIs, project management (Jira/Linear/Notion for work), documentation, business communication (Slack, Teams, email), cloud consoles, deployment tools
        - Distraction: social media (LinkedIn, Twitter, Instagram, Reddit, Facebook), news sites (HackerNews, TechCrunch, CNN, BBC), forums, random browsing, entertainment browsing
        - Entertainment: video streaming (Netflix, YouTube for fun, Disney+, Twitch), music (Spotify, Apple Music), gaming, podcasts
        - Personal: banking, shopping, maps, travel, food ordering, personal email, health apps, personal errands
        - Creative: design tools (Figma, Sketch, Photoshop, Illustrator), video editing, music production, art creation
        - Learning: educational courses (Coursera, Udemy, Khan Academy), studying, reading documentation to learn, tutorials
        - Uncategorized: cannot determine from available information

        Activity to categorize:
        App: \(appName) (\(bundleID))
        Window Title: \(windowTitle)
        """
        if let url = url { prompt += "\nURL/Domain: \(domainOnly(from: url))" }
        prompt += "\n\nRespond with ONLY the category name, nothing else."
        return prompt
    }

    static func batchCategorizationPrompt(items: [BatchCategorizeItem]) -> String {
        var prompt = """
        You are a productivity tracker AI. Categorize each computer activity into EXACTLY one category.

        Categories:
        - Work: coding, professional tools, project management, business communication, cloud/deployment
        - Distraction: social media, news sites, forums, random browsing
        - Entertainment: video/music streaming, gaming
        - Personal: banking, shopping, maps, food delivery, personal errands
        - Creative: design, video editing, music production, art tools
        - Learning: educational courses, studying, tutorials
        - Uncategorized: cannot determine

        Activities to categorize:
        """
        for item in items {
            var line = "\n\(item.index). App:\(item.appName) | Title:\(item.windowTitle)"
            if let url = item.url { line += " | Domain:\(domainOnly(from: url))" }
            prompt += line
        }
        prompt += "\n\nRespond with ONLY numbered categories, one per line: \"1. CategoryName\""
        return prompt
    }

    static func parseBatchCategories(_ text: String, count: Int) -> [Int: Category] {
        var results: [Int: Category] = [:]
        let lines = text.components(separatedBy: .newlines)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            // Match patterns like "1. Work" or "1: Work"
            let parts = trimmed.split(separator: ".", maxSplits: 1)
            if parts.count == 2, let idx = Int(parts[0].trimmingCharacters(in: .whitespaces)) {
                let catText = String(parts[1]).trimmingCharacters(in: .whitespaces)
                if let cat = parseCategory(catText) {
                    results[idx] = cat
                }
            } else {
                // Try colon separator
                let colonParts = trimmed.split(separator: ":", maxSplits: 1)
                if colonParts.count == 2, let idx = Int(colonParts[0].trimmingCharacters(in: .whitespaces)) {
                    let catText = String(colonParts[1]).trimmingCharacters(in: .whitespaces)
                    if let cat = parseCategory(catText) {
                        results[idx] = cat
                    }
                }
            }
        }
        return results
    }

    static func titlePrompt(activities: [ActivitySummary], category: Category) -> String {
        let apps = activities.prefix(10).map { "\($0.appName): \($0.title)" }.joined(separator: "\n")
        return """
        Generate a short title (5-10 words) for this time block.
        Category: \(category.rawValue)
        Apps:
        \(apps)

        Be specific. Don't use "Various", "Multiple", "Session".
        Respond with ONLY the title.
        """
    }

    static func summaryPrompt(activities: [ActivitySummary]) -> String {
        let apps = activities.prefix(15).map {
            var line = "\($0.appName) (\(Int($0.duration))s): \($0.title)"
            if let url = $0.url { line += " [\(domainOnly(from: url))]" }
            return line
        }.joined(separator: "\n")
        return """
        Summarize this session in 2-3 sentences. Be specific about tasks and apps.
        Activities:
        \(apps)

        Respond with ONLY the summary.
        """
    }

    static func parseCategory(_ text: String) -> Category? {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: ".", with: "")
        let allCats = CategoryManager.shared.allCategories
        if let match = allCats.first(where: { $0.name.lowercased() == cleaned.lowercased() }) {
            return Category(rawValue: match.name)
        }
        if let match = allCats.first(where: { cleaned.lowercased().contains($0.name.lowercased()) }) {
            return Category(rawValue: match.name)
        }
        return nil
    }
}

// MARK: - AIHTTPHelper
struct AIHTTPHelper {
    static func sendRequest(url: URL, headers: [String: String], body: Data) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.timeoutInterval = 30

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AIError.networkError("Invalid response type")
        }

        if httpResponse.statusCode == 404 {
            let bodyStr = String(data: data.prefix(500), encoding: .utf8) ?? "(non-utf8)"
            aiLogger.error("404 from \(url.host ?? "", privacy: .public): \(bodyStr, privacy: .private)")
            throw AIError.modelNotFound(url.absoluteString)
        }

        if httpResponse.statusCode == 429 {
            throw AIError.rateLimited
        }

        if httpResponse.statusCode >= 400 {
            let bodyStr = String(data: data.prefix(500), encoding: .utf8) ?? "(non-utf8)"
            aiLogger.error("\(httpResponse.statusCode) from \(url.host ?? "", privacy: .public): \(bodyStr, privacy: .private)")
            throw AIError.networkError("HTTP \(httpResponse.statusCode): \(String(bodyStr.prefix(200)))")
        }

        return (data, httpResponse)
    }
}
