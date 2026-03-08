import Foundation
import SwiftUI

// MARK: - Category (struct-based, dynamic)
struct Category: RawRepresentable, Codable, Hashable, Sendable {
    let rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }
    init(_ name: String) { self.rawValue = name }

    static let idle = Category(rawValue: "Idle")
    static let uncategorized = Category(rawValue: "Uncategorized")
    static let work = Category(rawValue: "Work")
    static let distraction = Category(rawValue: "Distraction")
    // Legacy aliases — all map to Work or Distraction
    static let productivity = Category(rawValue: "Work")
    static let creative = Category(rawValue: "Work")
    static let communication = Category(rawValue: "Work")
    static let learning = Category(rawValue: "Work")
    static let personal = Category(rawValue: "Distraction")
    static let entertainment = Category(rawValue: "Distraction")
    static let health = Category(rawValue: "Distraction")

    var isProductive: Bool {
        CategoryManager.shared.definition(for: self)?.isProductive ?? false
    }

    var icon: String {
        CategoryManager.shared.definition(for: self)?.icon ?? "questionmark.circle"
    }
}

// MARK: - GRDB DatabaseValueConvertible
import GRDB

extension Category: DatabaseValueConvertible {
    var databaseValue: DatabaseValue {
        rawValue.databaseValue
    }
    static func fromDatabaseValue(_ dbValue: DatabaseValue) -> Category? {
        guard let str = String.fromDatabaseValue(dbValue) else { return nil }
        return Category(rawValue: str)
    }
}

// MARK: - ActivityRecord
struct ActivityRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    var id: Int64?
    let timestamp: Date
    let appName: String
    let bundleID: String
    let windowTitle: String
    let url: String?
    var category: Category
    let isIdle: Bool
    let duration: TimeInterval
    let contentMetadata: String?
    let documentPath: String?

    static let databaseTableName = "activities"

    enum Columns: String, ColumnExpression {
        case id, timestamp, appName, bundleID, windowTitle, url, category, isIdle, duration, contentMetadata, documentPath
    }
}

// MARK: - TimeSlotStatus
enum TimeSlotStatus: Sendable {
    case processed    // AI has analyzed this — real data
    case processing   // Current in-progress window — placeholder
    case continuous   // Current window, continuing previous session
    case pending      // Past window, AI hasn't processed yet
}

// MARK: - TimeSlot (session-based)
struct TimeSlot: Identifiable, Sendable {
    let id: String
    let startTime: Date
    let endTime: Date
    let category: Category
    let activities: [ActivitySummary]
    let isIdle: Bool
    var title: String?
    var summary: String?
    var status: TimeSlotStatus

    var duration: TimeInterval { endTime.timeIntervalSince(startTime) }
    /// Sum of all activity durations (excludes idle gaps between activities)
    var activeDuration: TimeInterval { activities.reduce(0) { $0 + $1.duration } }

    init(id: String, startTime: Date, endTime: Date, category: Category,
         activities: [ActivitySummary], isIdle: Bool,
         title: String? = nil, summary: String? = nil,
         status: TimeSlotStatus = .processed) {
        self.id = id
        self.startTime = startTime
        self.endTime = endTime
        self.category = category
        self.activities = activities
        self.isIdle = isIdle
        self.title = title
        self.summary = summary
        self.status = status
    }
}

// MARK: - WindowSegment (stored in DB)
struct WindowSegment: Codable, FetchableRecord, PersistableRecord, Sendable {
    var id: String            // "2026-03-06T10:00-0"
    let windowId: String      // "2026-03-06T10:00"
    let segmentStart: Date
    let segmentEnd: Date
    let category: Category
    let title: String?
    let summary: String?
    let isIdle: Bool
    let apps: String          // JSON array of app data
    let processedAt: Date

    static let databaseTableName = "window_segments"

    enum Columns: String, ColumnExpression {
        case id, windowId, segmentStart, segmentEnd, category, title, summary, isIdle, apps, processedAt
    }

    /// Decoded app summaries from the JSON `apps` column
    var appSummaries: [ActivitySummary] {
        guard let data = apps.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([CodableAppEntry].self, from: data) else {
            return []
        }
        return decoded.enumerated().map { idx, entry in
            ActivitySummary(appName: entry.appName, bundleID: entry.bundleID ?? "",
                            title: entry.title ?? "", url: entry.url,
                            duration: entry.duration)
        }
    }
}

/// Lightweight codable struct for the JSON `apps` column in window_segments
struct CodableAppEntry: Codable, Sendable {
    let appName: String
    let bundleID: String?
    let title: String?
    let url: String?
    let duration: TimeInterval
    let contentMetadata: String?

    init(appName: String, bundleID: String?, title: String?, url: String?, duration: TimeInterval, contentMetadata: String? = nil) {
        self.appName = appName
        self.bundleID = bundleID
        self.title = title
        self.url = url
        self.duration = duration
        self.contentMetadata = contentMetadata
    }
}

// MARK: - WindowSegmentResult (AI response, not stored directly)
struct WindowSegmentResult: Sendable {
    let segmentStart: Date
    let segmentEnd: Date
    let category: Category
    let title: String?
    let summary: String?
    let isIdle: Bool
    let apps: [CodableAppEntry]
}

// MARK: - ActivitySummary
struct ActivitySummary: Identifiable, Sendable {
    let id: String
    let appName: String
    let bundleID: String
    let title: String
    let url: String?
    let duration: TimeInterval
    let timestamps: [Date]

    init(appName: String, bundleID: String, title: String, url: String?, duration: TimeInterval, timestamps: [Date] = []) {
        self.id = "\(bundleID)-\(timestamps.first.map { Int($0.timeIntervalSince1970) } ?? 0)"
        self.appName = appName
        self.bundleID = bundleID
        self.title = title
        self.url = url
        self.duration = duration
        self.timestamps = timestamps
    }
}

// MARK: - CategoryStat
struct CategoryStat: Identifiable, Sendable {
    let id: String
    let category: Category
    let totalSeconds: Double
    let percentage: Double
    let appCount: Int

    init(category: Category, totalSeconds: Double, percentage: Double, appCount: Int = 0) {
        self.id = category.rawValue
        self.category = category
        self.totalSeconds = totalSeconds
        self.percentage = percentage
        self.appCount = appCount
    }
}

// MARK: - HourStat
struct HourStat: Identifiable, Sendable {
    let id: String
    let hour: Int
    let category: Category
    let minutes: Double

    init(hour: Int, category: Category, minutes: Double) {
        self.id = "\(hour)-\(category.rawValue)"
        self.hour = hour
        self.category = category
        self.minutes = minutes
    }
}

// MARK: - Rule
struct Rule: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let matchType: MatchType
    let pattern: String
    let category: String

    enum MatchType: String, Codable, Sendable {
        case appName, bundleID, domain, titleContains

        init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            switch raw {
            case "windowTitle": self = .titleContains
            default:
                guard let value = MatchType(rawValue: raw) else {
                    throw DecodingError.dataCorrupted(.init(
                        codingPath: decoder.codingPath,
                        debugDescription: "Unknown MatchType: \(raw)"
                    ))
                }
                self = value
            }
        }
    }

    init(matchType: MatchType, pattern: String, category: String) {
        self.id = "\(matchType.rawValue):\(pattern)"
        self.matchType = matchType
        self.pattern = pattern
        self.category = category
    }
}

// MARK: - AIProviderType
enum AIProviderType: String, CaseIterable, Codable, Identifiable, Sendable {
    case claudeCLI = "Claude Code"
    case chatgptCLI = "ChatGPT Codex"
    case claude = "Claude API"
    case openai = "OpenAI API"
    case gemini = "Gemini API"
    case ollama = "Ollama"
    case lmstudio = "LM Studio"

    var id: String { rawValue }

    var isCLI: Bool {
        self == .claudeCLI || self == .chatgptCLI
    }

    var needsAPIKey: Bool {
        switch self {
        case .claude, .openai, .gemini: return true
        default: return false
        }
    }

    var defaultModel: String {
        switch self {
        case .claudeCLI: return "sonnet"
        case .chatgptCLI: return "gpt-4.1-mini"
        case .claude: return "claude-sonnet-4-5-20250929"
        case .openai: return "gpt-4o-mini"
        case .gemini: return "gemini-2.5-flash"
        case .ollama: return "llama3.2"
        case .lmstudio: return "default"
        }
    }

    var suggestedModels: [String] {
        switch self {
        case .claudeCLI: return ["haiku", "sonnet", "opus"]
        case .chatgptCLI: return ["gpt-4.1-mini", "gpt-4.1", "o3-mini"]
        case .claude: return ["claude-haiku-4-5-20250929", "claude-sonnet-4-5-20250929", "claude-opus-4-20250916"]
        case .openai: return ["gpt-4o-mini", "gpt-4o", "gpt-4.1-mini", "gpt-4.1"]
        case .gemini: return ["gemini-2.5-flash-lite", "gemini-2.5-flash", "gemini-2.5-pro"]
        case .ollama: return ["llama3.2", "llama3.2:1b", "mistral", "gemma2"]
        case .lmstudio: return ["default"]
        }
    }

    /// The cheapest/fastest model for lightweight classification tasks (e.g., 1-word responses).
    var cheapClassificationModel: String {
        switch self {
        case .claudeCLI:   return "haiku"
        case .chatgptCLI:  return "gpt-4.1-mini"
        case .claude:      return "claude-haiku-4-5-20250929"
        case .openai:      return "gpt-4o-mini"
        case .gemini:      return "gemini-2.5-flash-lite"
        case .ollama:      return defaultModel
        case .lmstudio:    return defaultModel
        }
    }

    var modelHint: String {
        switch self {
        case .claudeCLI: return "haiku (cheapest) → sonnet → opus"
        case .chatgptCLI: return "gpt-4.1-mini (cheapest) → gpt-4.1"
        case .claude: return "haiku (cheapest) → sonnet → opus"
        case .openai: return "gpt-4o-mini (cheapest) → gpt-4o → gpt-4.1"
        case .gemini: return "flash-lite (cheapest) → flash → pro"
        case .ollama: return "llama3.2:1b (smallest) → llama3.2 → mistral"
        case .lmstudio: return "Use model loaded in LM Studio"
        }
    }

    var cliCommand: String? {
        switch self {
        case .claudeCLI: return "claude"
        case .chatgptCLI: return "codex"
        default: return nil
        }
    }

    var setupInstructions: String? {
        switch self {
        case .claudeCLI: return "Install: npm install -g @anthropic-ai/claude-code"
        case .chatgptCLI: return "Install: npm install -g @openai/codex"
        default: return nil
        }
    }
}

// MARK: - Sync

enum SyncProvider: String, CaseIterable, Sendable {
    case none      = "none"
    case iCloud    = "iCloud"
    case googleDrive = "googleDrive"
    case dropbox   = "dropbox"
    case oneDrive  = "oneDrive"

    var displayName: String {
        switch self {
        case .none:        return "Off"
        case .iCloud:      return "iCloud Drive"
        case .googleDrive: return "Google Drive"
        case .dropbox:     return "Dropbox"
        case .oneDrive:    return "OneDrive"
        }
    }

    var icon: String {
        switch self {
        case .none:        return "xmark.circle"
        case .iCloud:      return "icloud"
        case .googleDrive: return "g.circle"
        case .dropbox:     return "square.and.arrow.down"
        case .oneDrive:    return "cloud"
        }
    }
}

// MARK: - AppSettings
@MainActor @Observable
final class AppSettings {
    static let shared = AppSettings()

    var aiProvider: AIProviderType {
        didSet { UserDefaults.standard.set(aiProvider.rawValue, forKey: "aiProvider") }
    }
    var secondaryProvider: AIProviderType? {
        didSet { UserDefaults.standard.set(secondaryProvider?.rawValue, forKey: "secondaryProvider") }
    }
    var tertiaryProvider: AIProviderType? {
        didSet { UserDefaults.standard.set(tertiaryProvider?.rawValue, forKey: "tertiaryProvider") }
    }
    var aiSummariesEnabled: Bool {
        didSet { UserDefaults.standard.set(aiSummariesEnabled, forKey: "aiSummariesEnabled") }
    }
    var aiBatchIntervalMinutes: Int {
        didSet {
            UserDefaults.standard.set(aiBatchIntervalMinutes, forKey: "aiBatchIntervalMinutes")
            AppState.shared.resetAITimer()
        }
    }
    var aiBatchSize: Int {
        didSet { UserDefaults.standard.set(aiBatchSize, forKey: "aiBatchSize") }
    }
    var showDockIcon: Bool {
        didSet {
            UserDefaults.standard.set(showDockIcon, forKey: "showDockIcon")
            NSApp?.setActivationPolicy(showDockIcon ? .regular : .accessory)
        }
    }
    var showAppIcons: Bool {
        didSet { UserDefaults.standard.set(showAppIcons, forKey: "showAppIcons") }
    }
    var launchAtLogin: Bool {
        didSet { UserDefaults.standard.set(launchAtLogin, forKey: "launchAtLogin") }
    }
    var hasCompletedOnboarding: Bool {
        didSet { UserDefaults.standard.set(hasCompletedOnboarding, forKey: "hasCompletedOnboarding") }
    }
    var appTheme: AppTheme {
        didSet { UserDefaults.standard.set(appTheme.rawValue, forKey: "appTheme") }
    }
    var captureWindowTitles: Bool {
        didSet { UserDefaults.standard.set(captureWindowTitles, forKey: "captureWindowTitles") }
    }
    var excludedBundleIDs: [String] {
        didSet { UserDefaults.standard.set(excludedBundleIDs, forKey: "excludedBundleIDs") }
    }
    var idleThresholdSeconds: Int {
        didSet { UserDefaults.standard.set(idleThresholdSeconds, forKey: "idleThresholdSeconds") }
    }
    var distractionAlertMinutes: Int {
        didSet { UserDefaults.standard.set(distractionAlertMinutes, forKey: "distractionAlertMinutes") }
    }
    var retentionDays: Int {
        didSet { UserDefaults.standard.set(retentionDays, forKey: "retentionDays") }
    }
    var sessionWorkMinutes: Int {
        didSet { UserDefaults.standard.set(sessionWorkMinutes, forKey: "sessionWorkMinutes") }
    }
    var sessionBreakMinutes: Int {
        didSet { UserDefaults.standard.set(sessionBreakMinutes, forKey: "sessionBreakMinutes") }
    }
    var sessionLongBreakMinutes: Int {
        didSet { UserDefaults.standard.set(sessionLongBreakMinutes, forKey: "sessionLongBreakMinutes") }
    }
    var sessionsBeforeLong: Int {
        didSet { UserDefaults.standard.set(sessionsBeforeLong, forKey: "sessionsBeforeLong") }
    }
    var countdownMinutes: Int {
        didSet { UserDefaults.standard.set(countdownMinutes, forKey: "countdownMinutes") }
    }
    var use24HourClock: Bool {
        didSet { UserDefaults.standard.set(use24HourClock, forKey: "use24HourClock") }
    }
    var defaultTimerMode: TimerMode {
        didSet { UserDefaults.standard.set(defaultTimerMode.rawValue, forKey: "defaultTimerMode") }
    }
    var sessionGapSeconds: Int {
        didSet { UserDefaults.standard.set(sessionGapSeconds, forKey: "sessionGapSeconds") }
    }
    var syncProvider: SyncProvider {
        didSet { UserDefaults.standard.set(syncProvider.rawValue, forKey: "syncProvider") }
    }
    var lastSyncDate: Date? {
        didSet { UserDefaults.standard.set(lastSyncDate, forKey: "lastSyncDate") }
    }
    var autoSyncEnabled: Bool {
        didSet { UserDefaults.standard.set(autoSyncEnabled, forKey: "autoSyncEnabled") }
    }
    var autoSyncIntervalDays: Int {
        didSet { UserDefaults.standard.set(autoSyncIntervalDays, forKey: "autoSyncIntervalDays") }
    }

    private init() {
        let defaults = UserDefaults.standard
        self.aiProvider = AIProviderType(rawValue: defaults.string(forKey: "aiProvider") ?? "") ?? .claudeCLI
        self.secondaryProvider = AIProviderType(rawValue: defaults.string(forKey: "secondaryProvider") ?? "")
        self.tertiaryProvider = AIProviderType(rawValue: defaults.string(forKey: "tertiaryProvider") ?? "")
        self.aiSummariesEnabled = defaults.object(forKey: "aiSummariesEnabled") as? Bool ?? true
        self.aiBatchIntervalMinutes = defaults.object(forKey: "aiBatchIntervalMinutes") as? Int ?? 30
        self.aiBatchSize = defaults.object(forKey: "aiBatchSize") as? Int ?? 30
        self.showDockIcon = defaults.bool(forKey: "showDockIcon")
        self.showAppIcons = defaults.object(forKey: "showAppIcons") as? Bool ?? true
        self.launchAtLogin = defaults.bool(forKey: "launchAtLogin")
        self.hasCompletedOnboarding = defaults.bool(forKey: "hasCompletedOnboarding")
        self.appTheme = AppTheme(rawValue: defaults.string(forKey: "appTheme") ?? "") ?? .system
        self.captureWindowTitles = defaults.object(forKey: "captureWindowTitles") as? Bool ?? true
        self.excludedBundleIDs = defaults.stringArray(forKey: "excludedBundleIDs") ?? []
        self.idleThresholdSeconds = defaults.object(forKey: "idleThresholdSeconds") as? Int ?? 120
        self.distractionAlertMinutes = defaults.object(forKey: "distractionAlertMinutes") as? Int ?? 0
        self.retentionDays = defaults.object(forKey: "retentionDays") as? Int ?? 90
        self.sessionWorkMinutes = (defaults.object(forKey: "sessionWorkMinutes") ?? defaults.object(forKey: "pomodoroWorkMinutes")) as? Int ?? 25
        self.sessionBreakMinutes = (defaults.object(forKey: "sessionBreakMinutes") ?? defaults.object(forKey: "pomodoroBreakMinutes")) as? Int ?? 5
        self.sessionLongBreakMinutes = (defaults.object(forKey: "sessionLongBreakMinutes") ?? defaults.object(forKey: "pomodoroLongBreakMinutes")) as? Int ?? 15
        self.sessionsBeforeLong = (defaults.object(forKey: "sessionsBeforeLong") ?? defaults.object(forKey: "pomodoroSessionsBeforeLong")) as? Int ?? 4
        self.countdownMinutes = defaults.object(forKey: "countdownMinutes") as? Int ?? 25
        self.use24HourClock = defaults.object(forKey: "use24HourClock") as? Bool ?? true
        self.defaultTimerMode = TimerMode(rawValue: defaults.string(forKey: "defaultTimerMode") ?? "") ?? .stopwatch
        self.sessionGapSeconds = defaults.object(forKey: "sessionGapSeconds") as? Int ?? 300
        self.syncProvider = SyncProvider(rawValue: defaults.string(forKey: "syncProvider") ?? "") ?? .none
        self.lastSyncDate = defaults.object(forKey: "lastSyncDate") as? Date
        self.autoSyncEnabled = defaults.bool(forKey: "autoSyncEnabled")
        self.autoSyncIntervalDays = defaults.object(forKey: "autoSyncIntervalDays") as? Int ?? 1
    }

    func modelName(for provider: AIProviderType) -> String {
        UserDefaults.standard.string(forKey: "model_\(provider.rawValue)") ?? provider.defaultModel
    }

    func setModelName(_ name: String, for provider: AIProviderType) {
        UserDefaults.standard.set(name, forKey: "model_\(provider.rawValue)")
    }

    var currentModelName: String {
        modelName(for: aiProvider)
    }
}

// MARK: - Todo Models

enum TodoStatus: String, Codable, CaseIterable, Sendable {
    case pending    = "pending"
    case inProgress = "inProgress"
    case done       = "done"

    var label: String {
        switch self { case .pending: "To Do"; case .inProgress: "In Progress"; case .done: "Done" }
    }
}

enum TodoPriority: Int, Codable, CaseIterable, Sendable {
    case low = 0, medium = 1, high = 2
    var label: String { ["Low", "Medium", "High"][rawValue] }
    var color: Color {
        let theme = AppSettings.shared.appTheme
        switch self {
        case .low:    return theme.successColor
        case .medium: return theme.warningColor
        case .high:   return theme.errorColor
        }
    }
    var icon: String { ["arrow.down", "minus", "arrow.up"][rawValue] }
}

struct TodoItem: Codable, Identifiable, Sendable {
    var id: String = UUID().uuidString
    var title: String
    var notes: String = ""
    var status: TodoStatus = .pending
    var priority: TodoPriority = .medium
    var dueDate: Date? = nil
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    var subtasks: [TodoItem] = []
    /// When enabled, StudyTrackerEngine auto-starts a stopwatch when the current activity matches this todo.
    var autoCatch: Bool = false
    /// Comma-separated keywords for instant matching (e.g. "python, calculus, react tutorial").
    var autoCatchKeywords: String = ""

    var completedSubtaskCount: Int { subtasks.filter { $0.status == .done }.count }
    var hasSubtasks: Bool { !subtasks.isEmpty }

    /// Parsed keywords lowercased and trimmed, used by StudyTrackerEngine for fast matching.
    var parsedKeywords: [String] {
        autoCatchKeywords
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
    }
}

// MARK: - Timer Models

enum TimerMode: String, Codable, CaseIterable, Sendable {
    case pomodoro  = "Session"
    case countdown = "Countdown"
    case stopwatch = "Stopwatch"
    var icon: String {
        switch self { case .pomodoro: "timer"; case .countdown: "hourglass"; case .stopwatch: "stopwatch" }
    }
}

enum SessionPhase: String, Sendable {
    case work, shortBreak, longBreak
    var label: String {
        switch self { case .work: "Focus"; case .shortBreak: "Short Break"; case .longBreak: "Long Break" }
    }
    var color: Color {
        let theme = AppSettings.shared.appTheme
        switch self {
        case .work:       return theme.infoColor
        case .shortBreak: return theme.successColor
        case .longBreak:  return theme.warningColor
        }
    }
}

/// Backward-compatibility typealias so any remaining PomodoroPhase references still compile.
typealias PomodoroPhase = SessionPhase

struct LapRecord: Codable, Identifiable, Sendable {
    var id: String = UUID().uuidString
    var index: Int              // 1-based lap number
    var duration: TimeInterval  // how long this lap lasted
    var startedAt: Date
    var endedAt: Date
    var todoId: String?         // which todo was active during this lap
}

struct TimerSession: Codable, Identifiable, Sendable {
    var id: String = UUID().uuidString
    var todoId: String?
    var mode: TimerMode
    var duration: TimeInterval   // seconds actually tracked
    var startedAt: Date
    var endedAt: Date
}

// MARK: - App Blocker Models

/// An app entry inside a BlockCard.
struct BlockedApp: Codable, Identifiable, Sendable, Hashable {
    var id: String = UUID().uuidString
    var displayName: String
    var bundleID: String
}

/// A group card containing websites and apps to block together.
struct BlockCard: Codable, Identifiable, Sendable {
    var id: String = UUID().uuidString
    var name: String                    // "Social Media"
    var iconName: String = "nosign"     // SF Symbol name for card icon
    var colorName: String = "purple"    // "purple","blue","red","orange","green","teal","pink","yellow"
    var isEnabled: Bool = true
    var websites: [String] = []         // ["reddit.com", "twitter.com"]
    var apps: [BlockedApp] = []         // apps with bundle IDs
    var dailyLimitMinutes: Int = 0      // 0 = always block
    var createdAt: Date = Date()

    var isAlwaysBlock: Bool { dailyLimitMinutes == 0 }

    var accentColor: Color {
        switch colorName {
        case "blue":   return .blue
        case "red":    return .red
        case "orange": return .orange
        case "green":  return Color(red: 0.2, green: 0.75, blue: 0.45)
        case "teal":   return .teal
        case "pink":   return .pink
        case "yellow": return .yellow
        default:       return .purple
        }
    }
}

struct BlockUsage: Codable, Sendable {
    var cardId: String         // references BlockCard.id
    var date: String           // "YYYY-MM-DD"
    var usedSeconds: Int
}
