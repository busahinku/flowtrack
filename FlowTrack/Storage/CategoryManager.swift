import Foundation
import SwiftUI

// MARK: - CategoryDefinition
struct CategoryDefinition: Codable, Hashable, Identifiable, Sendable {
    var name: String
    var colorHex: String
    var icon: String
    var isProductive: Bool
    var isSystem: Bool
    var aiPrompt: String

    var id: String { name }

    var color: Color { Color(hex: colorHex) }

    // Migration: decode without aiPrompt for old data
    init(name: String, colorHex: String, icon: String, isProductive: Bool, isSystem: Bool, aiPrompt: String = "") {
        self.name = name
        self.colorHex = colorHex
        self.icon = icon
        self.isProductive = isProductive
        self.isSystem = isSystem
        self.aiPrompt = aiPrompt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        colorHex = try c.decode(String.self, forKey: .colorHex)
        icon = try c.decode(String.self, forKey: .icon)
        isProductive = try c.decode(Bool.self, forKey: .isProductive)
        isSystem = try c.decode(Bool.self, forKey: .isSystem)
        aiPrompt = (try? c.decode(String.self, forKey: .aiPrompt)) ?? ""
    }
}

// MARK: - CategoryManager
final class CategoryManager: @unchecked Sendable {
    static let shared = CategoryManager()

    private var definitions: [CategoryDefinition]
    private let fileURL: URL
    private let lock = NSLock()

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let folder = appSupport.appendingPathComponent("FlowTrack")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        self.fileURL = folder.appendingPathComponent("categories.json")

        if let data = try? Data(contentsOf: fileURL),
           let loaded = try? JSONDecoder().decode([CategoryDefinition].self, from: data) {
            self.definitions = loaded
            // Migrate: add missing categories and aiPrompts; remap removed categories
            migrateDefaults()
        } else {
            self.definitions = Self.defaultDefinitions
            saveLocked()  // init is single-threaded, no lock needed
        }
    }

    private func migrateDefaults() {
        lock.lock()
        defer { lock.unlock() }

        var changed = false
        let defaults = Dictionary(uniqueKeysWithValues: Self.defaultDefinitions.map { ($0.name, $0) })

        // Remap removed categories to their new homes and update DB records
        let remapped = ["Communication": "Work", "Learning": "Work", "Health": "Distraction",
                        "Productivity": "Work", "Creative": "Work",
                        "Personal": "Distraction", "Entertainment": "Distraction"]
        for (old, new) in remapped {
            if let idx = definitions.firstIndex(where: { $0.name == old }) {
                definitions.remove(at: idx)
                changed = true
                Database.shared.remapCategory(from: old, to: new)
            }
        }

        // Add default categories that don't exist yet
        for def in Self.defaultDefinitions {
            if !definitions.contains(where: { $0.name == def.name }) {
                definitions.append(def)
                changed = true
            }
        }
        // Fill in empty aiPrompts from defaults
        for i in definitions.indices {
            if definitions[i].aiPrompt.isEmpty, let d = defaults[definitions[i].name] {
                definitions[i].aiPrompt = d.aiPrompt
                changed = true
            }
        }
        if changed { saveLocked() }
    }

    static let defaultDefinitions: [CategoryDefinition] = [
        CategoryDefinition(name: "Work", colorHex: "#3B82F6", icon: "briefcase.fill", isProductive: true, isSystem: false,
                           aiPrompt: "Coding, software development, IDEs, terminals, Git, programming tools, DevOps, databases, email, work communication (Slack, Teams, Zoom, Discord), online learning, tutorials, documentation, courses, Stack Overflow, planning, notes, calendars, task management, project management, spreadsheets, Notion, Obsidian, design tools (Figma, Photoshop), creative work, video editing, music production"),
        CategoryDefinition(name: "Distraction", colorHex: "#EF4444", icon: "eye.slash.fill", isProductive: false, isSystem: false,
                           aiPrompt: "Social media (Reddit, Twitter/X, TikTok, Instagram, LinkedIn), news feeds, YouTube (non-tutorial), streaming video (Netflix, Hulu, Disney+), gaming, shopping, banking, personal finance, travel booking, music listening, podcasts, Finder, system preferences, any non-work activity"),
        CategoryDefinition(name: "Idle", colorHex: "#9CA3AF", icon: "moon.fill", isProductive: false, isSystem: true,
                           aiPrompt: "Computer is idle, screen locked, screensaver active, no user input detected"),
        CategoryDefinition(name: "Uncategorized", colorHex: "#6B7280", icon: "questionmark.circle", isProductive: false, isSystem: true,
                           aiPrompt: "Activity that hasn't been categorized yet — classify as Work or Distraction"),
    ]

    var allCategories: [CategoryDefinition] {
        lock.lock()
        defer { lock.unlock() }
        return definitions
    }

    var selectableCategories: [CategoryDefinition] {
        lock.lock()
        defer { lock.unlock() }
        return definitions.filter { !$0.isSystem }
    }

    func definition(for category: Category) -> CategoryDefinition? {
        lock.lock()
        defer { lock.unlock() }
        return definitions.first { $0.name == category.rawValue }
    }

    func color(for category: Category) -> Color {
        definition(for: category)?.color ?? .gray
    }

    func addCategory(_ def: CategoryDefinition) {
        lock.lock()
        definitions.append(def)
        let snapshot = definitions
        lock.unlock()
        saveSnapshot(snapshot)
    }

    func updateCategory(_ def: CategoryDefinition) {
        lock.lock()
        if let idx = definitions.firstIndex(where: { $0.name == def.name }) {
            definitions[idx] = def
        }
        let snapshot = definitions
        lock.unlock()
        saveSnapshot(snapshot)
    }

    func removeCategory(named name: String) {
        lock.lock()
        definitions.removeAll { $0.name == name && !$0.isSystem }
        let snapshot = definitions
        lock.unlock()
        saveSnapshot(snapshot)
    }

    /// Writes a snapshot of definitions to disk — called outside the lock.
    private func saveSnapshot(_ snapshot: [CategoryDefinition]) {
        if let data = try? JSONEncoder().encode(snapshot) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    /// Must be called while lock is held (only used during init where single-threaded)
    private func saveLocked() {
        if let data = try? JSONEncoder().encode(definitions) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}

// MARK: - Color hex extension
extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let r, g, b: Double
        switch hex.count {
        case 6:
            r = Double((int >> 16) & 0xFF) / 255
            g = Double((int >> 8) & 0xFF) / 255
            b = Double(int & 0xFF) / 255
        default:
            r = 0; g = 0; b = 0
        }
        self.init(red: r, green: g, blue: b)
    }

    var hexString: String {
        guard let c = NSColor(self).usingColorSpace(.sRGB) else { return "#000000" }
        let r = Int(c.redComponent * 255)
        let g = Int(c.greenComponent * 255)
        let b = Int(c.blueComponent * 255)
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}
