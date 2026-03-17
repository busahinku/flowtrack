import Foundation

struct OllamaProvider: AIProvider, Sendable {
    let model: String

    func categorize(appName: String, bundleID: String, windowTitle: String, url: String?) async throws -> Category {
        let prompt = AIPromptBuilder.categorizationPrompt(appName: appName, bundleID: bundleID, windowTitle: windowTitle, url: url)
        let text = try await sendRequest(prompt: prompt)
        guard let cat = AIPromptBuilder.parseCategory(text) else {
            throw AIError.invalidResponse("Could not parse: \(text)")
        }
        return cat
    }

    func generateTitle(activities: [ActivitySummary], category: Category) async throws -> String {
        let prompt = AIPromptBuilder.titlePrompt(activities: activities, category: category)
        return try await sendRequest(prompt: prompt).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func summarize(activities: [ActivitySummary]) async throws -> String {
        let prompt = AIPromptBuilder.summaryPrompt(activities: activities)
        return try await sendRequest(prompt: prompt).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func checkHealth() async throws -> Bool {
        let url = URL(string: "http://localhost:11434/api/tags")!
        let request = URLRequest(url: url)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw AIError.networkError("Ollama not running")
        }

        // Validate the configured model is actually installed
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["models"] as? [[String: Any]] else {
            throw AIError.networkError("Could not read installed models from Ollama")
        }

        let installedNames = models.compactMap { $0["name"] as? String }
        let modelMatches = installedNames.contains { installed in
            // Exact match or match without ":latest" tag
            installed == model
                || installed == "\(model):latest"
                || installed.split(separator: ":").first.map(String.init) == model
        }
        guard modelMatches else {
            let available = installedNames.joined(separator: ", ")
            throw AIError.modelNotFound("'\(model)' not installed. Available: \(available)")
        }
        return true
    }

    private func sendRequest(prompt: String) async throws -> String {
        try await sendChat(messages: [ChatTurn(role: "user", content: prompt)], systemPrompt: nil)
    }

    func chat(messages: [ChatTurn], systemPrompt: String) async throws -> String {
        try await sendChat(messages: messages, systemPrompt: systemPrompt)
    }

    private func sendChat(messages: [ChatTurn], systemPrompt: String?) async throws -> String {
        let url = URL(string: "http://localhost:11434/api/chat")!
        var apiMessages: [[String: Any]] = []
        if let sys = systemPrompt {
            apiMessages.append(["role": "system", "content": sys])
        }
        apiMessages += messages.map { ["role": $0.role, "content": $0.content] }
        let body: [String: Any] = ["model": model, "messages": apiMessages, "stream": false]
        let jsonData = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await AIHTTPHelper.sendRequest(url: url, headers: [
            "Content-Type": "application/json"
        ], body: jsonData)

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = json["message"] as? [String: Any],
              let text = message["content"] as? String else {
            // Fallback to old /api/generate response format
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let text = json["response"] as? String { return text }
            throw AIError.invalidResponse("Unexpected Ollama response format")
        }
        return text
    }
}
