import Foundation

struct GeminiProvider: AIProvider, Sendable {
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
        guard let key = SecureStore.shared.loadKey(for: AIProviderType.gemini.rawValue), !key.isEmpty else {
            throw AIError.noAPIKey
        }
        let request = URLRequest(url: URL(string: "https://generativelanguage.googleapis.com/v1/models?key=\(key)")!)
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw AIError.networkError("Health check failed")
        }
        return true
    }

    private func sendRequest(prompt: String) async throws -> String {
        guard let key = SecureStore.shared.loadKey(for: AIProviderType.gemini.rawValue), !key.isEmpty else {
            throw AIError.noAPIKey
        }
        let url = URL(string: "https://generativelanguage.googleapis.com/v1/models/\(model):generateContent?key=\(key)")!
        let body: [String: Any] = [
            "contents": [["parts": [["text": prompt]]]],
            "generationConfig": ["maxOutputTokens": 200]
        ]
        let jsonData = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await AIHTTPHelper.sendRequest(url: url, headers: [
            "Content-Type": "application/json"
        ], body: jsonData)

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AIError.invalidResponse("Could not parse Gemini response")
        }

        if let error = json["error"] as? [String: Any], let message = error["message"] as? String {
            throw AIError.invalidResponse("Gemini: \(String(message.prefix(200)))")
        }

        guard let candidates = json["candidates"] as? [[String: Any]],
              let content = candidates.first?["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]],
              let text = parts.first?["text"] as? String else {
            let raw = String(data: data.prefix(300), encoding: .utf8) ?? "(non-utf8)"
            throw AIError.invalidResponse("Unexpected Gemini format: \(String(raw.prefix(200)))")
        }
        return text
    }
}
