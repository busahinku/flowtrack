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
    static let productivity = Category(rawValue: "Work")  // merged into Work
    static let personal = Category(rawValue: "Personal")
    static let distraction = Category(rawValue: "Distraction")
    static let creative = Category(rawValue: "Creative")
    static let entertainment = Category(rawValue: "Entertainment")
    // Legacy aliases — kept for backward compat with any stored data
    static let communication = Category(rawValue: "Work")
    static let learning = Category(rawValue: "Work")
    static let health = Category(rawValue: "Personal")

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

    static let databaseTableName = "activities"

    enum Columns: String, ColumnExpression {
        case id, timestamp, appName, bundleID, windowTitle, url, category, isIdle, duration
    }
}

// MARK: - TimeSlot (session-based)
struct TimeSlot: Identifiable, Sendable {
    let id: String
    let startTime: Date
    let endTime: Date
    let category: Category
    let activities: [ActivitySummary]
    let isIdle: Bool

    var duration: TimeInterval { endTime.timeIntervalSince(startTime) }
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
    var pomodoroWorkMinutes: Int {
        didSet { UserDefaults.standard.set(pomodoroWorkMinutes, forKey: "pomodoroWorkMinutes") }
    }
    var pomodoroBreakMinutes: Int {
        didSet { UserDefaults.standard.set(pomodoroBreakMinutes, forKey: "pomodoroBreakMinutes") }
    }
    var pomodoroLongBreakMinutes: Int {
        didSet { UserDefaults.standard.set(pomodoroLongBreakMinutes, forKey: "pomodoroLongBreakMinutes") }
    }
    var pomodoroSessionsBeforeLong: Int {
        didSet { UserDefaults.standard.set(pomodoroSessionsBeforeLong, forKey: "pomodoroSessionsBeforeLong") }
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
        self.pomodoroWorkMinutes = defaults.object(forKey: "pomodoroWorkMinutes") as? Int ?? 25
        self.pomodoroBreakMinutes = defaults.object(forKey: "pomodoroBreakMinutes") as? Int ?? 5
        self.pomodoroLongBreakMinutes = defaults.object(forKey: "pomodoroLongBreakMinutes") as? Int ?? 15
        self.pomodoroSessionsBeforeLong = defaults.object(forKey: "pomodoroSessionsBeforeLong") as? Int ?? 4
        self.countdownMinutes = defaults.object(forKey: "countdownMinutes") as? Int ?? 25
        self.use24HourClock = defaults.object(forKey: "use24HourClock") as? Bool ?? true
        self.defaultTimerMode = TimerMode(rawValue: defaults.string(forKey: "defaultTimerMode") ?? "") ?? .stopwatch
        self.sessionGapSeconds = defaults.object(forKey: "sessionGapSeconds") as? Int ?? 300
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
}

// MARK: - Timer Models

enum TimerMode: String, Codable, CaseIterable, Sendable {
    case pomodoro  = "Pomodoro"
    case countdown = "Countdown"
    case stopwatch = "Stopwatch"
    var icon: String {
        switch self { case .pomodoro: "timer"; case .countdown: "hourglass"; case .stopwatch: "stopwatch" }
    }
}

enum PomodoroPhase: String, Sendable {
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
    var emoji: String = "🚫"            // card icon
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
