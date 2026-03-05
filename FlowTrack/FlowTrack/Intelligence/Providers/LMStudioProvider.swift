import Foundation

struct LMStudioProvider: AIProvider, Sendable {
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
        var request = URLRequest(url: URL(string: "http://localhost:1234/v1/models")!)
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw AIError.networkError("LM Studio not running")
        }
        return true
    }

    private func sendRequest(prompt: String) async throws -> String {
        let url = URL(string: "http://localhost:1234/v1/chat/completions")!
        var body: [String: Any] = [
            "messages": [["role": "user", "content": prompt]],
            "max_tokens": 200
        ]
        if model != "default" { body["model"] = model }
        let jsonData = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await AIHTTPHelper.sendRequest(url: url, headers: [
            "Content-Type": "application/json"
        ], body: jsonData)

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let text = message["content"] as? String else {
            throw AIError.invalidResponse("Unexpected LM Studio response format")
        }
        return text
    }
}
