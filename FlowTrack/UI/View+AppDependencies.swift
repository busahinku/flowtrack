import SwiftUI

extension View {
  func withAppDependency() -> some View {
    environment(Theme.shared)
      .environment(SettingsStorage.shared)
  }

  func withEnvironment() -> some View {
    environment(Theme.shared)
      .environment(SettingsStorage.shared)
  }
}
