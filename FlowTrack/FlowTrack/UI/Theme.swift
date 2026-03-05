import SwiftUI

// MARK: - AppTheme
enum AppTheme: String, CaseIterable, Identifiable, Sendable {
    case system = "System"
    case light = "Light"
    case dark = "Dark"
    case pastel = "Pastel"
    case midnight = "Midnight"

    var id: String { rawValue }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light, .pastel: return .light
        case .dark, .midnight: return .dark
        }
    }

    // System uses the Light or Dark values depending on macOS appearance
    var cardBg: Color {
        switch self {
        case .system: return Color(nsColor: .textBackgroundColor)
        case .light: return .white
        case .dark: return Color(red: 0.15, green: 0.15, blue: 0.17)
        case .pastel: return Color(red: 0.96, green: 0.95, blue: 0.98)
        case .midnight: return Color(red: 0.10, green: 0.10, blue: 0.18)
        }
    }

    var timelineBg: Color {
        switch self {
        case .system: return Color(nsColor: .textBackgroundColor).opacity(0.95)
        case .light: return Color(red: 0.97, green: 0.97, blue: 0.98)
        case .dark: return Color(red: 0.10, green: 0.10, blue: 0.12)
        case .pastel: return Color(red: 0.98, green: 0.97, blue: 1.0)
        case .midnight: return Color(red: 0.06, green: 0.06, blue: 0.12)
        }
    }

    var sidebarBg: Color {
        switch self {
        case .system: return Color(nsColor: .windowBackgroundColor)
        case .light: return Color(red: 0.95, green: 0.95, blue: 0.97)
        case .dark: return Color(red: 0.12, green: 0.12, blue: 0.14)
        case .pastel: return Color(red: 0.94, green: 0.93, blue: 0.97)
        case .midnight: return Color(red: 0.07, green: 0.07, blue: 0.14)
        }
    }

    var gridLineColor: Color {
        switch self {
        case .system: return Color(nsColor: .separatorColor)
        case .light: return Color.gray.opacity(0.2)
        case .dark: return Color.gray.opacity(0.15)
        case .pastel: return Color.purple.opacity(0.1)
        case .midnight: return Color.blue.opacity(0.15)
        }
    }

    var hourLabelColor: Color {
        switch self {
        case .system: return .secondary
        case .light: return .secondary
        case .dark: return Color.gray
        case .pastel: return Color(red: 0.5, green: 0.4, blue: 0.6)
        case .midnight: return Color(red: 0.4, green: 0.4, blue: 0.7)
        }
    }

    var accentColor: Color {
        switch self {
        case .system, .light, .dark: return .blue
        case .pastel: return Color(red: 0.6, green: 0.4, blue: 0.8)
        case .midnight: return Color(red: 0.3, green: 0.4, blue: 0.9)
        }
    }
}

// MARK: - Theme Helpers
enum Theme {
    static var current: AppTheme {
        AppSettings.shared.appTheme
    }

    static func color(for category: Category) -> Color {
        CategoryManager.shared.color(for: category)
    }

    static func formatDuration(_ seconds: Double) -> String {
        let h = Int(seconds) / 3600
        let m = (Int(seconds) % 3600) / 60
        if h > 0 { return "\(h)h \(m)m" }
        if m > 0 { return "\(m)m" }
        return "<1m"
    }

    static func formatTime(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return f.string(from: date)
    }

    static func formatTimeRange(_ start: Date, _ end: Date) -> String {
        "\(formatTime(start)) – \(formatTime(end))"
    }
}
