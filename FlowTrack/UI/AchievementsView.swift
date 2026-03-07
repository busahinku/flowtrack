import SwiftUI

// MARK: - AchievementsView
/// Displays earned achievement badges in a scrollable grid.
struct AchievementsView: View {
    @Bindable private var engine = AchievementEngine.shared
    private var theme: AppTheme { AppSettings.shared.appTheme }

    private let columns = [GridItem(.adaptive(minimum: 140, maximum: 180), spacing: 12)]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "trophy.fill")
                    .foregroundStyle(theme.accentColor)
                Text("Achievements")
                    .font(.headline)
                    .foregroundStyle(theme.primaryText)
                Spacer()
                Text("\(engine.unlockedAchievements.count)/\(AchievementID.allCases.count)")
                    .font(.caption)
                    .foregroundStyle(theme.secondaryText)
            }

            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(AchievementID.allCases, id: \.self) { id in
                    BadgeCell(id: id, unlocked: engine.unlockedIDs.contains(id),
                              unlockedAt: engine.unlockedAchievements.first(where: { $0.achievementID == id })?.unlockedAt)
                }
            }
        }
        .padding(16)
        .background(theme.cardBg, in: RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - BadgeCell

private struct BadgeCell: View {
    let id: AchievementID
    let unlocked: Bool
    let unlockedAt: Date?
    private var theme: AppTheme { AppSettings.shared.appTheme }

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle()
                    .fill(unlocked ? theme.accentColor.opacity(0.15) : theme.secondaryText.opacity(0.06))
                    .frame(width: 52, height: 52)
                Text(id.emoji)
                    .font(.title2)
                    .opacity(unlocked ? 1 : 0.25)
                if !unlocked {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(theme.secondaryText.opacity(0.45))
                        .offset(x: 16, y: 16)
                }
            }
            Text(id.title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(unlocked ? theme.primaryText : theme.secondaryText.opacity(0.5))
                .multilineTextAlignment(.center)
                .lineLimit(2)
            if let date = unlockedAt {
                Text(date, style: .date)
                    .font(.system(size: 9))
                    .foregroundStyle(theme.secondaryText.opacity(0.6))
            } else {
                Text(id.description)
                    .font(.system(size: 9))
                    .foregroundStyle(theme.secondaryText.opacity(0.4))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(unlocked ? theme.accentColor.opacity(0.05) : Color.clear)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(unlocked ? theme.accentColor.opacity(0.25) : theme.secondaryText.opacity(0.1), lineWidth: 1)
                )
        )
    }
}
