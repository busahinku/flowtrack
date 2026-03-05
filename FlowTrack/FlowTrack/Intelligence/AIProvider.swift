import Foundation

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

// MARK: - AIProvider Protocol
protocol AIProvider: Sendable {
    func categorize(appName: String, bundleID: String, windowTitle: String, url: String?) async throws -> Category
    func categorizeBatch(items: [BatchCategorizeItem]) async throws -> [Int: Category]
    func summarize(activities: [ActivitySummary]) async throws -> String
    func generateTitle(activities: [ActivitySummary], category: Category) async throws -> String
    func checkHealth() async throws -> Bool
}

extension AIProvider {
    func summarize(activities: [ActivitySummary]) async throws -> String {
        throw AIError.invalidResponse("Not implemented")
    }
    func generateTitle(activities: [ActivitySummary], category: Category) async throws -> String {
        throw AIError.invalidResponse("Not implemented")
    }
    func checkHealth() async throws -> Bool { true }

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
    static func categorizationPrompt(appName: String, bundleID: String, windowTitle: String, url: String?) -> String {
        let categories = CategoryManager.shared.allCategories
        let catList = categories.map { cat in
            "\(cat.name) (\(cat.isProductive ? "productive" : "non-productive"))"
        }.joined(separator: ", ")
        var prompt = """
        Categorize this app activity. Categories: \(catList)

        App: \(appName) (\(bundleID))
        Title: \(windowTitle)
        """
        if let url = url { prompt += "\nURL: \(url)" }
        prompt += "\n\nRespond with ONLY the category name."
        return prompt
    }

    static func batchCategorizationPrompt(items: [BatchCategorizeItem]) -> String {
        let categories = CategoryManager.shared.allCategories
        let catList = categories.map { cat in
            "\(cat.name) (\(cat.isProductive ? "productive" : "non-productive"))"
        }.joined(separator: ", ")

        var prompt = """
        Categorize each activity. Categories: \(catList)

        Activities:
        """
        for item in items {
            var line = "\n\(item.index). \(item.appName) (\(item.bundleID)) — \(item.windowTitle)"
            if let url = item.url { line += " [\(url)]" }
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
            if let url = $0.url { line += " [\(url)]" }
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
            print("[AI HTTP] 404 from \(url.host ?? ""): \(bodyStr)")
            throw AIError.modelNotFound(url.absoluteString)
        }

        if httpResponse.statusCode == 429 {
            throw AIError.rateLimited
        }

        if httpResponse.statusCode >= 400 {
            let bodyStr = String(data: data.prefix(500), encoding: .utf8) ?? "(non-utf8)"
            print("[AI HTTP] \(httpResponse.statusCode) from \(url.host ?? ""): \(bodyStr)")
            throw AIError.networkError("HTTP \(httpResponse.statusCode): \(String(bodyStr.prefix(200)))")
        }

        return (data, httpResponse)
    }
}
