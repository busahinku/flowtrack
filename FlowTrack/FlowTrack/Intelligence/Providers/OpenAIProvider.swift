import Foundation

struct OpenAIProvider: AIProvider, Sendable {
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
        guard let key = SecureStore.shared.loadKey(for: AIProviderType.openai.rawValue), !key.isEmpty else {
            throw AIError.noAPIKey
        }
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/models")!)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw AIError.networkError("Health check failed")
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
        guard let key = SecureStore.shared.loadKey(for: AIProviderType.openai.rawValue), !key.isEmpty else {
            throw AIError.noAPIKey
        }
        let url = URL(string: "https://api.openai.com/v1/chat/completions")!
        let isChat = messages.count > 1 || systemPrompt != nil
        var apiMessages: [[String: Any]] = []
        if let sys = systemPrompt {
            apiMessages.append(["role": "system", "content": sys])
        }
        apiMessages += messages.map { ["role": $0.role, "content": $0.content] }
        let body: [String: Any] = [
            "model": model,
            "max_tokens": isChat ? 1500 : 200,
            "messages": apiMessages
        ]
        let jsonData = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await AIHTTPHelper.sendRequest(url: url, headers: [
            "Content-Type": "application/json",
            "Authorization": "Bearer \(key)"
        ], body: jsonData)

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AIError.invalidResponse("Could not parse OpenAI response")
        }

        if let error = json["error"] as? [String: Any], let message = error["message"] as? String {
            throw AIError.invalidResponse("OpenAI: \(String(message.prefix(200)))")
        }

        guard let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let text = message["content"] as? String else {
            let raw = String(data: data.prefix(300), encoding: .utf8) ?? "(non-utf8)"
            throw AIError.invalidResponse("Unexpected OpenAI format: \(String(raw.prefix(200)))")
        }
        return text
    }
}
