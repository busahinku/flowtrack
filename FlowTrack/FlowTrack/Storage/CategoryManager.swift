import Foundation
import SwiftUI

// MARK: - CategoryDefinition
struct CategoryDefinition: Codable, Hashable, Identifiable, Sendable {
    var name: String
    var colorHex: String
    var icon: String
    var isProductive: Bool
    var isSystem: Bool

    var id: String { name }

    var color: Color { Color(hex: colorHex) }
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
        } else {
            self.definitions = Self.defaultDefinitions
            save()
        }
    }

    static let defaultDefinitions: [CategoryDefinition] = [
        CategoryDefinition(name: "Work", colorHex: "#3B82F6", icon: "briefcase.fill", isProductive: true, isSystem: false),
        CategoryDefinition(name: "Personal", colorHex: "#22C55E", icon: "person.fill", isProductive: false, isSystem: false),
        CategoryDefinition(name: "Distraction", colorHex: "#EF4444", icon: "eye.slash.fill", isProductive: false, isSystem: false),
        CategoryDefinition(name: "Communication", colorHex: "#06B6D4", icon: "bubble.left.and.bubble.right.fill", isProductive: true, isSystem: false),
        CategoryDefinition(name: "Learning", colorHex: "#8B5CF6", icon: "book.fill", isProductive: true, isSystem: false),
        CategoryDefinition(name: "Creative", colorHex: "#EC4899", icon: "paintbrush.fill", isProductive: true, isSystem: false),
        CategoryDefinition(name: "Health", colorHex: "#14B8A6", icon: "heart.fill", isProductive: false, isSystem: false),
        CategoryDefinition(name: "Entertainment", colorHex: "#F97316", icon: "play.circle.fill", isProductive: false, isSystem: false),
        CategoryDefinition(name: "Idle", colorHex: "#9CA3AF", icon: "moon.fill", isProductive: false, isSystem: true),
        CategoryDefinition(name: "Uncategorized", colorHex: "#6B7280", icon: "questionmark.circle", isProductive: false, isSystem: true),
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
}
