import SwiftUI
import ServiceManagement
import UniformTypeIdentifiers

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
        .frame(width: 650, height: 520)
        .preferredColorScheme(AppSettings.shared.appTheme.colorScheme)
    }
}

// MARK: - General Tab
struct GeneralTab: View {
    @Bindable var settings = AppSettings.shared
    @State private var hasAccessibility = PermissionChecker.hasAccessibility
    private var accessibilityTimer: Timer? = nil

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
            }
        }
        .formStyle(.grouped)
        .onAppear {
            Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
                Task { @MainActor in
                    hasAccessibility = PermissionChecker.hasAccessibility
                }
            }
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
                    apiKeySection(for: settings.aiProvider)
                }

                modelSection(for: settings.aiProvider)
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
                    HStack(spacing: 6) {
                        statusDot(for: sec)
                        Text(sec.rawValue)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if sec.needsAPIKey && !SecureStore.shared.hasKey(for: sec.rawValue) {
                            Text("⚠️ No API key")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        }
                    }
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
                    HStack(spacing: 6) {
                        statusDot(for: ter)
                        Text(ter.rawValue)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if ter.needsAPIKey && !SecureStore.shared.hasKey(for: ter.rawValue) {
                            Text("⚠️ No API key")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        }
                    }
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
    private func apiKeySection(for provider: AIProviderType) -> some View {
        HStack {
            TextField("API Key", text: $apiKeyInput)
                .textFieldStyle(.roundedBorder)
            Button("Save") {
                SecureStore.shared.save(key: apiKeyInput, for: provider.rawValue)
                apiKeyInput = ""
                savedIndicator = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { savedIndicator = false }
            }
            if savedIndicator {
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
                    SecureStore.shared.save(key: "", for: provider.rawValue)
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
    private func modelSection(for provider: AIProviderType) -> some View {
        let currentModel = settings.modelName(for: provider)
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Model:")
                    .font(.caption)
                TextField("Model", text: Binding(
                    get: { modelInput.isEmpty ? currentModel : modelInput },
                    set: { modelInput = $0 }
                ))
                .textFieldStyle(.roundedBorder)
                Button("Set") {
                    settings.setModelName(modelInput.isEmpty ? currentModel : modelInput, for: provider)
                    modelInput = ""
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
                        modelInput = ""
                    }
                    .font(.caption2)
                    .buttonStyle(.bordered)
                    .tint(currentModel == model ? .blue : nil)
                }
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
            // Pre-flight checks
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
                print("[TestAI] Result: \(testResult!)")
            } catch {
                testResult = "✗ \(error.localizedDescription)"
                providerHealth[providerType.rawValue] = .unhealthy(error.localizedDescription)
                print("[TestAI] Result: \(testResult!)")
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

    var body: some View {
        VStack {
            List {
                ForEach(CategoryManager.shared.allCategories, id: \.name) { cat in
                    HStack {
                        Circle()
                            .fill(cat.color)
                            .frame(width: 12, height: 12)
                        Image(systemName: cat.icon)
                            .frame(width: 20)
                        Text(cat.name)
                        Spacer()
                        if cat.isProductive {
                            Text("Productive")
                                .font(.caption2)
                                .foregroundStyle(.green)
                        }
                        if cat.isSystem {
                            Text("System")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if !cat.isSystem { editingCategory = cat }
                    }
                }
            }
            HStack {
                Text("\(CategoryManager.shared.allCategories.count) categories")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Add Category") { showAddSheet = true }
            }
            .padding()
        }
        .sheet(item: $editingCategory) { cat in
            EditCategorySheet(category: cat)
        }
        .sheet(isPresented: $showAddSheet) {
            AddCategorySheet()
        }
    }
}

struct EditCategorySheet: View {
    @State var category: CategoryDefinition
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 16) {
            Text("Edit Category")
                .font(.headline)

            HStack {
                Image(systemName: category.icon)
                    .font(.title2)
                    .foregroundStyle(Color(hex: category.colorHex))
                    .frame(width: 40)
                Text(category.name)
                    .font(.title3.bold())
            }

            TextField("Icon (SF Symbol)", text: $category.icon)
                .textFieldStyle(.roundedBorder)
            TextField("Color Hex", text: $category.colorHex)
                .textFieldStyle(.roundedBorder)
            Toggle("Productive", isOn: $category.isProductive)

            HStack {
                Button("Delete") {
                    CategoryManager.shared.removeCategory(named: category.name)
                    dismiss()
                }
                .foregroundStyle(.red)
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    CategoryManager.shared.updateCategory(category)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .frame(width: 380)
    }
}

struct AddCategorySheet: View {
    @State private var name = ""
    @State private var icon = "tag"
    @State private var colorHex = "#3B82F6"
    @State private var isProductive = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 16) {
            Text("Add Category")
                .font(.headline)
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
            TextField("Icon (SF Symbol)", text: $icon)
                .textFieldStyle(.roundedBorder)
            TextField("Color Hex", text: $colorHex)
                .textFieldStyle(.roundedBorder)
            Toggle("Productive", isOn: $isProductive)

            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button("Add") {
                    let def = CategoryDefinition(name: name, colorHex: colorHex, icon: icon, isProductive: isProductive, isSystem: false)
                    CategoryManager.shared.addCategory(def)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(name.isEmpty)
            }
        }
        .padding()
        .frame(width: 350)
    }
}

// MARK: - Rules Tab
struct RulesTab: View {
    @State private var showAddSheet = false

    var body: some View {
        VStack {
            List {
                Section("Custom Rules (\(RuleEngine.shared.allCustomRules.count))") {
                    if RuleEngine.shared.allCustomRules.isEmpty {
                        Text("No custom rules yet. Add rules to override default categorization.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(RuleEngine.shared.allCustomRules, id: \.id) { rule in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(rule.pattern)
                                    .font(.subheadline)
                                Text(rule.matchType.rawValue)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(rule.category)
                                .font(.caption)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2)
                                .background(Color.blue.opacity(0.1))
                                .cornerRadius(4)
                            Button(action: {
                                RuleEngine.shared.removeRule(withId: rule.id)
                            }) {
                                Image(systemName: "trash")
                                    .foregroundStyle(.red)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                Section("Default Rules") {
                    Text("Built-in rules are loaded from DefaultRules.json (\(RuleEngine.shared.defaultRuleCount) rules). Custom rules take priority.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            HStack {
                Spacer()
                Button("Add Rule") { showAddSheet = true }
            }
            .padding()
        }
        .sheet(isPresented: $showAddSheet) {
            AddRuleSheet()
        }
    }
}

struct AddRuleSheet: View {
    @State private var matchType: Rule.MatchType = .appName
    @State private var pattern = ""
    @State private var category = "Work"
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 16) {
            Text("Add Rule")
                .font(.headline)
            Picker("Match Type", selection: $matchType) {
                Text("App Name").tag(Rule.MatchType.appName)
                Text("Bundle ID").tag(Rule.MatchType.bundleID)
                Text("Domain").tag(Rule.MatchType.domain)
                Text("Title Contains").tag(Rule.MatchType.titleContains)
            }
            TextField("Pattern", text: $pattern)
                .textFieldStyle(.roundedBorder)
            Picker("Category", selection: $category) {
                ForEach(CategoryManager.shared.selectableCategories, id: \.name) { cat in
                    Text(cat.name).tag(cat.name)
                }
            }

            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button("Add") {
                    let rule = Rule(matchType: matchType, pattern: pattern, category: category)
                    RuleEngine.shared.addRule(rule)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(pattern.isEmpty)
            }
        }
        .padding()
        .frame(width: 400)
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
                        SecureStore.shared.save(key: "", for: provider.rawValue)
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
    @State private var isExporting = false

    var body: some View {
        Form {
            Section("Export Activities") {
                Text("Export your activity data as CSV or JSON for analysis in other tools.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack {
                    Button("Export Today as CSV") {
                        exportCSV(for: Date())
                    }

                    Button("Export Today as JSON") {
                        exportJSON(for: Date())
                    }
                }

                HStack {
                    Button("Export All Data as CSV") {
                        exportAllCSV()
                    }

                    Button("Export All Data as JSON") {
                        exportAllJSON()
                    }
                }
            }

            Section("Export AI Data") {
                Button("Export Session Titles & Summaries") {
                    exportSessionAI()
                }
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
