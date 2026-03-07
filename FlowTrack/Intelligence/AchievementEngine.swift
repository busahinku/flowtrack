import Foundation
import UserNotifications
import OSLog

private let achLog = Logger(subsystem: "com.flowtrack", category: "Achievements")

// MARK: - AchievementID

enum AchievementID: String, Codable, CaseIterable {
    case firstSession    = "first_session"
    case deepWork        = "deep_work"        // 2-hour session
    case marathon        = "marathon"          // 3-hour session
    case ultraFocus      = "ultra_focus"       // 5-hour session
    case streak3         = "streak_3"
    case streak7         = "streak_7"
    case streak30        = "streak_30"
    case earlyBird       = "early_bird"        // started before 7 AM
    case nightOwl        = "night_owl"         // started after 10 PM
    case pomodoroMaster  = "pomodoro_master"   // 10 sessions in one day

    var title: String {
        switch self {
        case .firstSession:   return "First Steps"
        case .deepWork:       return "Deep Work"
        case .marathon:       return "Marathon"
        case .ultraFocus:     return "Ultra Focus"
        case .streak3:        return "On a Roll"
        case .streak7:        return "Week Warrior"
        case .streak30:       return "Monthly Master"
        case .earlyBird:      return "Early Bird"
        case .nightOwl:       return "Night Owl"
        case .pomodoroMaster: return "Session Master"
        }
    }

    var description: String {
        switch self {
        case .firstSession:   return "Complete your first focus session"
        case .deepWork:       return "Focus for 2 hours in one session"
        case .marathon:       return "Focus for 3 hours in one session"
        case .ultraFocus:     return "Focus for 5 hours in one session"
        case .streak3:        return "Maintain a 3-day focus streak"
        case .streak7:        return "Maintain a 7-day focus streak"
        case .streak30:       return "Maintain a 30-day focus streak"
        case .earlyBird:      return "Start a focus session before 7:00 AM"
        case .nightOwl:       return "Start a focus session after 10:00 PM"
        case .pomodoroMaster: return "Complete 10 sessions in one day"
        }
    }

    var emoji: String {
        switch self {
        case .firstSession:   return "🌱"
        case .deepWork:       return "🎯"
        case .marathon:       return "🏃"
        case .ultraFocus:     return "🏆"
        case .streak3:        return "🔥"
        case .streak7:        return "⚡"
        case .streak30:       return "💎"
        case .earlyBird:      return "🌅"
        case .nightOwl:       return "🦉"
        case .pomodoroMaster: return "🍅"
        }
    }
}

// MARK: - Achievement (record of an unlocked badge)

struct Achievement: Identifiable, Codable {
    var id: AchievementID { achievementID }
    let achievementID: AchievementID
    let unlockedAt: Date
}

// MARK: - AchievementEngine

@MainActor @Observable
final class AchievementEngine {
    static let shared = AchievementEngine()

    private(set) var unlockedAchievements: [Achievement] = []
    private let storageKey = "com.flowtrack.achievements.v1"

    private init() {
        load()
    }

    var unlockedIDs: Set<AchievementID> {
        Set(unlockedAchievements.map(\.achievementID))
    }

    // MARK: - Unlock

    func unlock(_ id: AchievementID) {
        guard !unlockedIDs.contains(id) else { return }
        let achievement = Achievement(achievementID: id, unlockedAt: Date())
        unlockedAchievements.append(achievement)
        unlockedAchievements.sort { $0.unlockedAt > $1.unlockedAt }
        save()
        sendNotification(for: achievement)
        achLog.info("Achievement unlocked: \(id.rawValue)")
    }

    // MARK: - Check triggers (called from TimerStore and AppState)

    /// Call after any timer session ends.
    func checkSessionAchievements(duration: TimeInterval, startedAt: Date) {
        unlock(.firstSession)
        if duration >= 2 * 3600 { unlock(.deepWork) }
        if duration >= 3 * 3600 { unlock(.marathon) }
        if duration >= 5 * 3600 { unlock(.ultraFocus) }
        let hour = Calendar.current.component(.hour, from: startedAt)
        if hour < 7  { unlock(.earlyBird) }
        if hour >= 22 { unlock(.nightOwl) }
    }

    /// Call whenever the focus streak value is updated.
    func checkStreakAchievements(streak: Int) {
        if streak >= 3  { unlock(.streak3) }
        if streak >= 7  { unlock(.streak7) }
        if streak >= 30 { unlock(.streak30) }
    }

    /// Call when session work phases complete for today.
    func checkSessionAchievement(completedToday: Int) {
        if completedToday >= 10 { unlock(.pomodoroMaster) }
    }

    // MARK: - Persistence

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([Achievement].self, from: data) else { return }
        unlockedAchievements = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(unlockedAchievements) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }

    // MARK: - Notification

    private func sendNotification(for achievement: Achievement) {
        let id = achievement.achievementID
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "Achievement Unlocked \(id.emoji)"
            content.body  = "\(id.title) — \(id.description)"
            content.sound = .default
            let req = UNNotificationRequest(
                identifier: "achievement-\(id.rawValue)",
                content: content,
                trigger: nil
            )
            UNUserNotificationCenter.current().add(req) { err in
                if let err { achLog.error("Achievement notification error: \(err.localizedDescription)") }
            }
        }
    }
}
