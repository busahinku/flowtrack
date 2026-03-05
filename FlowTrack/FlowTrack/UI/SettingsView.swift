import SwiftUI
import ServiceManagement
import UniformTypeIdentifiers
import Combine

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralTab()
                .tabItem { Label("General", systemImage: "gear") }
            AITab()
                .tabItem { Label("AI Provider", systemImage: "brain") }
            CategoriesTab()
                .tabItem { Label("Categories", systemImage: "tag") }
            RulesTab()
                .tabItem { Label("Rules", systemImage: "list.bullet") }
            AppearanceTab()
                .tabItem { Label("Appearance", systemImage: "paintbrush") }
            PrivacyTab()
                .tabItem { Label("Privacy", systemImage: "lock.shield") }
            ExportTab()
                .tabItem { Label("Export", systemImage: "square.and.arrow.up") }
        }
        .frame(width: 660, height: 540)
        .preferredColorScheme(AppSettings.shared.appTheme.colorScheme)
    }
}

// MARK: - General Tab
struct GeneralTab: View {
    @Bindable var settings = AppSettings.shared
    @State private var hasAccessibility = PermissionChecker.hasAccessibility
    @State private var dbSizeText = "Calculating..."

    var body: some View {
        Form {
            Section("Startup") {
                Toggle("Launch at Login", isOn: Binding(
                    get: { settings.launchAtLogin },
                    set: { newValue in
                        settings.launchAtLogin = newValue
                        if newValue {
                            try? SMAppService.mainApp.register()
                        } else {
                            try? SMAppService.mainApp.unregister()
                        }
                    }
                ))
                Toggle("Show Dock Icon", isOn: $settings.showDockIcon)
                Toggle("Show App Icons in Timeline", isOn: $settings.showAppIcons)
            }

            Section("Permissions") {
                HStack {
                    Text("Accessibility")
                    Spacer()
                    if hasAccessibility {
                        Label("Granted", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Button("Request Access") {
                            PermissionChecker.requestAccessibility()
                        }
                    }
                }
            }

            Section("AI Batch Processing") {
                Picker("Auto-run interval", selection: $settings.aiBatchIntervalMinutes) {
                    Text("10 min").tag(10)
                    Text("20 min").tag(20)
                    Text("30 min").tag(30)
                    Text("60 min").tag(60)
                }
                Stepper("Batch size: \(settings.aiBatchSize)", value: $settings.aiBatchSize, in: 5...100, step: 5)
                Toggle("AI Summaries", isOn: $settings.aiSummariesEnabled)
            }

            Section("Data Storage") {
                HStack {
                    Text("Location")
                    Spacer()
                    Text("~/Library/Application Support/FlowTrack/")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Reveal") {
                        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                            .appendingPathComponent("FlowTrack")
                        NSWorkspace.shared.open(folder)
                    }
                }
                HStack {
                    Text("Database size")
                    Spacer()
                    Text(dbSizeText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("Data older than 90 days is automatically cleaned when DB exceeds 3 GB.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
                Task { @MainActor in
                    hasAccessibility = PermissionChecker.hasAccessibility
                }
            }
            updateDBSize()
        }
        .onReceive(NotificationCenter.default.publisher(for: .init("FlowTrackDataCleared"))) { _ in
            updateDBSize()
        }
    }

    private func updateDBSize() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dbPath = appSupport.appendingPathComponent("FlowTrack/flowtrack.sqlite").path
        if let attrs = try? FileManager.default.attributesOfItem(atPath: dbPath),
           let size = attrs[.size] as? Int64 {
            let mb = Double(size) / (1024 * 1024)
            if mb >= 1024 {
                dbSizeText = String(format: "%.1f GB", mb / 1024)
            } else {
                dbSizeText = String(format: "%.1f MB", mb)
            }
        } else {
            dbSizeText = "Unknown"
        }
    }
}

// MARK: - AI Tab
struct AITab: View {
    @Bindable var settings = AppSettings.shared
    @State private var apiKeyInput = ""
    @State private var testResult: String?
    @State private var isTesting = false
    @State private var modelInput = ""
    @State private var savedIndicator = false
    @State private var cliDetected: [String: String?] = [:]
    @State private var providerHealth: [String: ProviderHealthStatus] = [:]
    // Fallback inline config
    @State private var fb1KeyInput = ""
    @State private var fb2KeyInput = ""
    @State private var fb1ModelInput = ""
    @State private var fb2ModelInput = ""

    enum ProviderHealthStatus {
        case unknown, checking, healthy, unhealthy(String)
    }

    var body: some View {
        Form {
            Section("Primary Provider") {
                Picker("Provider", selection: $settings.aiProvider) {
                    ForEach(AIProviderType.allCases) { provider in
                        HStack {
                            statusDot(for: provider)
                            Text(provider.rawValue)
                        }
                        .tag(provider)
                    }
                }

                if settings.aiProvider.isCLI {
                    cliSection(for: settings.aiProvider)
                }

                if settings.aiProvider.needsAPIKey {
                    apiKeySection(for: settings.aiProvider, keyBinding: $apiKeyInput, savedBinding: $savedIndicator)
                }

                modelSection(for: settings.aiProvider, modelBinding: $modelInput)
            }

            Section("Fallback Chain") {
                Text("If the primary fails, it tries fallback providers in order.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                fallbackPicker("Fallback 1", selection: Binding(
                    get: {
                        guard let sec = settings.secondaryProvider, sec != settings.aiProvider else { return "__none__" }
                        return sec.rawValue
                    },
                    set: { settings.secondaryProvider = $0 == "__none__" ? nil : AIProviderType(rawValue: $0) }
                ))

                if let sec = settings.secondaryProvider, sec != settings.aiProvider {
                    fallbackProviderConfig(sec, keyBinding: $fb1KeyInput, modelBinding: $fb1ModelInput)
                }

                fallbackPicker("Fallback 2", selection: Binding(
                    get: {
                        guard let ter = settings.tertiaryProvider,
                              ter != settings.aiProvider,
                              ter != settings.secondaryProvider else { return "__none__" }
                        return ter.rawValue
                    },
                    set: { settings.tertiaryProvider = $0 == "__none__" ? nil : AIProviderType(rawValue: $0) }
                ))

                if let ter = settings.tertiaryProvider, ter != settings.aiProvider, ter != settings.secondaryProvider {
                    fallbackProviderConfig(ter, keyBinding: $fb2KeyInput, modelBinding: $fb2ModelInput)
                }
            }

            Section("Test Connection") {
                HStack {
                    Button(action: testConnection) {
                        HStack {
                            if isTesting {
                                ProgressView().controlSize(.small)
                            }
                            Text(isTesting ? "Testing..." : "Send Test Request")
                        }
                    }
                    .disabled(isTesting)

                    Spacer()

                    Button("Check All Providers") {
                        Task { await checkAllProviders() }
                    }
                    .font(.caption)
                    .disabled(isTesting)
                }

                if let result = testResult {
                    Text(result)
                        .font(.caption)
                        .foregroundStyle(result.contains("✓") ? .green : .red)
                        .textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { refreshCLIDetection() }
    }

    @ViewBuilder
    private func statusDot(for provider: AIProviderType) -> some View {
        let key = provider.rawValue
        switch providerHealth[key] {
        case .healthy:
            Circle().fill(.green).frame(width: 8, height: 8)
        case .unhealthy:
            Circle().fill(.red).frame(width: 8, height: 8)
        case .checking:
            Circle().fill(.orange).frame(width: 8, height: 8)
        default:
            Circle().fill(.gray.opacity(0.3)).frame(width: 8, height: 8)
        }
    }

    @ViewBuilder
    private func cliSection(for provider: AIProviderType) -> some View {
        let cmd = provider.cliCommand ?? ""
        let cached = cliDetected[cmd]
        HStack {
            if let path = cached as? String {
                Label("Found: \(path)", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Not found", systemImage: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                    if let instructions = provider.setupInstructions {
                        Text(instructions)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Spacer()
            Button("Refresh") {
                refreshCLIDetection()
            }
            .font(.caption)
        }
    }

    @ViewBuilder
    private func apiKeySection(for provider: AIProviderType, keyBinding: Binding<String>, savedBinding: Binding<Bool>) -> some View {
        HStack {
            SecureField("API Key", text: keyBinding)
                .textFieldStyle(.roundedBorder)
            Button("Save") {
                SecureStore.shared.save(key: keyBinding.wrappedValue, for: provider.rawValue)
                keyBinding.wrappedValue = ""
                savedBinding.wrappedValue = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { savedBinding.wrappedValue = false }
            }
            if savedBinding.wrappedValue {
                Text("Saved ✓")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
        }
        if SecureStore.shared.hasKey(for: provider.rawValue) {
            HStack {
                Label("Key saved", systemImage: "key.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
                Spacer()
                Button("Remove Key") {
                    SecureStore.shared.deleteKey(for: provider.rawValue)
                }
                .font(.caption)
                .foregroundStyle(.red)
            }
        } else {
            Text("⚠️ No API key saved for \(provider.rawValue)")
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }

    @ViewBuilder
    private func modelSection(for provider: AIProviderType, modelBinding: Binding<String>) -> some View {
        let currentModel = settings.modelName(for: provider)
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Model:")
                    .font(.caption)
                TextField("Model", text: Binding(
                    get: { modelBinding.wrappedValue.isEmpty ? currentModel : modelBinding.wrappedValue },
                    set: { modelBinding.wrappedValue = $0 }
                ))
                .textFieldStyle(.roundedBorder)
                Button("Set") {
                    settings.setModelName(modelBinding.wrappedValue.isEmpty ? currentModel : modelBinding.wrappedValue, for: provider)
                    modelBinding.wrappedValue = ""
                }
            }
            Text(provider.modelHint)
                .font(.caption2)
                .foregroundStyle(.secondary)

            HStack(spacing: 4) {
                Text("Quick:")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                ForEach(provider.suggestedModels, id: \.self) { model in
                    Button(model) {
                        settings.setModelName(model, for: provider)
                        modelBinding.wrappedValue = ""
                    }
                    .font(.caption2)
                    .buttonStyle(.bordered)
                    .tint(currentModel == model ? .blue : nil)
                }
            }
        }
    }

    @ViewBuilder
    private func fallbackProviderConfig(_ provider: AIProviderType, keyBinding: Binding<String>, modelBinding: Binding<String>) -> some View {
        HStack(spacing: 6) {
            statusDot(for: provider)
            Text(provider.rawValue)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            if provider.needsAPIKey {
                if SecureStore.shared.hasKey(for: provider.rawValue) {
                    Label("Key saved", systemImage: "key.fill")
                        .font(.caption2)
                        .foregroundStyle(.green)
                } else {
                    Text("⚠️ No key")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
            if provider.isCLI {
                if cliDetected[provider.cliCommand ?? ""] != nil {
                    Label("Found", systemImage: "checkmark.circle.fill")
                        .font(.caption2)
                        .foregroundStyle(.green)
                } else {
                    Text("Not installed")
                        .font(.caption2)
                        .foregroundStyle(.red)
                }
            }
        }

        if provider.needsAPIKey && !SecureStore.shared.hasKey(for: provider.rawValue) {
            HStack {
                SecureField("API Key for \(provider.rawValue)", text: keyBinding)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
                Button("Save") {
                    SecureStore.shared.save(key: keyBinding.wrappedValue, for: provider.rawValue)
                    keyBinding.wrappedValue = ""
                }
                .font(.caption)
            }
        }

        HStack {
            Text("Model:")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(settings.modelName(for: provider))
                .font(.caption2)
            Spacer()
            ForEach(provider.suggestedModels.prefix(3), id: \.self) { model in
                Button(model) {
                    settings.setModelName(model, for: provider)
                }
                .font(.caption2)
                .buttonStyle(.bordered)
                .controlSize(.mini)
            }
        }
    }

    private func fallbackPicker(_ label: String, selection: Binding<String>) -> some View {
        Picker(label, selection: selection) {
            Text("None").tag("__none__")
            ForEach(AIProviderType.allCases.filter { $0 != settings.aiProvider }) { p in
                Text(p.rawValue).tag(p.rawValue)
            }
        }
    }

    private func refreshCLIDetection() {
        for provider in AIProviderType.allCases where provider.isCLI {
            let cmd = provider.cliCommand ?? ""
            cliDetected[cmd] = CLIProvider.detectCLI(command: cmd)
        }
    }

    private func testConnection() {
        isTesting = true
        testResult = nil
        let providerType = settings.aiProvider
        Task {
            if providerType.needsAPIKey && !SecureStore.shared.hasKey(for: providerType.rawValue) {
                testResult = "✗ No API key saved for \(providerType.rawValue). Save a key first."
                isTesting = false
                return
            }
            if providerType.isCLI {
                let cmd = providerType.cliCommand ?? ""
                if CLIProvider.detectCLI(command: cmd) == nil {
                    testResult = "✗ CLI '\(cmd)' not found. Install it first."
                    isTesting = false
                    return
                }
            }

            let model = settings.modelName(for: providerType)
            let provider = AIProviderFactory.create(for: providerType)
            print("[TestAI] Testing \(providerType.rawValue) with model \(model)...")
            do {
                let result = try await provider.categorize(
                    appName: "Safari",
                    bundleID: "com.apple.Safari",
                    windowTitle: "GitHub - Swift",
                    url: "https://github.com"
                )
                testResult = "✓ Success! Categorized as: \(result.rawValue)"
                providerHealth[providerType.rawValue] = .healthy
            } catch {
                testResult = "✗ \(error.localizedDescription)"
                providerHealth[providerType.rawValue] = .unhealthy(error.localizedDescription)
            }
            isTesting = false
        }
    }

    private func checkAllProviders() async {
        let chain: [AIProviderType] = [settings.aiProvider] +
            [settings.secondaryProvider, settings.tertiaryProvider].compactMap { $0 }
        for pt in chain {
            providerHealth[pt.rawValue] = .checking
            let provider = AIProviderFactory.create(for: pt)
            do {
                _ = try await provider.checkHealth()
                providerHealth[pt.rawValue] = .healthy
            } catch {
                providerHealth[pt.rawValue] = .unhealthy(error.localizedDescription)
            }
        }
    }
}

// MARK: - Categories Tab
struct CategoriesTab: View {
    @State private var editingCategory: CategoryDefinition?
    @State private var showAddSheet = false
    @State private var categories: [CategoryDefinition] = CategoryManager.shared.allCategories

    // Protected categories that cannot be deleted
    private let protectedNames: Set<String> = ["Idle", "Uncategorized", "Work", "Distraction", "Productivity"]

    var body: some View {
        VStack(spacing: 0) {
            List {
                ForEach(categories, id: \.name) { cat in
                    HStack(spacing: 10) {
                        Circle()
                            .fill(cat.color)
                            .frame(width: 14, height: 14)
                        Image(systemName: cat.icon)
                            .foregroundStyle(cat.color)
                            .frame(width: 22)
                        Text(cat.name)
                            .font(.body)
                        Spacer()
                        if cat.isProductive {
                            Text("Productive")
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.green.opacity(0.15))
                                .foregroundStyle(.green)
                                .cornerRadius(4)
                        }
                        if protectedNames.contains(cat.name) {
                            Image(systemName: "lock.fill")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        editingCategory = cat
                    }
                }
            }
            HStack {
                Text("\(categories.count) categories • AI uses these to classify your activity")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(action: { showAddSheet = true }) {
                    Label("Add Category", systemImage: "plus")
                }
            }
            .padding()
        }
        .sheet(item: $editingCategory) { cat in
            EditCategorySheet(category: cat, isProtected: protectedNames.contains(cat.name)) {
                categories = CategoryManager.shared.allCategories
            }
        }
        .sheet(isPresented: $showAddSheet) {
            AddCategorySheet {
                categories = CategoryManager.shared.allCategories
            }
        }
    }
}

struct EditCategorySheet: View {
    @State var category: CategoryDefinition
    let isProtected: Bool
    let onDismiss: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var pickedColor: Color
    @State private var showIconPicker = false

    init(category: CategoryDefinition, isProtected: Bool, onDismiss: @escaping () -> Void) {
        self._category = State(initialValue: category)
        self.isProtected = isProtected
        self.onDismiss = onDismiss
        self._pickedColor = State(initialValue: Color(hex: category.colorHex))
    }

    static let popularIcons = [
        "briefcase.fill", "chart.bar.fill", "person.fill", "eye.slash.fill",
        "bubble.left.and.bubble.right.fill", "book.fill", "paintbrush.fill",
        "heart.fill", "play.circle.fill", "moon.fill", "questionmark.circle",
        "star.fill", "flag.fill", "bolt.fill", "globe", "doc.fill",
        "folder.fill", "envelope.fill", "phone.fill", "camera.fill",
        "music.note", "gamecontroller.fill", "cart.fill", "house.fill",
        "wrench.fill", "lock.fill", "shield.fill", "leaf.fill",
        "lightbulb.fill", "graduationcap.fill", "desktopcomputer", "terminal.fill",
        "tag.fill", "bookmark.fill", "clock.fill", "calendar",
        "map.fill", "airplane", "gift.fill", "bell.fill"
    ]

    var body: some View {
        VStack(spacing: 16) {
            Text("Edit Category")
                .font(.headline)

            // Preview
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(pickedColor)
                        .frame(width: 44, height: 44)
                    Image(systemName: category.icon)
                        .font(.title3)
                        .foregroundStyle(.white)
                }
                Text(category.name)
                    .font(.title3.bold())
            }

            Form {
                // AI Prompt
                Section("AI Description") {
                    TextField("Describe what this category includes for AI", text: $category.aiPrompt, axis: .vertical)
                        .lineLimit(2...4)
                }

                // Color picker
                Section("Color") {
                    ColorPicker("Pick a color", selection: $pickedColor, supportsOpacity: false)
                        .onChange(of: pickedColor) {
                            category.colorHex = pickedColor.hexString
                        }
                }

                // Icon picker
                Section("Icon") {
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(36), spacing: 8), count: 8), spacing: 8) {
                        ForEach(Self.popularIcons, id: \.self) { icon in
                            Button(action: { category.icon = icon }) {
                                Image(systemName: icon)
                                    .font(.body)
                                    .frame(width: 32, height: 32)
                                    .foregroundStyle(category.icon == icon ? .white : .primary)
                                    .background(
                                        RoundedRectangle(cornerRadius: 6)
                                            .fill(category.icon == icon ? pickedColor : Color.gray.opacity(0.1))
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                Toggle("Productive", isOn: $category.isProductive)
            }
            .formStyle(.grouped)
            .frame(height: 380)

            HStack {
                if !isProtected {
                    Button("Delete", role: .destructive) {
                        CategoryManager.shared.removeCategory(named: category.name)
                        onDismiss()
                        dismiss()
                    }
                    .foregroundStyle(.red)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    CategoryManager.shared.updateCategory(category)
                    onDismiss()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .frame(width: 440)
    }
}

struct AddCategorySheet: View {
    @State private var name = ""
    @State private var icon = "tag.fill"
    @State private var pickedColor = Color.blue
    @State private var isProductive = false
    @State private var aiPrompt = ""
    let onDismiss: () -> Void
    @Environment(\.dismiss) private var dismiss

    private static let popularIcons = EditCategorySheet.popularIcons

    var body: some View {
        VStack(spacing: 16) {
            Text("Add Category")
                .font(.headline)

            // Preview
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(pickedColor)
                        .frame(width: 40, height: 40)
                    Image(systemName: icon)
                        .foregroundStyle(.white)
                }
                Text(name.isEmpty ? "New Category" : name)
                    .font(.title3)
            }

            Form {
                TextField("Name", text: $name)

                Section("AI Description") {
                    TextField("Describe what this category includes for AI", text: $aiPrompt, axis: .vertical)
                        .lineLimit(2...4)
                }

                Section("Color") {
                    ColorPicker("Pick a color", selection: $pickedColor, supportsOpacity: false)
                }

                Section("Icon") {
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(36), spacing: 8), count: 8), spacing: 8) {
                        ForEach(Self.popularIcons, id: \.self) { ic in
                            Button(action: { icon = ic }) {
                                Image(systemName: ic)
                                    .font(.body)
                                    .frame(width: 32, height: 32)
                                    .foregroundStyle(icon == ic ? .white : .primary)
                                    .background(
                                        RoundedRectangle(cornerRadius: 6)
                                            .fill(icon == ic ? pickedColor : Color.gray.opacity(0.1))
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                Toggle("Productive", isOn: $isProductive)
            }
            .formStyle(.grouped)
            .frame(height: 400)

            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button("Add") {
                    let def = CategoryDefinition(name: name, colorHex: pickedColor.hexString, icon: icon, isProductive: isProductive, isSystem: false, aiPrompt: aiPrompt)
                    CategoryManager.shared.addCategory(def)
                    onDismiss()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(name.isEmpty)
            }
        }
        .padding()
        .frame(width: 440)
    }
}

// MARK: - Rules Tab
struct RulesTab: View {
    @State private var showAddSheet = false
    @State private var customRules: [Rule] = RuleEngine.shared.allCustomRules

    var body: some View {
        VStack(spacing: 0) {
            List {
                Section {
                    if customRules.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "text.badge.plus")
                                .font(.title2)
                                .foregroundStyle(.secondary)
                            Text("No custom rules yet")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Text("Rules let you override the default categorization for specific apps, websites, or window titles.")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 20)
                    }
                    ForEach(customRules, id: \.id) { rule in
                        HStack(spacing: 10) {
                            Image(systemName: ruleIcon(for: rule.matchType))
                                .foregroundStyle(.blue)
                                .frame(width: 20)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(rule.pattern)
                                    .font(.subheadline.bold())
                                Text(rule.matchType.rawValue.replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression).capitalized)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            HStack(spacing: 4) {
                                if let def = CategoryManager.shared.definition(for: Category(rawValue: rule.category)) {
                                    Image(systemName: def.icon)
                                        .font(.caption)
                                        .foregroundStyle(def.color)
                                }
                                Text(rule.category)
                                    .font(.caption)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.blue.opacity(0.08))
                            .cornerRadius(6)

                            Button(action: {
                                RuleEngine.shared.removeRule(withId: rule.id)
                                customRules = RuleEngine.shared.allCustomRules
                            }) {
                                Image(systemName: "trash")
                                    .font(.caption)
                                    .foregroundStyle(.red)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                } header: {
                    Text("Custom Rules (\(customRules.count))")
                }

                Section {
                    HStack {
                        Image(systemName: "info.circle")
                            .foregroundStyle(.blue)
                        Text("Built-in rules: \(RuleEngine.shared.defaultRuleCount). Custom rules take priority over defaults.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Default Rules")
                }
            }

            HStack {
                Text("Rules are matched in order: custom first, then defaults")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button(action: { showAddSheet = true }) {
                    Label("Add Rule", systemImage: "plus")
                }
            }
            .padding()
        }
        .sheet(isPresented: $showAddSheet) {
            AddRuleSheet {
                customRules = RuleEngine.shared.allCustomRules
            }
        }
    }

    private func ruleIcon(for type: Rule.MatchType) -> String {
        switch type {
        case .appName: return "app.badge"
        case .bundleID: return "shippingbox"
        case .domain: return "globe"
        case .titleContains: return "textformat"
        }
    }
}

struct AddRuleSheet: View {
    @State private var matchType: Rule.MatchType = .appName
    @State private var pattern = ""
    @State private var category = "Work"
    let onDismiss: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 16) {
            Text("Add Rule")
                .font(.headline)

            Form {
                Picker("Match Type", selection: $matchType) {
                    Label("App Name", systemImage: "app.badge").tag(Rule.MatchType.appName)
                    Label("Bundle ID", systemImage: "shippingbox").tag(Rule.MatchType.bundleID)
                    Label("Domain", systemImage: "globe").tag(Rule.MatchType.domain)
                    Label("Title Contains", systemImage: "textformat").tag(Rule.MatchType.titleContains)
                }
                TextField("Pattern (e.g., Safari, com.apple.*, reddit.com)", text: $pattern)
                Picker("Category", selection: $category) {
                    ForEach(CategoryManager.shared.selectableCategories, id: \.name) { cat in
                        Label {
                            Text(cat.name)
                        } icon: {
                            Image(systemName: cat.icon)
                                .foregroundStyle(cat.color)
                        }
                        .tag(cat.name)
                    }
                }
            }
            .formStyle(.grouped)
            .frame(height: 200)

            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button("Add") {
                    let rule = Rule(matchType: matchType, pattern: pattern, category: category)
                    RuleEngine.shared.addRule(rule)
                    onDismiss()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(pattern.isEmpty)
            }
        }
        .padding()
        .frame(width: 420)
    }
}

// MARK: - Appearance Tab
struct AppearanceTab: View {
    @Bindable var settings = AppSettings.shared

    var body: some View {
        Form {
            Section("Theme") {
                Picker("App Theme", selection: $settings.appTheme) {
                    ForEach(AppTheme.allCases) { theme in
                        HStack {
                            Circle()
                                .fill(theme.accentColor)
                                .frame(width: 12, height: 12)
                            Text(theme.rawValue)
                        }
                        .tag(theme)
                    }
                }
                .pickerStyle(.radioGroup)

                Text(themeDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Preview") {
                HStack(spacing: 12) {
                    themePreviewBox("Card", color: settings.appTheme.cardBg)
                    themePreviewBox("BG", color: settings.appTheme.timelineBg)
                    themePreviewBox("Sidebar", color: settings.appTheme.sidebarBg)
                    themePreviewBox("Accent", color: settings.appTheme.accentColor, textColor: .white)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var themeDescription: String {
        switch settings.appTheme {
        case .system: return "Follows your macOS appearance (light or dark)"
        case .light: return "Clean light interface"
        case .dark: return "Standard dark interface"
        case .pastel: return "Soft pastel colors with light background"
        case .midnight: return "Deep dark theme with blue accent"
        }
    }

    private func themePreviewBox(_ label: String, color: Color, textColor: Color = .primary) -> some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(color)
            .frame(width: 60, height: 40)
            .overlay(
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(textColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.gray.opacity(0.2), lineWidth: 0.5)
            )
    }
}

// MARK: - Privacy Tab
struct PrivacyTab: View {
    @State private var showClearConfirm = false
    @State private var showClearAIConfirm = false
    @State private var clearResult: String?

    var body: some View {
        Form {
            Section("Data Collection") {
                VStack(alignment: .leading, spacing: 8) {
                    Label("FlowTrack tracks which apps you use and their window titles.", systemImage: "info.circle")
                        .font(.callout)
                    Text("All data is stored locally on your Mac. Nothing is sent to any server unless you configure an API-based AI provider.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("AI Provider Privacy") {
                VStack(alignment: .leading, spacing: 8) {
                    Label("When using AI providers, app names and window titles are sent for categorization.", systemImage: "brain")
                        .font(.callout)
                    Text("CLI providers (Claude Code, ChatGPT Codex) process data through your local installation. API providers send data to their respective cloud services.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Manage Data") {
                Button("Clear AI-Generated Data") {
                    showClearAIConfirm = true
                }
                .foregroundStyle(.orange)

                Button("Clear ALL Activity Data") {
                    showClearConfirm = true
                }
                .foregroundStyle(.red)

                if let result = clearResult {
                    Text(result)
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            }

            Section("API Keys") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("API keys are stored in a local file with restricted permissions (0600).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Location: ~/Library/Application Support/FlowTrack/.apikeys")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                Button("Remove All API Keys") {
                    for provider in AIProviderType.allCases where provider.needsAPIKey {
                        SecureStore.shared.deleteKey(for: provider.rawValue)
                    }
                    clearResult = "All API keys removed"
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { clearResult = nil }
                }
                .foregroundStyle(.red)
            }
        }
        .formStyle(.grouped)
        .alert("Clear AI Data?", isPresented: $showClearAIConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Clear", role: .destructive) {
                try? Database.shared.clearSessionAI()
                AppState.shared.sessionTitles.removeAll()
                AppState.shared.sessionSummaries.removeAll()
                clearResult = "AI data cleared"
                NotificationCenter.default.post(name: .init("FlowTrackDataCleared"), object: nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { clearResult = nil }
            }
        } message: {
            Text("This will remove all AI-generated titles and summaries. Activity data will be kept.")
        }
        .alert("Clear ALL Data?", isPresented: $showClearConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Clear Everything", role: .destructive) {
                try? Database.shared.clearAllData()
                AppState.shared.sessionTitles.removeAll()
                AppState.shared.sessionSummaries.removeAll()
                Task { await AppState.shared.refreshData() }
                clearResult = "All data cleared"
                NotificationCenter.default.post(name: .init("FlowTrackDataCleared"), object: nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { clearResult = nil }
            }
        } message: {
            Text("This will permanently delete all activity records and AI data. This cannot be undone.")
        }
    }
}

// MARK: - Export Tab
struct ExportTab: View {
    @State private var exportResult: String?

    var body: some View {
        Form {
            Section("Export Activities") {
                Text("Export your activity data as CSV or JSON for analysis in other tools.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack {
                    Button("Export Today as CSV") { exportCSV(for: Date()) }
                    Button("Export Today as JSON") { exportJSON(for: Date()) }
                }

                HStack {
                    Button("Export All Data as CSV") { exportAllCSV() }
                    Button("Export All Data as JSON") { exportAllJSON() }
                }
            }

            Section("Export AI Data") {
                Button("Export Session Titles & Summaries") { exportSessionAI() }
            }

            if let result = exportResult {
                Section {
                    Text(result)
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func exportCSV(for date: Date) {
        guard let activities = try? Database.shared.activitiesForDate(date) else { return }
        let csv = buildCSV(from: activities)
        saveToFile(content: csv, defaultName: "flowtrack_\(dateString(date)).csv")
    }

    private func exportJSON(for date: Date) {
        guard let activities = try? Database.shared.activitiesForDate(date) else { return }
        let json = buildJSON(from: activities)
        saveToFile(content: json, defaultName: "flowtrack_\(dateString(date)).json")
    }

    private func exportAllCSV() {
        let thirtyDaysAgo = Calendar.current.date(byAdding: .day, value: -30, to: Date())!
        guard let activities = try? Database.shared.activitiesForRange(from: thirtyDaysAgo, to: Date()) else { return }
        let csv = buildCSV(from: activities)
        saveToFile(content: csv, defaultName: "flowtrack_all.csv")
    }

    private func exportAllJSON() {
        let thirtyDaysAgo = Calendar.current.date(byAdding: .day, value: -30, to: Date())!
        guard let activities = try? Database.shared.activitiesForRange(from: thirtyDaysAgo, to: Date()) else { return }
        let json = buildJSON(from: activities)
        saveToFile(content: json, defaultName: "flowtrack_all.json")
    }

    private func exportSessionAI() {
        guard let data = try? Database.shared.loadAllSessionAI() else { return }
        var lines = "sessionId,title,summary\n"
        for item in data {
            let title = (item.title ?? "").replacingOccurrences(of: "\"", with: "\"\"")
            let summary = (item.summary ?? "").replacingOccurrences(of: "\"", with: "\"\"")
            lines += "\"\(item.sessionId)\",\"\(title)\",\"\(summary)\"\n"
        }
        saveToFile(content: lines, defaultName: "flowtrack_ai_data.csv")
    }

    private func buildCSV(from activities: [ActivityRecord]) -> String {
        var csv = "timestamp,appName,bundleID,windowTitle,url,category,duration\n"
        let f = ISO8601DateFormatter()
        for a in activities {
            let ts = f.string(from: a.timestamp)
            let title = a.windowTitle.replacingOccurrences(of: "\"", with: "\"\"")
            csv += "\"\(ts)\",\"\(a.appName)\",\"\(a.bundleID)\",\"\(title)\",\"\(a.url ?? "")\",\"\(a.category.rawValue)\",\(a.duration)\n"
        }
        return csv
    }

    private func buildJSON(from activities: [ActivityRecord]) -> String {
        let f = ISO8601DateFormatter()
        let items = activities.map { a -> [String: Any] in
            var dict: [String: Any] = [
                "timestamp": f.string(from: a.timestamp),
                "appName": a.appName,
                "bundleID": a.bundleID,
                "windowTitle": a.windowTitle,
                "category": a.category.rawValue,
                "duration": a.duration,
                "isIdle": a.isIdle
            ]
            if let url = a.url { dict["url"] = url }
            return dict
        }
        guard let data = try? JSONSerialization.data(withJSONObject: items, options: .prettyPrinted),
              let str = String(data: data, encoding: .utf8) else { return "[]" }
        return str
    }

    private func saveToFile(content: String, defaultName: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = defaultName
        panel.allowedContentTypes = defaultName.hasSuffix(".json") ? [.json] : [.commaSeparatedText]
        panel.begin { response in
            if response == .OK, let url = panel.url {
                try? content.write(to: url, atomically: true, encoding: .utf8)
                exportResult = "Exported to \(url.lastPathComponent)"
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) { exportResult = nil }
            }
        }
    }

    private func dateString(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }
}
