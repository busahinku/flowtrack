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

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let folder = appSupport.appendingPathComponent("FlowTrack")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        self.fileURL = folder.appendingPathComponent("categories.json")

        if let data = try? Data(contentsOf: fileURL),
           let loaded = try? JSONDecoder().decode([CategoryDefinition].self, from: data) {
            self.definitions = loaded
            // Migrate: add missing categories (e.g. Productivity) and aiPrompts
            migrateDefaults()
        } else {
            self.definitions = Self.defaultDefinitions
            save()
        }
    }

    private func migrateDefaults() {
        var changed = false
        let defaults = Dictionary(uniqueKeysWithValues: Self.defaultDefinitions.map { ($0.name, $0) })
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
        if changed { save() }
    }

    static let defaultDefinitions: [CategoryDefinition] = [
        CategoryDefinition(name: "Work", colorHex: "#3B82F6", icon: "briefcase.fill", isProductive: true, isSystem: false,
                           aiPrompt: "Coding, software development, IDEs, terminals, Git, code editors, programming tools, DevOps, databases, API testing"),
        CategoryDefinition(name: "Productivity", colorHex: "#10B981", icon: "chart.bar.fill", isProductive: true, isSystem: false,
                           aiPrompt: "Planning, notes, calendars, task management, project management, documentation, spreadsheets, time tracking, Notion, Obsidian"),
        CategoryDefinition(name: "Personal", colorHex: "#22C55E", icon: "person.fill", isProductive: false, isSystem: false,
                           aiPrompt: "Personal activities, banking, shopping, food delivery, personal email, personal finance, travel booking"),
        CategoryDefinition(name: "Distraction", colorHex: "#EF4444", icon: "eye.slash.fill", isProductive: false, isSystem: false,
                           aiPrompt: "Social media scrolling, news feeds, Reddit, Twitter/X, TikTok, Instagram, YouTube shorts, memes, clickbait, non-work browsing"),
        CategoryDefinition(name: "Communication", colorHex: "#06B6D4", icon: "bubble.left.and.bubble.right.fill", isProductive: true, isSystem: false,
                           aiPrompt: "Email, Slack, Discord, Teams, Zoom, video calls, messaging, chat apps, work communication"),
        CategoryDefinition(name: "Learning", colorHex: "#8B5CF6", icon: "book.fill", isProductive: true, isSystem: false,
                           aiPrompt: "Online courses, tutorials, documentation reading, Stack Overflow research, educational content, tech articles, learning platforms"),
        CategoryDefinition(name: "Creative", colorHex: "#EC4899", icon: "paintbrush.fill", isProductive: true, isSystem: false,
                           aiPrompt: "Design tools, Figma, Photoshop, illustration, video editing, music production, creative writing, 3D modeling"),
        CategoryDefinition(name: "Health", colorHex: "#14B8A6", icon: "heart.fill", isProductive: false, isSystem: false,
                           aiPrompt: "Fitness apps, health tracking, meditation, workout timers, nutrition tracking, mental health apps"),
        CategoryDefinition(name: "Entertainment", colorHex: "#F97316", icon: "play.circle.fill", isProductive: false, isSystem: false,
                           aiPrompt: "Streaming video, Netflix, movies, TV shows, gaming, music listening, Spotify, podcasts, leisure content"),
        CategoryDefinition(name: "Idle", colorHex: "#9CA3AF", icon: "moon.fill", isProductive: false, isSystem: true,
                           aiPrompt: "Computer is idle, screen locked, screensaver active, no user input detected"),
        CategoryDefinition(name: "Uncategorized", colorHex: "#6B7280", icon: "questionmark.circle", isProductive: false, isSystem: true,
                           aiPrompt: "Activity that hasn't been categorized yet — AI should attempt to classify into one of the other categories"),
    ]

    var allCategories: [CategoryDefinition] { definitions }

    var selectableCategories: [CategoryDefinition] {
        definitions.filter { !$0.isSystem }
    }

    func definition(for category: Category) -> CategoryDefinition? {
        definitions.first { $0.name == category.rawValue }
    }

    func color(for category: Category) -> Color {
        definition(for: category)?.color ?? .gray
    }

    func addCategory(_ def: CategoryDefinition) {
        definitions.append(def)
        save()
    }

    func updateCategory(_ def: CategoryDefinition) {
        if let idx = definitions.firstIndex(where: { $0.name == def.name }) {
            definitions[idx] = def
            save()
        }
    }

    func removeCategory(named name: String) {
        definitions.removeAll { $0.name == name && !$0.isSystem }
        save()
    }

    private func save() {
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
