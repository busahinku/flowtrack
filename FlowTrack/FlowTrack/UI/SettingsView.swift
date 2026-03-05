import SwiftUI
import ServiceManagement

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
        }
        .frame(width: 600, height: 500)
        .preferredColorScheme(AppSettings.shared.appTheme.colorScheme)
    }
}

// MARK: - General Tab
struct GeneralTab: View {
    @Bindable var settings = AppSettings.shared
    @State private var hasAccessibility = PermissionChecker.hasAccessibility

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

            Section("AI Batch") {
                Picker("Auto-run interval", selection: $settings.aiBatchIntervalMinutes) {
                    Text("10 min").tag(10)
                    Text("20 min").tag(20)
                    Text("30 min").tag(30)
                    Text("60 min").tag(60)
                }
                Toggle("AI Summaries", isOn: $settings.aiSummariesEnabled)
            }

            Section("Data") {
                HStack {
                    Text("Storage Location")
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

    var body: some View {
        Form {
            Section("Primary Provider") {
                Picker("Provider", selection: $settings.aiProvider) {
                    ForEach(AIProviderType.allCases) { provider in
                        Text(provider.rawValue).tag(provider)
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

            Section("Fallback Providers") {
                fallbackPicker("Fallback 1", selection: Binding(
                    get: { settings.secondaryProvider?.rawValue ?? "__none__" },
                    set: { settings.secondaryProvider = $0 == "__none__" ? nil : AIProviderType(rawValue: $0) }
                ))
                fallbackPicker("Fallback 2", selection: Binding(
                    get: { settings.tertiaryProvider?.rawValue ?? "__none__" },
                    set: { settings.tertiaryProvider = $0 == "__none__" ? nil : AIProviderType(rawValue: $0) }
                ))
            }

            Section("Test Connection") {
                Button(action: testConnection) {
                    HStack {
                        if isTesting {
                            ProgressView().controlSize(.small)
                        }
                        Text(isTesting ? "Testing..." : "Send Test Request")
                    }
                }
                .disabled(isTesting)

                if let result = testResult {
                    Text(result)
                        .font(.caption)
                        .foregroundStyle(result.contains("✓") ? .green : .red)
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func cliSection(for provider: AIProviderType) -> some View {
        let path = CLIProvider.detectCLI(command: provider.cliCommand ?? "")
        HStack {
            if let path = path {
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
        if !SecureStore.shared.hasKey(for: provider.rawValue) {
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
                ForEach(provider.suggestedModels, id: \.self) { model in
                    Button(model) {
                        settings.setModelName(model, for: provider)
                        modelInput = ""
                    }
                    .font(.caption2)
                    .buttonStyle(.bordered)
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

    private func testConnection() {
        isTesting = true
        testResult = nil
        Task {
            let provider = AIProviderFactory.create(for: settings.aiProvider)
            let model = settings.modelName(for: settings.aiProvider)
            print("[TestAI] Testing \(settings.aiProvider.rawValue) with model \(model)...")
            do {
                let result = try await provider.categorize(
                    appName: "Safari",
                    bundleID: "com.apple.Safari",
                    windowTitle: "GitHub - Swift",
                    url: "https://github.com"
                )
                testResult = "✓ Success! Categorized as: \(result.rawValue)"
                print("[TestAI] Result: \(testResult!)")
            } catch {
                testResult = "✗ \(error.localizedDescription)"
                print("[TestAI] Result: \(testResult!)")
            }
            isTesting = false
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
            TextField("Name", text: $category.name)
                .textFieldStyle(.roundedBorder)
                .disabled(true)
            TextField("Icon (SF Symbol)", text: $category.icon)
                .textFieldStyle(.roundedBorder)
            TextField("Color Hex", text: $category.colorHex)
                .textFieldStyle(.roundedBorder)
            Toggle("Productive", isOn: $category.isProductive)

            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button("Save") {
                    CategoryManager.shared.updateCategory(category)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .frame(width: 350)
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
                Section("Custom Rules") {
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
                    RoundedRectangle(cornerRadius: 8)
                        .fill(settings.appTheme.cardBg)
                        .frame(width: 60, height: 40)
                        .overlay(Text("Card").font(.caption2))
                    RoundedRectangle(cornerRadius: 8)
                        .fill(settings.appTheme.timelineBg)
                        .frame(width: 60, height: 40)
                        .overlay(Text("BG").font(.caption2))
                    RoundedRectangle(cornerRadius: 8)
                        .fill(settings.appTheme.sidebarBg)
                        .frame(width: 60, height: 40)
                        .overlay(Text("Side").font(.caption2))
                    RoundedRectangle(cornerRadius: 8)
                        .fill(settings.appTheme.accentColor)
                        .frame(width: 60, height: 40)
                        .overlay(Text("Accent").font(.caption2).foregroundStyle(.white))
                }
            }
        }
        .formStyle(.grouped)
    }
}
