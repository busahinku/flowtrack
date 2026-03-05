import Foundation

struct ClaudeProvider: AIProvider, Sendable {
    let model: String

    func categorize(appName: String, bundleID: String, windowTitle: String, url: String?) async throws -> Category {
        let prompt = AIPromptBuilder.categorizationPrompt(appName: appName, bundleID: bundleID, windowTitle: windowTitle, url: url)
        let text = try await sendRequest(prompt: prompt)
        guard let cat = AIPromptBuilder.parseCategory(text) else {
            throw AIError.invalidResponse("Could not parse category from: \(text)")
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
        guard let key = SecureStore.shared.loadKey(for: AIProviderType.claude.rawValue), !key.isEmpty else {
            throw AIError.noAPIKey
        }
        let url = URL(string: "https://api.anthropic.com/v1/messages")!
        let body: [String: Any] = [
            "model": model,
            "max_tokens": 10,
            "messages": [["role": "user", "content": "Hi"]]
        ]
        let data = try JSONSerialization.data(withJSONObject: body)
        let _ = try await AIHTTPHelper.sendRequest(url: url, headers: [
            "Content-Type": "application/json",
            "x-api-key": key,
            "anthropic-version": "2023-06-01"
        ], body: data)
        return true
    }

    private func sendRequest(prompt: String) async throws -> String {
        guard let key = SecureStore.shared.loadKey(for: AIProviderType.claude.rawValue), !key.isEmpty else {
            throw AIError.noAPIKey
        }
        let url = URL(string: "https://api.anthropic.com/v1/messages")!
        let body: [String: Any] = [
            "model": model,
            "max_tokens": 200,
            "messages": [["role": "user", "content": prompt]]
        ]
        let jsonData = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await AIHTTPHelper.sendRequest(url: url, headers: [
            "Content-Type": "application/json",
            "x-api-key": key,
            "anthropic-version": "2023-06-01"
        ], body: jsonData)

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AIError.invalidResponse("Could not parse Claude response")
        }

        if let error = json["error"] as? [String: Any], let message = error["message"] as? String {
            throw AIError.invalidResponse("Claude: \(String(message.prefix(200)))")
        }

        guard let content = json["content"] as? [[String: Any]],
              let text = content.first?["text"] as? String else {
            let raw = String(data: data.prefix(300), encoding: .utf8) ?? "(non-utf8)"
            throw AIError.invalidResponse("Unexpected Claude format: \(String(raw.prefix(200)))")
        }
        return text
    }
}
