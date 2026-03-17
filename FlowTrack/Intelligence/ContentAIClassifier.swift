import Foundation
import OSLog

private nonisolated let classifierLog = Logger(subsystem: "com.flowtrack", category: "ContentClassifier")

// MARK: - ContentAIClassifier

/// Classifies YouTube video titles as educational or entertainment using AI.
///
/// Runs as an `actor` for safe concurrent cache access. A lightweight 1-word prompt
/// is sent to the user's configured AI provider (using the cheapest available model).
/// Results are cached in-memory by title prefix to avoid redundant API calls.
/// Falls back to keyword matching if no API-based provider is configured or the call fails.
actor ContentAIClassifier {
    static let shared = ContentAIClassifier()

    // In-memory cache: lowercase title prefix → isEducational
    private var cache: [String: Bool] = [:]

    private init() {}

    // MARK: - Public API

    /// Returns `true` if the video title appears to be educational content.
    func isEducational(videoTitle: String) async -> Bool {
        guard !videoTitle.isEmpty else { return false }

        let cacheKey = String(videoTitle.lowercased().prefix(80))
        if let cached = cache[cacheKey] {
            classifierLog.debug("Cache hit: \(videoTitle.prefix(40))")
            return cached
        }

        if let aiResult = await classifyWithAI(videoTitle) {
            cache[cacheKey] = aiResult
            return aiResult
        }

        let fallback = keywordMatch(videoTitle)
        cache[cacheKey] = fallback
        return fallback
    }

    // MARK: - AI Classification

    private func classifyWithAI(_ title: String) async -> Bool? {
        // Read provider config on the main actor
        let (providerType, isCliProvider, provider): (AIProviderType, Bool, any AIProvider) = await MainActor.run {
            let settings = SettingsStorage.shared
            let type = settings.aiProvider
            // CLI tools spawn child processes — unsuitable for real-time 1-word calls
            let cli = type.isCLI
            let p = AIProviderFactory.create(for: type, model: type.cheapClassificationModel)
            return (type, cli, p)
        }

        guard !isCliProvider else {
            classifierLog.debug("Skipping AI: CLI provider '\(providerType.rawValue)' not suitable for real-time calls")
            return nil
        }

        let system = """
            You classify YouTube video titles. \
            Respond with exactly one word: educational or entertainment. \
            No punctuation, no explanation.
            """
        let messages = [ChatTurn(role: "user", content: title)]

        do {
            let response = try await provider.chat(messages: messages, systemPrompt: system)
            let isEd = response
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
                .hasPrefix("educational")
            classifierLog.info(
                "AI: '\(title.prefix(50))' → \(isEd ? "educational ✅" : "entertainment 🚫")"
            )
            return isEd
        } catch {
            classifierLog.debug("AI call failed (\(error.localizedDescription)) — falling back to keywords")
            return nil
        }
    }

    // MARK: - Keyword Fallback

    private func keywordMatch(_ title: String) -> Bool {
        let t = title.lowercased()
        let keywords: [String] = [
            "tutorial", "course", "lecture", "how to", "learn", "programming",
            "explained", "walkthrough", "guide", "study", "masterclass", "lesson",
            "coding", "algorithm", "data structure", "math", "physics", "chemistry",
            "biology", "history", "science", "engineering", "medicine",
            "mit opencourseware", "stanford", "coursera", "khan academy", "freecodecamp",
            "university", "professor", "classroom", "exam prep",
            "chapter", "part 1", "part 2", "episode", "python", "javascript", "swift",
            "machine learning", "deep learning", "neural network", "calculus", "statistics"
        ]
        return keywords.contains { t.contains($0) }
    }
}
