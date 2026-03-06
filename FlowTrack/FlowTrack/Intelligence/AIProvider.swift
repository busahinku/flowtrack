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
    /// Analyze a 30-minute activity window and return structured segments.
    func analyzeActivityWindow(activities: [ActivityRecord], windowStart: Date, windowEnd: Date) async throws -> [WindowSegmentResult]
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

    /// Default window analysis: sends prompt to AI via chat, parses JSON response.
    /// Falls back to a single segment with dominant category on failure.
    func analyzeActivityWindow(activities: [ActivityRecord], windowStart: Date, windowEnd: Date) async throws -> [WindowSegmentResult] {
        guard !activities.isEmpty else { return [] }
        let prompt = AIPromptBuilder.windowAnalysisPrompt(activities: activities, windowStart: windowStart, windowEnd: windowEnd)
        let response = try await chat(
            messages: [ChatTurn(role: "user", content: prompt)],
            systemPrompt: "You are a productivity analysis AI. Respond with JSON only."
        )
        return AIPromptBuilder.parseWindowSegments(response, windowStart: windowStart, windowEnd: windowEnd, activities: activities)
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

        Categories:
        - Work: coding, writing code, terminal/shell, IDEs, professional tools, databases, APIs, project management, documentation, business communication (Slack, Teams, email), cloud consoles, deployment tools, design tools (Figma, Photoshop), video editing, music production, creative work, online learning, tutorials, educational content
        - Distraction: social media (LinkedIn, Twitter, Instagram, Reddit, Facebook, TikTok), news sites, forums, random browsing, streaming video (Netflix, YouTube entertainment, Disney+), gaming, music streaming, shopping, banking, maps, travel, food ordering, personal apps, system settings, Finder
        - Uncategorized: cannot determine from available information

        Activity to categorize:
        App: \(appName) (\(bundleID))
        Window Title: \(windowTitle)
        """
        if let url = url { prompt += "\nURL/Domain: \(domainOnly(from: url))" }
        prompt += "\n\nRespond with ONLY the category name (Work, Distraction, or Uncategorized), nothing else."
        return prompt
    }

    static func batchCategorizationPrompt(items: [BatchCategorizeItem]) -> String {
        var prompt = """
        You are a productivity tracker AI. Categorize each computer activity into EXACTLY one category.

        Categories:
        - Work: coding, professional tools, project management, business communication, cloud/deployment, design tools, creative work, learning/tutorials
        - Distraction: social media, news sites, forums, streaming video, gaming, music streaming, shopping, personal apps, system utilities
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
        // Legacy category names AI might still return → remap to new 2-category system
        let legacyMap: [String: Category] = [
            "entertainment": .distraction, "personal": .distraction,
            "creative": .work, "learning": .work, "productivity": .work,
            "communication": .work, "health": .distraction
        ]
        if let mapped = legacyMap[cleaned.lowercased()] { return mapped }
        let allCats = CategoryManager.shared.allCategories
        if let match = allCats.first(where: { $0.name.lowercased() == cleaned.lowercased() }) {
            return Category(rawValue: match.name)
        }
        if let match = allCats.first(where: { cleaned.lowercased().contains($0.name.lowercased()) }) {
            return Category(rawValue: match.name)
        }
        return nil
    }

    // MARK: - Window Analysis Prompt

    static func windowAnalysisPrompt(activities: [ActivityRecord], windowStart: Date, windowEnd: Date) -> String {
        let timeFmt = DateFormatter()
        timeFmt.dateFormat = "HH:mm:ss"
        timeFmt.timeZone = Calendar.current.timeZone
        let windowStartStr = timeFmt.string(from: windowStart)
        let windowEndStr = timeFmt.string(from: windowEnd)

        // Build compact activity list
        var lines: [String] = []
        for a in activities {
            let time = timeFmt.string(from: a.timestamp)
            var line = "\(time) \(a.appName)"
            if !a.windowTitle.isEmpty { line += " \"\(a.windowTitle.prefix(80))\"" }
            if let url = a.url { line += " [\(domainOnly(from: url))]" }
            line += " \(Int(a.duration))s"
            if a.isIdle { line += " [IDLE]" }
            lines.append(line)
        }

        let categoriesList = CategoryManager.shared.allCategories.map { $0.name }.joined(separator: ", ")

        return """
        Analyze this \(windowStartStr)–\(windowEndStr) activity window. Return a JSON array of time segments.

        Activities (format: HH:mm:ss AppName "WindowTitle" [domain] duration_seconds):
        \(lines.joined(separator: "\n"))

        Rules:
        - Group consecutive related activities into segments (minimum 60 seconds per segment)
        - Detect idle gaps (periods with [IDLE] markers or no activity for >2 minutes)
        - Available categories: \(categoriesList)
        - Each segment needs: start (HH:mm), end (HH:mm), category, title (5-10 words describing what was done), isIdle (boolean)
        - Add a summary field (1-2 sentences) for segments longer than 10 minutes
        - Merge very short app switches (<30s) into the surrounding segment
        - Start must be >= \(windowStartStr.prefix(5)) and end must be <= \(windowEndStr.prefix(5))

        Respond with ONLY a JSON array, no markdown fences, no explanation:
        [{"start":"HH:mm","end":"HH:mm","category":"Work","title":"Short description","summary":null,"isIdle":false}]
        """
    }

    /// Parse AI JSON response into WindowSegmentResult array.
    /// Falls back to a single segment with dominant category on parse failure.
    static func parseWindowSegments(_ text: String, windowStart: Date, windowEnd: Date, activities: [ActivityRecord]) -> [WindowSegmentResult] {
        let cleaned = text
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let data = cleaned.data(using: .utf8),
              let jsonArray = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            aiLogger.warning("Failed to parse window analysis JSON, falling back to single segment")
            return fallbackSegment(windowStart: windowStart, windowEnd: windowEnd, activities: activities)
        }

        let cal = Calendar.current
        let timeFmt = DateFormatter()
        timeFmt.dateFormat = "HH:mm"
        timeFmt.timeZone = cal.timeZone

        // Base date for constructing segment times
        let dayStart = cal.startOfDay(for: windowStart)

        var results: [WindowSegmentResult] = []
        for obj in jsonArray {
            guard let startStr = obj["start"] as? String,
                  let endStr = obj["end"] as? String,
                  let catStr = obj["category"] as? String else { continue }

            guard let startTime = timeFmt.date(from: startStr),
                  let endTime = timeFmt.date(from: endStr) else { continue }

            // Reconstruct full dates from HH:mm relative to the window's day
            let startComps = cal.dateComponents([.hour, .minute], from: startTime)
            let endComps = cal.dateComponents([.hour, .minute], from: endTime)
            let segStart = cal.date(bySettingHour: startComps.hour ?? 0, minute: startComps.minute ?? 0, second: 0, of: dayStart)!
            var segEnd = cal.date(bySettingHour: endComps.hour ?? 0, minute: endComps.minute ?? 0, second: 0, of: dayStart)!

            // Handle midnight crossover
            if segEnd <= segStart { segEnd = cal.date(byAdding: .day, value: 1, to: segEnd)! }

            // Clamp to window bounds
            let clampedStart = max(segStart, windowStart)
            let clampedEnd = min(segEnd, windowEnd)
            guard clampedEnd > clampedStart else { continue }

            let category = parseCategory(catStr) ?? .uncategorized
            let title = obj["title"] as? String
            let summary = obj["summary"] as? String
            let isIdle = obj["isIdle"] as? Bool ?? false

            // Collect apps that fall within this segment's time range
            let segActivities = activities.filter { a in
                a.timestamp >= clampedStart && a.timestamp < clampedEnd && !a.isIdle
            }
            let apps = buildAppEntries(from: segActivities)

            results.append(WindowSegmentResult(
                segmentStart: clampedStart,
                segmentEnd: clampedEnd,
                category: category,
                title: title,
                summary: summary,
                isIdle: isIdle,
                apps: apps
            ))
        }

        if results.isEmpty {
            return fallbackSegment(windowStart: windowStart, windowEnd: windowEnd, activities: activities)
        }
        return results
    }

    /// Build CodableAppEntry list from activities (grouped by app)
    private static func buildAppEntries(from activities: [ActivityRecord]) -> [CodableAppEntry] {
        var grouped: [String: (bundleID: String, title: String, url: String?, duration: TimeInterval)] = [:]
        for a in activities where !a.isIdle {
            var entry = grouped[a.appName] ?? (bundleID: a.bundleID, title: a.windowTitle, url: a.url, duration: 0)
            entry.duration += a.duration
            if entry.title.isEmpty && !a.windowTitle.isEmpty { entry.title = a.windowTitle }
            if entry.url == nil && a.url != nil { entry.url = a.url }
            grouped[a.appName] = entry
        }
        return grouped.map { (name, e) in
            CodableAppEntry(appName: name, bundleID: e.bundleID, title: e.title, url: e.url, duration: e.duration)
        }.sorted { $0.duration > $1.duration }
    }

    /// Fallback: create a single segment covering the full window with dominant category
    static func fallbackSegment(windowStart: Date, windowEnd: Date, activities: [ActivityRecord]) -> [WindowSegmentResult] {
        let nonIdle = activities.filter { !$0.isIdle }
        guard !nonIdle.isEmpty else { return [] }

        // Find dominant category by total duration
        var totals: [String: TimeInterval] = [:]
        for a in nonIdle { totals[a.category.rawValue, default: 0] += a.duration }
        let best = totals.max { $0.value < $1.value }
        let category = Category(rawValue: best?.key ?? Category.work.rawValue)
        let apps = buildAppEntries(from: nonIdle)

        return [WindowSegmentResult(
            segmentStart: windowStart,
            segmentEnd: windowEnd,
            category: category,
            title: nil,
            summary: nil,
            isIdle: false,
            apps: apps
        )]
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
