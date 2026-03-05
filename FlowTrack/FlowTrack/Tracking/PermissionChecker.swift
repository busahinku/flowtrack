import Foundation
import AppKit

struct PermissionChecker {
    static var hasAccessibility: Bool {
        AXIsProcessTrusted()
    }

    static func requestAccessibility() {
        let options: [String: Any] = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: true]
        AXIsProcessTrustedWithOptions(options as CFDictionary)
    }
}
