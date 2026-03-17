import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

// MARK: - Theme (@Observable singleton)

@MainActor @Observable
final class Theme {
  static let shared = Theme()

  private(set) var selectedColorSet: ColorSetName = .system
  private(set) var cardBackgroundColor: Color = .white
  private(set) var timelineBackgroundColor: Color = .white
  private(set) var sidebarBackgroundColor: Color = .white
  private(set) var gridLineColor: Color = .gray
  private(set) var hourLabelColor: Color = .secondary
  private(set) var accentColor: Color = .blue
  private(set) var primaryTextColor: Color = .primary
  private(set) var secondaryTextColor: Color = .secondary
  private(set) var successColor: Color = .green
  private(set) var errorColor: Color = .red
  private(set) var warningColor: Color = .orange
  private(set) var infoColor: Color = .blue
  private(set) var nowLineColor: Color = .red
  private(set) var selectedForegroundColor: Color = .white
  private(set) var shadowColor: Color = .black
  private(set) var dividerColor: Color = .gray

  var colorScheme: ColorScheme? { selectedColorSet.colorSet.colorScheme }

  private init() {
    applySet(.system)
  }

  func applySet(_ name: ColorSetName) {
    selectedColorSet = name
    let set = name.colorSet
    cardBackgroundColor = set.cardBackgroundColor
    timelineBackgroundColor = set.timelineBackgroundColor
    sidebarBackgroundColor = set.sidebarBackgroundColor
    gridLineColor = set.gridLineColor
    hourLabelColor = set.hourLabelColor
    accentColor = set.accentColor
    primaryTextColor = set.primaryTextColor
    secondaryTextColor = set.secondaryTextColor
    successColor = set.successColor
    errorColor = set.errorColor
    warningColor = set.warningColor
    infoColor = set.infoColor
    nowLineColor = set.nowLineColor
    selectedForegroundColor = set.selectedForegroundColor
    shadowColor = set.shadowColor
    dividerColor = set.dividerColor
  }

  func menuBarIconName(under colorScheme: ColorScheme?) -> String {
    switch selectedColorSet {
    case .system:
      return (colorScheme == .dark) ? "WhiteLogo" : "DarkLogo"
    case .light:
      return "DarkLogo"
    case .dark, .midnight:
      return "WhiteLogo"
    case .pastel:
      return "PastelLogo"
    }
  }
}

// MARK: - Menu bar icon: template image so macOS auto-colors it like all other menu bar icons
struct MenuBarIconView: View {
  var size: CGFloat = 18

  var body: some View {
    Image(nsImage: templateIcon(size: size))
      .resizable()
      .aspectRatio(contentMode: .fit)
      .frame(width: size, height: size)
  }

  /// Loads DarkLogo and marks it as a template image.
  /// macOS then renders it in the correct menu bar foreground color automatically.
  private func templateIcon(size: CGFloat) -> NSImage {
    guard let source = NSImage(named: "DarkLogo") else {
      let fallback = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: nil) ?? NSImage()
      fallback.isTemplate = true
      return fallback
    }
    let targetSize = NSSize(width: size, height: size)
    let scaled = NSImage(size: targetSize)
    scaled.lockFocus()
    NSGraphicsContext.current?.imageInterpolation = .high
    source.draw(
      in: NSRect(origin: .zero, size: targetSize),
      from: NSRect(origin: .zero, size: source.size),
      operation: .copy, fraction: 1)
    scaled.unlockFocus()
    scaled.isTemplate = true
    return scaled
  }
}

// MARK: - Theme-aware icon for in-app only (headers, onboarding) — uses app theme
struct ThemeAwareMenuIcon: View {
  @Environment(\.colorScheme) private var colorScheme

  var size: CGFloat = 18

  var body: some View {
    Group {
      if let nsImage = loadIcon(name: Theme.shared.menuBarIconName(under: colorScheme), side: size) {
        Image(nsImage: nsImage)
          .resizable()
          .aspectRatio(contentMode: .fit)
      } else {
        Image(systemName: "bolt.fill")
          .font(.system(size: size))
      }
    }
    .frame(width: size, height: size)
  }

  private func loadIcon(name: String, side: CGFloat) -> NSImage? {
    guard let img = NSImage(named: name) else { return nil }
    let targetSize = NSSize(width: side, height: side)
    let newImage = NSImage(size: targetSize)
    newImage.lockFocus()
    NSGraphicsContext.current?.imageInterpolation = .high
    img.draw(
      in: NSRect(origin: .zero, size: targetSize),
      from: NSRect(origin: .zero, size: img.size),
      operation: .copy,
      fraction: 1)
    newImage.unlockFocus()
    return newImage
  }
}
