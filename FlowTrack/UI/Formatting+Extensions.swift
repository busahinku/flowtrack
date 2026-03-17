import Foundation
import SwiftUI

// MARK: - TimeInterval formatting

extension TimeInterval {
  func formattedDuration() -> String {
    let h = Int(self) / 3600
    let m = (Int(self) % 3600) / 60
    if h > 0 { return "\(h)h \(m)m" }
    if m > 0 { return "\(m)m" }
    return "<1m"
  }
}

// MARK: - Date formatting

extension Date {
  private static let formatterAMPM: DateFormatter = {
    let f = DateFormatter(); f.dateFormat = "h:mm a"; return f
  }()

  private static let formatter24h: DateFormatter = {
    let f = DateFormatter(); f.dateFormat = "HH:mm"; return f
  }()

  @MainActor
  func formattedTime() -> String {
    let f = SettingsStorage.shared.use24HourClock ? Self.formatter24h : Self.formatterAMPM
    return f.string(from: self)
  }

  @MainActor
  func formattedRange(to end: Date) -> String {
    "\(formattedTime()) – \(end.formattedTime())"
  }
}

// MARK: - Category color

extension Category {
  var color: Color { CategoryManager.shared.color(for: self) }
}
