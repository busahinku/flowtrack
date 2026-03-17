import Foundation
import SwiftUI

// MARK: - SettingsStorage

@MainActor @Observable
final class SettingsStorage {
  static let shared = SettingsStorage()

  let storage = Storage()

  // MARK: AI

  var aiProvider: AIProviderType {
    didSet { storage.aiProvider = aiProvider.rawValue }
  }

  var secondaryProvider: AIProviderType? {
    didSet { storage.secondaryProviderRaw = secondaryProvider?.rawValue ?? "" }
  }

  var tertiaryProvider: AIProviderType? {
    didSet { storage.tertiaryProviderRaw = tertiaryProvider?.rawValue ?? "" }
  }

  var aiSummariesEnabled: Bool {
    didSet { storage.aiSummariesEnabled = aiSummariesEnabled }
  }

  var aiBatchIntervalMinutes: Int {
    didSet {
      storage.aiBatchIntervalMinutes = aiBatchIntervalMinutes
      AppState.shared.resetAITimer()
    }
  }

  var aiBatchSize: Int {
    didSet { storage.aiBatchSize = aiBatchSize }
  }

  // MARK: General

  var showDockIcon: Bool {
    didSet {
      storage.showDockIcon = showDockIcon
      NSApp?.setActivationPolicy(showDockIcon ? .regular : .accessory)
    }
  }

  var showAppIcons: Bool {
    didSet { storage.showAppIcons = showAppIcons }
  }

  var launchAtLogin: Bool {
    didSet { storage.launchAtLogin = launchAtLogin }
  }

  var hasCompletedOnboarding: Bool {
    didSet { storage.hasCompletedOnboarding = hasCompletedOnboarding }
  }

  var appTheme: ColorSetName {
    didSet {
      storage.appTheme = appTheme.rawValue
      Theme.shared.applySet(appTheme)
    }
  }

  var use24HourClock: Bool {
    didSet { storage.use24HourClock = use24HourClock }
  }

  // MARK: Tracking

  var captureWindowTitles: Bool {
    didSet { storage.captureWindowTitles = captureWindowTitles }
  }

  var excludedBundleIDs: [String] {
    didSet {
      if let data = try? JSONEncoder().encode(excludedBundleIDs),
        let json = String(data: data, encoding: .utf8)
      {
        storage.excludedBundleIDsRaw = json
      }
    }
  }

  var idleThresholdSeconds: Int {
    didSet { storage.idleThresholdSeconds = idleThresholdSeconds }
  }

  var distractionAlertMinutes: Int {
    didSet { storage.distractionAlertMinutes = distractionAlertMinutes }
  }

  var retentionDays: Int {
    didSet { storage.retentionDays = retentionDays }
  }

  // MARK: Timer / Session

  var sessionWorkMinutes: Int {
    didSet { storage.sessionWorkMinutes = sessionWorkMinutes }
  }

  var sessionBreakMinutes: Int {
    didSet { storage.sessionBreakMinutes = sessionBreakMinutes }
  }

  var sessionLongBreakMinutes: Int {
    didSet { storage.sessionLongBreakMinutes = sessionLongBreakMinutes }
  }

  var sessionsBeforeLong: Int {
    didSet { storage.sessionsBeforeLong = sessionsBeforeLong }
  }

  var countdownMinutes: Int {
    didSet { storage.countdownMinutes = countdownMinutes }
  }

  var defaultTimerMode: TimerMode {
    didSet { storage.defaultTimerMode = defaultTimerMode.rawValue }
  }

  var sessionGapSeconds: Int {
    didSet { storage.sessionGapSeconds = sessionGapSeconds }
  }

  // MARK: Sync

  var syncProvider: SyncProvider {
    didSet { storage.syncProvider = syncProvider.rawValue }
  }

  var lastSyncDate: Date? {
    didSet { storage.lastSyncDateInterval = lastSyncDate?.timeIntervalSince1970 ?? 0 }
  }

  var autoSyncEnabled: Bool {
    didSet { storage.autoSyncEnabled = autoSyncEnabled }
  }

  var autoSyncIntervalDays: Int {
    didSet { storage.autoSyncIntervalDays = autoSyncIntervalDays }
  }

  // MARK: Dynamic model keys

  func modelName(for provider: AIProviderType) -> String {
    UserDefaults.standard.string(forKey: "model_\(provider.rawValue)") ?? provider.defaultModel
  }

  func setModelName(_ name: String, for provider: AIProviderType) {
    UserDefaults.standard.set(name, forKey: "model_\(provider.rawValue)")
  }

  var currentModelName: String {
    modelName(for: aiProvider)
  }

  // MARK: Init

  private init() {
    // Migrate old array-format excludedBundleIDs if present
    let defaults = UserDefaults.standard
    if let oldArray = defaults.stringArray(forKey: "excludedBundleIDs"),
      defaults.string(forKey: "excludedBundleIDs") == nil
        || (defaults.object(forKey: "excludedBundleIDs") is [String])
    {
      if let data = try? JSONEncoder().encode(oldArray),
        let json = String(data: data, encoding: .utf8)
      {
        defaults.set(json, forKey: "excludedBundleIDs")
      }
    }

    // Read all values from storage
    self.aiProvider = AIProviderType(rawValue: storage.aiProvider) ?? .claudeCLI
    let secRaw = storage.secondaryProviderRaw
    self.secondaryProvider = secRaw.isEmpty ? nil : AIProviderType(rawValue: secRaw)
    let terRaw = storage.tertiaryProviderRaw
    self.tertiaryProvider = terRaw.isEmpty ? nil : AIProviderType(rawValue: terRaw)
    self.aiSummariesEnabled = storage.aiSummariesEnabled
    self.aiBatchIntervalMinutes = storage.aiBatchIntervalMinutes
    self.aiBatchSize = storage.aiBatchSize
    self.showDockIcon = storage.showDockIcon
    self.showAppIcons = storage.showAppIcons
    self.launchAtLogin = storage.launchAtLogin
    self.hasCompletedOnboarding = storage.hasCompletedOnboarding
    self.appTheme = ColorSetName(rawValue: storage.appTheme) ?? .system
    self.use24HourClock = storage.use24HourClock
    self.captureWindowTitles = storage.captureWindowTitles

    // Decode excludedBundleIDs from JSON string
    let idsRaw = storage.excludedBundleIDsRaw
    if let data = idsRaw.data(using: .utf8),
      let decoded = try? JSONDecoder().decode([String].self, from: data)
    {
      self.excludedBundleIDs = decoded
    } else {
      self.excludedBundleIDs = []
    }

    self.idleThresholdSeconds = storage.idleThresholdSeconds
    self.distractionAlertMinutes = storage.distractionAlertMinutes
    self.retentionDays = storage.retentionDays

    // Session — support legacy pomodoro keys
    let workKey = defaults.object(forKey: "sessionWorkMinutes") ?? defaults.object(forKey: "pomodoroWorkMinutes")
    self.sessionWorkMinutes = (workKey as? Int) ?? storage.sessionWorkMinutes
    let breakKey = defaults.object(forKey: "sessionBreakMinutes") ?? defaults.object(forKey: "pomodoroBreakMinutes")
    self.sessionBreakMinutes = (breakKey as? Int) ?? storage.sessionBreakMinutes
    let longBreakKey = defaults.object(forKey: "sessionLongBreakMinutes") ?? defaults.object(forKey: "pomodoroLongBreakMinutes")
    self.sessionLongBreakMinutes = (longBreakKey as? Int) ?? storage.sessionLongBreakMinutes
    let sessionsKey = defaults.object(forKey: "sessionsBeforeLong") ?? defaults.object(forKey: "pomodoroSessionsBeforeLong")
    self.sessionsBeforeLong = (sessionsKey as? Int) ?? storage.sessionsBeforeLong

    self.countdownMinutes = storage.countdownMinutes
    self.defaultTimerMode = TimerMode(rawValue: storage.defaultTimerMode) ?? .stopwatch
    self.sessionGapSeconds = storage.sessionGapSeconds
    self.syncProvider = SyncProvider(rawValue: storage.syncProvider) ?? .none
    let syncInterval = storage.lastSyncDateInterval
    self.lastSyncDate = syncInterval > 0 ? Date(timeIntervalSince1970: syncInterval) : nil
    self.autoSyncEnabled = storage.autoSyncEnabled
    self.autoSyncIntervalDays = storage.autoSyncIntervalDays

    // Apply theme
    Theme.shared.applySet(appTheme)
  }
}

// MARK: - Storage (inner @AppStorage class)

extension SettingsStorage {
  final class Storage {
    // AI
    @AppStorage("aiProvider") var aiProvider: String = AIProviderType.claudeCLI.rawValue
    @AppStorage("secondaryProvider") var secondaryProviderRaw: String = ""
    @AppStorage("tertiaryProvider") var tertiaryProviderRaw: String = ""
    @AppStorage("aiSummariesEnabled") var aiSummariesEnabled: Bool = true
    @AppStorage("aiBatchIntervalMinutes") var aiBatchIntervalMinutes: Int = 30
    @AppStorage("aiBatchSize") var aiBatchSize: Int = 30

    // General
    @AppStorage("showDockIcon") var showDockIcon: Bool = false
    @AppStorage("showAppIcons") var showAppIcons: Bool = true
    @AppStorage("launchAtLogin") var launchAtLogin: Bool = false
    @AppStorage("hasCompletedOnboarding") var hasCompletedOnboarding: Bool = false
    @AppStorage("appTheme") var appTheme: String = ColorSetName.system.rawValue
    @AppStorage("use24HourClock") var use24HourClock: Bool = true

    // Tracking
    @AppStorage("captureWindowTitles") var captureWindowTitles: Bool = true
    @AppStorage("excludedBundleIDs") var excludedBundleIDsRaw: String = "[]"
    @AppStorage("idleThresholdSeconds") var idleThresholdSeconds: Int = 120
    @AppStorage("distractionAlertMinutes") var distractionAlertMinutes: Int = 0
    @AppStorage("retentionDays") var retentionDays: Int = 90

    // Timer / Session
    @AppStorage("sessionWorkMinutes") var sessionWorkMinutes: Int = 25
    @AppStorage("sessionBreakMinutes") var sessionBreakMinutes: Int = 5
    @AppStorage("sessionLongBreakMinutes") var sessionLongBreakMinutes: Int = 15
    @AppStorage("sessionsBeforeLong") var sessionsBeforeLong: Int = 4
    @AppStorage("countdownMinutes") var countdownMinutes: Int = 25
    @AppStorage("defaultTimerMode") var defaultTimerMode: String = TimerMode.stopwatch.rawValue
    @AppStorage("sessionGapSeconds") var sessionGapSeconds: Int = 300

    // Sync
    @AppStorage("syncProvider") var syncProvider: String = SyncProvider.none.rawValue
    @AppStorage("lastSyncDate") var lastSyncDateInterval: Double = 0
    @AppStorage("autoSyncEnabled") var autoSyncEnabled: Bool = false
    @AppStorage("autoSyncIntervalDays") var autoSyncIntervalDays: Int = 1
  }
}
