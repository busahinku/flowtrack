import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

// MARK: - ColorSetName

enum ColorSetName: String, CaseIterable, Identifiable, Sendable {
  case system = "System"
  case light = "Light"
  case dark = "Dark"
  case pastel = "Pastel"
  case midnight = "Midnight"

  var id: String { rawValue }

  var colorSet: any ColorSet {
    switch self {
    case .system: SystemColorSet()
    case .light: LightColorSet()
    case .dark: DarkColorSet()
    case .pastel: PastelColorSet()
    case .midnight: MidnightColorSet()
    }
  }
}

// MARK: - ColorSet Protocol

protocol ColorSet: Sendable {
  var name: ColorSetName { get }
  var colorScheme: ColorScheme? { get }
  var cardBackgroundColor: Color { get }
  var timelineBackgroundColor: Color { get }
  var sidebarBackgroundColor: Color { get }
  var gridLineColor: Color { get }
  var hourLabelColor: Color { get }
  var accentColor: Color { get }
  var primaryTextColor: Color { get }
  var secondaryTextColor: Color { get }
  var successColor: Color { get }
  var errorColor: Color { get }
  var warningColor: Color { get }
  var infoColor: Color { get }
  var nowLineColor: Color { get }
  var selectedForegroundColor: Color { get }
  var shadowColor: Color { get }
  var dividerColor: Color { get }
}

extension ColorSet {
  var nowLineColor: Color { errorColor }
}

// MARK: - System

struct SystemColorSet: ColorSet {
  let name = ColorSetName.system
  let colorScheme: ColorScheme? = nil
  var cardBackgroundColor: Color { Color(nsColor: .textBackgroundColor) }
  var timelineBackgroundColor: Color { Color(nsColor: .textBackgroundColor).opacity(0.95) }
  var sidebarBackgroundColor: Color { Color(nsColor: .windowBackgroundColor) }
  var gridLineColor: Color { Color(nsColor: .separatorColor) }
  let hourLabelColor: Color = .secondary
  let accentColor: Color = .blue
  var primaryTextColor: Color { Color(nsColor: .labelColor) }
  var secondaryTextColor: Color { Color(nsColor: .secondaryLabelColor) }
  let successColor: Color = .green
  let errorColor: Color = .red
  let warningColor: Color = .orange
  let infoColor: Color = .blue
  let selectedForegroundColor: Color = .white
  let shadowColor: Color = .black
  var dividerColor: Color { Color(nsColor: .separatorColor) }
}

// MARK: - Light

struct LightColorSet: ColorSet {
  let name = ColorSetName.light
  let colorScheme: ColorScheme? = .light
  let cardBackgroundColor: Color = .white
  let timelineBackgroundColor = Color(red: 0.97, green: 0.97, blue: 0.98)
  let sidebarBackgroundColor = Color(red: 0.95, green: 0.95, blue: 0.97)
  let gridLineColor = Color.gray.opacity(0.2)
  let hourLabelColor: Color = .secondary
  let accentColor: Color = .blue
  let primaryTextColor = Color(white: 0.10)
  let secondaryTextColor = Color(white: 0.45)
  let successColor = Color(red: 0.18, green: 0.65, blue: 0.32)
  let errorColor = Color(red: 0.85, green: 0.20, blue: 0.20)
  let warningColor = Color(red: 0.92, green: 0.55, blue: 0.10)
  let infoColor = Color(red: 0.20, green: 0.45, blue: 0.95)
  let selectedForegroundColor: Color = .white
  let shadowColor: Color = .black
  let dividerColor = Color(white: 0.70)
}

// MARK: - Dark

struct DarkColorSet: ColorSet {
  let name = ColorSetName.dark
  let colorScheme: ColorScheme? = .dark
  let cardBackgroundColor = Color(red: 0.15, green: 0.15, blue: 0.17)
  let timelineBackgroundColor = Color(red: 0.10, green: 0.10, blue: 0.12)
  let sidebarBackgroundColor = Color(red: 0.12, green: 0.12, blue: 0.14)
  let gridLineColor = Color.gray.opacity(0.15)
  let hourLabelColor = Color.gray
  let accentColor: Color = .blue
  let primaryTextColor = Color(white: 0.92)
  let secondaryTextColor = Color(white: 0.50)
  let successColor = Color(red: 0.25, green: 0.82, blue: 0.45)
  let errorColor = Color(red: 1.0, green: 0.40, blue: 0.40)
  let warningColor = Color(red: 1.0, green: 0.72, blue: 0.28)
  let infoColor = Color(red: 0.40, green: 0.67, blue: 1.0)
  let selectedForegroundColor: Color = .white
  let shadowColor: Color = .black
  let dividerColor = Color(white: 0.40)
}

// MARK: - Pastel

struct PastelColorSet: ColorSet {
  let name = ColorSetName.pastel
  let colorScheme: ColorScheme? = .light
  let cardBackgroundColor = Color(red: 0.96, green: 0.95, blue: 0.98)
  let timelineBackgroundColor = Color(red: 0.98, green: 0.97, blue: 1.0)
  let sidebarBackgroundColor = Color(red: 0.94, green: 0.93, blue: 0.97)
  let gridLineColor = Color.purple.opacity(0.1)
  let hourLabelColor = Color(red: 0.5, green: 0.4, blue: 0.6)
  let accentColor = Color(red: 0.6, green: 0.4, blue: 0.8)
  let primaryTextColor = Color(red: 0.22, green: 0.18, blue: 0.32)
  let secondaryTextColor = Color(red: 0.50, green: 0.42, blue: 0.62)
  let successColor = Color(red: 0.28, green: 0.68, blue: 0.52)
  let errorColor = Color(red: 0.88, green: 0.40, blue: 0.55)
  let warningColor = Color(red: 0.93, green: 0.62, blue: 0.38)
  let infoColor = Color(red: 0.55, green: 0.40, blue: 0.88)
  let selectedForegroundColor: Color = .white
  let shadowColor = Color(red: 0.40, green: 0.20, blue: 0.60)
  let dividerColor = Color(red: 0.60, green: 0.40, blue: 0.80)
}

// MARK: - Midnight

struct MidnightColorSet: ColorSet {
  let name = ColorSetName.midnight
  let colorScheme: ColorScheme? = .dark
  let cardBackgroundColor = Color(red: 0.10, green: 0.10, blue: 0.18)
  let timelineBackgroundColor = Color(red: 0.06, green: 0.06, blue: 0.12)
  let sidebarBackgroundColor = Color(red: 0.07, green: 0.07, blue: 0.14)
  let gridLineColor = Color.blue.opacity(0.15)
  let hourLabelColor = Color(red: 0.4, green: 0.4, blue: 0.7)
  let accentColor = Color(red: 0.3, green: 0.4, blue: 0.9)
  let primaryTextColor = Color(red: 0.82, green: 0.86, blue: 1.0)
  let secondaryTextColor = Color(red: 0.45, green: 0.50, blue: 0.72)
  let successColor = Color(red: 0.18, green: 0.88, blue: 0.62)
  let errorColor = Color(red: 1.0, green: 0.32, blue: 0.48)
  let warningColor = Color(red: 1.0, green: 0.76, blue: 0.28)
  let infoColor = Color(red: 0.38, green: 0.58, blue: 1.0)
  let selectedForegroundColor = Color(red: 0.88, green: 0.92, blue: 1.0)
  let shadowColor: Color = .black
  let dividerColor = Color(red: 0.25, green: 0.30, blue: 0.65)
}
