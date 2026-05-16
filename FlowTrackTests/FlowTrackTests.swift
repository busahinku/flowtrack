//
//  FlowTrackTests.swift
//  FlowTrackTests
//
//  Created by Burak Sahin Kucuk on 5.03.2026.
//

import Testing
import Foundation
@testable import FlowTrack

struct FlowTrackTests {

    @Test func domainMatcherNormalizesDomainsAndAvoidsSubstringMatches() {
        #expect(DomainMatcher.normalizedDomain("https://www.reddit.com/r/swift?token=secret") == "reddit.com")
        #expect(DomainMatcher.url("https://old.reddit.com/r/swift", matches: "reddit.com"))
        #expect(DomainMatcher.url("https://api.github.com/repos", matches: "*.github.com"))
        #expect(!DomainMatcher.url("https://notreddit.com", matches: "reddit.com"))
        #expect(!DomainMatcher.url("https://github.com.evil.test", matches: "github.com"))
    }

    @Test func browserCatalogRecognizesCommonVariants() {
        #expect(BrowserCatalog.isBrowser(appName: "Google Chrome Beta", bundleID: "com.google.Chrome.beta"))
        #expect(BrowserCatalog.isBrowser(appName: "LibreWolf", bundleID: "io.gitlab.librewolf-community"))
        #expect(BrowserCatalog.isBrowser(appName: "Microsoft Edge", bundleID: "com.microsoft.edgemac"))
        #expect(!BrowserCatalog.isBrowser(appName: "Xcode", bundleID: "com.apple.dt.Xcode"))
    }

    @Test func aiCategoryParserRequiresExplicitValidCategory() {
        #expect(AIPromptBuilder.parseCategory("Work") == .work)
        #expect(AIPromptBuilder.parseCategory("Category: Distraction") == .distraction)
        #expect(AIPromptBuilder.parseCategory(#"{"category":"Work","confidence":0.91}"#) == .work)
        #expect(AIPromptBuilder.parseCategory("This is not Work") == nil)
        #expect(AIPromptBuilder.parseCategory("Definitely productivity-ish") == nil)
    }

    @Test func aiPromptsStripURLsToDomainsOnly() {
        #expect(AIPromptBuilder.domainOnly(from: "https://www.example.com/path?token=secret") == "example.com")
        #expect(AIPromptBuilder.domainOnly(from: "old.reddit.com/r/swift") == "old.reddit.com")
    }

    @Test func invalidAISegmentCategoryFallsBackToRecordedDominantCategory() {
        let calendar = Calendar(identifier: .gregorian)
        let start = calendar.date(from: DateComponents(year: 2026, month: 5, day: 16, hour: 10, minute: 0, second: 0))!
        let activities = [
            ActivityRecord(
                id: nil,
                timestamp: start,
                appName: "Xcode",
                bundleID: "com.apple.dt.Xcode",
                windowTitle: "Project.swift",
                url: nil,
                category: .work,
                isIdle: false,
                duration: 180,
                contentMetadata: nil,
                documentPath: nil
            ),
            ActivityRecord(
                id: nil,
                timestamp: start.addingTimeInterval(180),
                appName: "Safari",
                bundleID: "com.apple.Safari",
                windowTitle: "News",
                url: "https://example.com",
                category: .distraction,
                isIdle: false,
                duration: 60,
                contentMetadata: nil,
                documentPath: nil
            )
        ]

        let invalidAI = """
        [{"start":"10:00:00","end":"10:04:00","category":"Definitely Work","title":"Bad category","summary":null,"isIdle":false}]
        """
        let segments = AIPromptBuilder.parseWindowSegments(
            invalidAI,
            windowStart: start,
            windowEnd: start.addingTimeInterval(300),
            activities: activities
        )

        #expect(segments.count == 1)
        #expect(segments.first?.category == .work)
        #expect(segments.first?.title == nil)
    }

    @Test func ruleEngineExposesClassificationSource() {
        let result = RuleEngine.shared.categorizeWithResult(
            appName: "Safari",
            bundleID: "com.apple.Safari",
            windowTitle: "Pull Request - GitHub",
            url: "https://github.com/example/repo"
        )

        #expect(result?.category == .work)
        #expect(result?.source == .defaultRule)
        #expect(result?.confidence == .high)
    }
}
