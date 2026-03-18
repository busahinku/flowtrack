import SwiftUI
import ServiceManagement
import UniformTypeIdentifiers
import Combine
import OSLog
import Sparkle

private let settingsLog = Logger(subsystem: "com.flowtrack", category: "Settings")

struct SettingsView: View {
    @Environment(Theme.self) private var theme

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
            SyncSettingsView()
                .tabItem { Label("Sync", systemImage: "arrow.triangle.2.circlepath") }
        }
        .frame(width: 660, height: 540)
        .preferredColorScheme(theme.colorScheme)
    }
}

// MARK: - General Tab
struct GeneralTab: View {
    @Environment(SettingsStorage.self) private var settings
    @State private var hasAccessibility = PermissionChecker.hasAccessibility
    @State private var dbSizeText = "Calculating..."
    @ObservedObject private var updater = AppUpdater.shared
    @Environment(Theme.self) private var theme

    var body: some View {
        @Bindable var settings = settings
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
                Toggle("24-Hour Clock in Timeline", isOn: $settings.use24HourClock)
            }

            Section("Updates") {
                Toggle("Automatically check for updates", isOn: Binding(
                    get: { updater.updater.automaticallyChecksForUpdates },
                    set: { updater.updater.automaticallyChecksForUpdates = $0 }
                ))
                Button("Check for Updates…") {
                    updater.checkForUpdates()
                }
                .disabled(!updater.canCheckForUpdates)
            }

            Section("Permissions") {
                HStack {
                    Text("Accessibility")
                    Spacer()
                    if hasAccessibility {
                        Label("Granted", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(theme.successColor)
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

            Section("Tracking") {
                Picker("Idle after", selection: $settings.idleThresholdSeconds) {
                    Text("30 sec").tag(30)
                    Text("1 min").tag(60)
                    Text("2 min").tag(120)
                    Text("5 min").tag(300)
                    Text("10 min").tag(600)
                }
                Picker("Distraction alert after", selection: $settings.distractionAlertMinutes) {
                    Text("Off").tag(0)
                    Text("15 min").tag(15)
                    Text("30 min").tag(30)
                    Text("45 min").tag(45)
                    Text("60 min").tag(60)
                }
                Text("Alert fires when you've spent this long in a distraction category continuously.")
                    .font(.caption).foregroundStyle(theme.secondaryTextColor)
            }

            Section("Data Storage") {
                HStack {
                    Text("Location")
                    Spacer()
                    Text("~/Library/Application Support/FlowTrack/")
                        .font(.caption)
                        .foregroundStyle(theme.secondaryTextColor)
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
                        .foregroundStyle(theme.secondaryTextColor)
                }
                Text("Data older than 90 days is automatically cleaned when DB exceeds 3 GB.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)

                Picker("Keep data for", selection: $settings.retentionDays) {
                    Text("30 days").tag(30)
                    Text("60 days").tag(60)
                    Text("90 days").tag(90)
                    Text("180 days").tag(180)
                    Text("1 year").tag(365)
                    Text("Forever").tag(0)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            hasAccessibility = PermissionChecker.hasAccessibility
            updateDBSize()
        }
        .onDisappear {}
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
    @Environment(SettingsStorage.self) private var settings
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
    @State private var fb1SavedIndicator = false
    @State private var fb2SavedIndicator = false
    @Environment(Theme.self) private var theme

    enum ProviderHealthStatus {
        case unknown, checking, healthy, unhealthy(String)
    }

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section("Primary Provider") {
                Picker("Provider", selection: Binding(
                    get: { settings.aiProvider },
                    set: { newPrimary in
                        settings.aiProvider = newPrimary
                        normalizeFallbackProviders(for: newPrimary)
                    }
                )) {
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
                    .foregroundStyle(theme.secondaryTextColor)

                fallbackPicker("Fallback 1", selection: Binding(
                    get: {
                        guard let sec = settings.secondaryProvider, sec != settings.aiProvider else { return "__none__" }
                        return sec.rawValue
                    },
                    set: { settings.secondaryProvider = $0 == "__none__" ? nil : AIProviderType(rawValue: $0) }
                ))

                if let sec = settings.secondaryProvider, sec != settings.aiProvider {
                    fallbackProviderConfig(sec, keyBinding: $fb1KeyInput, modelBinding: $fb1ModelInput, savedBinding: $fb1SavedIndicator)
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
                    fallbackProviderConfig(ter, keyBinding: $fb2KeyInput, modelBinding: $fb2ModelInput, savedBinding: $fb2SavedIndicator)
                }
            }

            Section("Test Connection") {
                HStack {
                    Button(action: testConnection) {
                        HStack {
                            if isTesting {
                                ProgressView().controlSize(.small)
                            }
                            Text(isTesting ? "Testing..." : "Test Connection")
                        }
                    }
                    .disabled(isTesting || isCheckingAllProviders)

                    Spacer()

                    Button(action: {
                        Task { await checkAllProviders() }
                    }) {
                        HStack {
                            if isCheckingAllProviders {
                                ProgressView().controlSize(.small)
                            }
                            Text(isCheckingAllProviders ? "Checking..." : "Check All Providers")
                        }
                    }
                    .font(.caption)
                    .disabled(isTesting || isCheckingAllProviders)
                }

                if let result = testResult {
                    Text(result)
                        .font(.caption)
                        .foregroundStyle(result.hasPrefix("✓") ? theme.successColor : theme.errorColor)
                        .textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            refreshCLIDetection()
            Task { ollamaInstalledModels = await OllamaProvider.fetchInstalledModels() }
        }
        .onDisappear {
            apiKeyInput = ""
            testResult = nil
            isTesting = false
            isCheckingAllProviders = false
            modelInput = ""
            savedIndicator = false
            modelSavedIndicator = false
            modelSetError = nil
            fb1KeyInput = ""
            fb2KeyInput = ""
            fb1ModelInput = ""
            fb2ModelInput = ""
            fb1SavedIndicator = false
            fb2SavedIndicator = false
        }
    }

    @ViewBuilder
    private func statusDot(for provider: AIProviderType) -> some View {
        let key = provider.rawValue
        switch providerHealth[key] {
        case .healthy:
            Circle().fill(theme.successColor).frame(width: 8, height: 8)
        case .unhealthy:
            Circle().fill(theme.errorColor).frame(width: 8, height: 8)
        case .checking:
            Circle().fill(theme.warningColor).frame(width: 8, height: 8)
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
                    .foregroundStyle(theme.successColor)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Not found", systemImage: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(theme.errorColor)
                    if let instructions = provider.setupInstructions {
                        Text(instructions)
                            .font(.caption2)
                            .foregroundStyle(theme.secondaryTextColor)
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
                    .foregroundStyle(theme.successColor)
            }
        }
        if SecureStore.shared.hasKey(for: provider.rawValue) {
            HStack {
                Label("Key saved", systemImage: "key.fill")
                    .font(.caption)
                    .foregroundStyle(theme.successColor)
                Spacer()
                Button("Remove Key") {
                    SecureStore.shared.deleteKey(for: provider.rawValue)
                }
                .font(.caption)
                .foregroundStyle(theme.errorColor)
            }
        } else {
            Text("⚠️ No API key saved for \(provider.rawValue)")
                .font(.caption)
                .foregroundStyle(theme.warningColor)
        }
    }

    @ViewBuilder
    private func modelSection(for provider: AIProviderType, modelBinding: Binding<String>) -> some View {
        let currentModel = settings.modelName(for: provider)
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Model:")
                    .font(.caption)
                TextField(currentModel, text: Binding(
                    get: { modelBinding.wrappedValue },
                    set: { modelBinding.wrappedValue = $0; modelSetError = nil }
                ))
                .textFieldStyle(.roundedBorder)
                Button("Set") {
                    let name = modelBinding.wrappedValue.isEmpty ? currentModel : modelBinding.wrappedValue
                    if provider == .ollama, !ollamaInstalledModels.isEmpty {
                        let isInstalled = ollamaInstalledModels.contains(where: {
                            $0 == name ||
                            $0.hasPrefix(name + ":") ||
                            name == ($0.components(separatedBy: ":").first ?? $0)
                        })
                        if !isInstalled {
                            modelSetError = "'\(name)' is not installed. Use a model from the Quick list."
                            return
                        }
                    }
                    modelSetError = nil
                    settings.setModelName(name, for: provider)
                    modelBinding.wrappedValue = ""
                    modelSavedIndicator = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { modelSavedIndicator = false }
                }
                if modelSavedIndicator {
                    Text("Set ✓")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            }
            if let err = modelSetError, provider == .ollama {
                Text(err)
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
            Text(provider.modelHint)
                .font(.caption2)
                .foregroundStyle(theme.secondaryTextColor)

            let quickModels = provider == .ollama ? ollamaInstalledModels : provider.suggestedModels
            if !quickModels.isEmpty {
                HStack(spacing: 4) {
                    Text("Quick:")
                        .font(.caption2)
                        .foregroundStyle(theme.secondaryTextColor)
                    ForEach(quickModels, id: \.self) { model in
                        Button(model) {
                            modelSetError = nil
                            settings.setModelName(model, for: provider)
                            modelSavedIndicator = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { modelSavedIndicator = false }
                        }
                        .font(.caption2)
                        .buttonStyle(.bordered)
                        .tint(settings.modelName(for: provider) == model ? theme.accentColor : nil)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func fallbackProviderConfig(_ provider: AIProviderType, keyBinding: Binding<String>, modelBinding: Binding<String>, savedBinding: Binding<Bool>) -> some View {
        // Header: status dot + provider name + CLI status
        HStack(spacing: 6) {
            statusDot(for: provider)
            Text(provider.rawValue)
                .font(.caption)
                .foregroundStyle(theme.secondaryTextColor)
            Spacer()
            if provider.isCLI {
                if cliDetected[provider.cliCommand ?? ""] != nil {
                    Label("Found", systemImage: "checkmark.circle.fill")
                        .font(.caption2)
                        .foregroundStyle(theme.successColor)
                } else {
                    Text("Not installed")
                        .font(.caption2)
                        .foregroundStyle(theme.errorColor)
                }
            }
        }

        // API key management — mirrors primary provider behaviour
        if provider.needsAPIKey {
            if SecureStore.shared.hasKey(for: provider.rawValue) {
                HStack {
                    Label("Key saved", systemImage: "key.fill")
                        .font(.caption2)
                        .foregroundStyle(theme.successColor)
                    Spacer()
                    Button("Remove Key") {
                        SecureStore.shared.deleteKey(for: provider.rawValue)
                    }
                    .font(.caption2)
                    .foregroundStyle(theme.errorColor)
                }
            } else {
                HStack {
                    SecureField("API Key for \(provider.rawValue)", text: keyBinding)
                        .textFieldStyle(.roundedBorder)
                        .font(.caption)
                    Button("Save") {
                        SecureStore.shared.save(key: keyBinding.wrappedValue, for: provider.rawValue)
                        keyBinding.wrappedValue = ""
                        savedBinding.wrappedValue = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { savedBinding.wrappedValue = false }
                    }
                    .font(.caption)
                    if savedBinding.wrappedValue {
                        Text("Saved ✓")
                            .font(.caption2)
                            .foregroundStyle(theme.successColor)
                    }
                }
                Text("⚠️ No API key saved for \(provider.rawValue)")
                    .font(.caption2)
                    .foregroundStyle(theme.warningColor)
            }
        }

        let savedModel = settings.modelName(for: provider)
        let displayedModel = modelBinding.wrappedValue.isEmpty ? savedModel : modelBinding.wrappedValue

        HStack {
            Text("Model:")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(displayedModel)
                .font(.caption2)
            Spacer()
            let quickModels = provider == .ollama
                ? Array(ollamaInstalledModels.prefix(3))
                : Array(provider.suggestedModels.prefix(3))
            ForEach(quickModels, id: \.self) { model in
                Button(model) {
                    modelBinding.wrappedValue = model
                    settings.setModelName(model, for: provider)
                }
                .font(.caption2)
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .tint(displayedModel == model ? theme.accentColor : nil)
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

    private func normalizeFallbackProviders(for primary: AIProviderType) {
        if settings.secondaryProvider == primary {
            settings.secondaryProvider = nil
        }
        if settings.tertiaryProvider == primary || settings.tertiaryProvider == settings.secondaryProvider {
            settings.tertiaryProvider = nil
        }
    }

    private func testConnection() {
        isTesting = true
        testResult = nil
        let providerType = settings.aiProvider
        Task {
            settingsLog.debug("Testing \(providerType.rawValue, privacy: .public) AI provider")
            do {
                let result = try await runProviderProbe(for: providerType)
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
        isCheckingAllProviders = true
        testResult = nil
        let chain: [AIProviderType] = [settings.aiProvider] +
            [settings.secondaryProvider, settings.tertiaryProvider].compactMap { $0 }
        var lines: [String] = []
        var failures = 0
        for pt in chain {
            providerHealth[pt.rawValue] = .checking
            do {
                let result = try await runProviderProbe(for: pt)
                providerHealth[pt.rawValue] = .healthy
                lines.append("✓ \(pt.rawValue): \(result.rawValue)")
            } catch {
                providerHealth[pt.rawValue] = .unhealthy(error.localizedDescription)
                lines.append("✗ \(pt.rawValue): \(error.localizedDescription)")
                failures += 1
            }
        }
        let summary = failures == 0
            ? "✓ All providers passed"
            : "✗ \(failures)/\(chain.count) providers failed"
        testResult = ([summary] + lines).joined(separator: "\n")
        isCheckingAllProviders = false
    }

    private func runProviderProbe(for providerType: AIProviderType) async throws -> Category {
        if providerType.needsAPIKey && !SecureStore.shared.hasKey(for: providerType.rawValue) {
            throw AIError.noAPIKey
        }
        if providerType.isCLI {
            let cmd = providerType.cliCommand ?? ""
            if CLIProvider.detectCLI(command: cmd) == nil {
                throw AIError.cliNotFound(cmd)
            }
        }
        let provider = AIProviderFactory.create(for: providerType)
        return try await provider.categorize(
            appName: "Safari",
            bundleID: "com.apple.Safari",
            windowTitle: "GitHub - Swift",
            url: "https://github.com"
        )
    }
}

// MARK: - Categories Tab
struct CategoriesTab: View {
    @State private var editingCategory: CategoryDefinition?
    @State private var showAddSheet = false
    @State private var categories: [CategoryDefinition] = CategoryManager.shared.allCategories
    @Environment(Theme.self) private var theme

    // Protected categories that cannot be deleted
    private let protectedNames: Set<String> = ["Idle", "Uncategorized", "Work", "Distraction"]

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
                                .background(theme.successColor.opacity(0.15))
                                .foregroundStyle(theme.successColor)
                                .cornerRadius(4)
                        }
                        if protectedNames.contains(cat.name) {
                            Image(systemName: "lock.fill")
                                .font(.caption2)
                                .foregroundStyle(theme.secondaryTextColor)
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
                    .foregroundStyle(theme.secondaryTextColor)
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
            .withEnvironment()
        }
        .sheet(isPresented: $showAddSheet) {
            AddCategorySheet {
                categories = CategoryManager.shared.allCategories
            }
            .withEnvironment()
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
    @Environment(Theme.self) private var theme

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
                        .foregroundStyle(theme.selectedForegroundColor)
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
                                    .foregroundStyle(category.icon == icon ? theme.selectedForegroundColor : .primary)
                                    .background(
                                        RoundedRectangle(cornerRadius: 6)
                                            .fill(category.icon == icon ? pickedColor : theme.dividerColor.opacity(0.15))
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
                    .foregroundStyle(theme.errorColor)
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
    @Environment(Theme.self) private var theme

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
                        .foregroundStyle(theme.selectedForegroundColor)
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
                                    .foregroundStyle(icon == ic ? theme.selectedForegroundColor : .primary)
                                    .background(
                                        RoundedRectangle(cornerRadius: 6)
                                            .fill(icon == ic ? pickedColor : theme.dividerColor.opacity(0.15))
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
    @Environment(Theme.self) private var theme

    var body: some View {
        VStack(spacing: 0) {
            List {
                Section {
                    if customRules.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "text.badge.plus")
                                .font(.title2)
                                .foregroundStyle(theme.secondaryTextColor)
                            Text("No custom rules yet")
                                .font(.subheadline)
                                .foregroundStyle(theme.secondaryTextColor)
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
                                .foregroundStyle(theme.infoColor)
                                .frame(width: 20)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(rule.pattern)
                                    .font(.subheadline.bold())
                                Text(rule.matchType.rawValue.replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression).capitalized)
                                    .font(.caption)
                                    .foregroundStyle(theme.secondaryTextColor)
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
                            .background(theme.infoColor.opacity(0.08))
                            .cornerRadius(6)

                            Button(action: {
                                RuleEngine.shared.removeRule(withId: rule.id)
                                customRules = RuleEngine.shared.allCustomRules
                            }) {
                                Image(systemName: "trash")
                                    .font(.caption)
                                    .foregroundStyle(theme.errorColor)
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
                            .foregroundStyle(theme.infoColor)
                        Text("Built-in rules: \(RuleEngine.shared.defaultRuleCount). Custom rules take priority over defaults.")
                            .font(.caption)
                            .foregroundStyle(theme.secondaryTextColor)
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
            .withEnvironment()
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
    @Environment(SettingsStorage.self) private var settings
    @Environment(Theme.self) private var theme

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section("Theme") {
                Picker("App Theme", selection: $settings.appTheme) {
                    ForEach(ColorSetName.allCases) { colorSetName in
                        HStack {
                            Circle()
                                .fill(colorSetName.colorSet.accentColor)
                                .frame(width: 12, height: 12)
                            Text(colorSetName.rawValue)
                        }
                        .tag(colorSetName)
                    }
                }
                .pickerStyle(.radioGroup)

                Text(themeDescription)
                    .font(.caption)
                    .foregroundStyle(theme.secondaryTextColor)
            }

            Section("Preview") {
                HStack(spacing: 12) {
                    themePreviewBox("Card", color: theme.cardBackgroundColor)
                    themePreviewBox("BG", color: theme.timelineBackgroundColor)
                    themePreviewBox("Sidebar", color: theme.sidebarBackgroundColor)
                    themePreviewBox("Accent", color: theme.accentColor, textColor: theme.selectedForegroundColor)
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
                    .stroke(theme.dividerColor.opacity(0.2), lineWidth: 0.5)
            )
    }
}

// MARK: - Privacy Tab
struct PrivacyTab: View {
    @Environment(SettingsStorage.self) private var settings
    @State private var showClearConfirm = false
    @State private var showClearAIConfirm = false
    @State private var showClearTodayConfirm = false
    @State private var showClearOldConfirm = false
    @State private var showClearTasksConfirm = false
    @State private var showClearEverythingConfirm = false
    @State private var clearDaysOption: Int = 30
    @State private var clearResult: String?
    @State private var clearError: String?
    @State private var newBundleID = ""
    @State private var storageStats: (activities: Int, aiRecords: Int, segments: Int, bytes: Int64) = (0, 0, 0, 0)
    @Environment(Theme.self) private var theme

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section("Data Collection") {
                Toggle("Capture Window Titles", isOn: $settings.captureWindowTitles)
                VStack(alignment: .leading, spacing: 4) {
                    Text("FlowTrack tracks which apps you use. Window titles add context but may contain sensitive info.")
                        .font(.caption)
                        .foregroundStyle(theme.secondaryTextColor)
                    Text("All data is stored locally. Nothing is sent to a server unless you use an API-based AI provider.")
                        .font(.caption)
                        .foregroundStyle(theme.secondaryTextColor)
                }
            }

            Section("Excluded Apps") {
                if settings.excludedBundleIDs.isEmpty {
                    Text("No apps excluded")
                        .foregroundStyle(theme.secondaryTextColor)
                        .font(.callout)
                } else {
                    ForEach(settings.excludedBundleIDs, id: \.self) { bundle in
                        HStack {
                            Text(bundle).font(.callout)
                            Spacer()
                            Button(action: {
                                settings.excludedBundleIDs.removeAll { $0 == bundle }
                            }) {
                                Image(systemName: "minus.circle.fill").foregroundStyle(theme.errorColor)
                            }.buttonStyle(.plain)
                        }
                    }
                }
                HStack {
                    TextField("com.example.app", text: $newBundleID)
                        .textFieldStyle(.roundedBorder)
                    Button("Add") {
                        let trimmed = newBundleID.trimmingCharacters(in: .whitespaces)
                        if !trimmed.isEmpty && !settings.excludedBundleIDs.contains(trimmed) {
                            settings.excludedBundleIDs.append(trimmed)
                        }
                        newBundleID = ""
                    }
                    .disabled(newBundleID.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Text("Excluded apps are never tracked or stored.")
                    .font(.caption).foregroundStyle(theme.secondaryTextColor)
            }

            Section("AI Provider Privacy") {
                VStack(alignment: .leading, spacing: 8) {
                    Label("When using AI providers, app names and window titles are sent for categorization.", systemImage: "brain")
                        .font(.callout)
                    Text("CLI providers (Claude Code, ChatGPT Codex) process data through your local installation. API providers send data to their respective cloud services.")
                        .font(.caption)
                        .foregroundStyle(theme.secondaryTextColor)
                }
            }

            // ── Storage Stats ──────────────────────────────────────────────────
            Section("Storage") {
                HStack {
                    Label("Activity Records", systemImage: "clock.arrow.circlepath")
                    Spacer()
                    Text("\(storageStats.activities)")
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(theme.secondaryTextColor)
                }
                HStack {
                    Label("AI Summaries", systemImage: "sparkles")
                    Spacer()
                    Text("\(storageStats.aiRecords)")
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(theme.secondaryTextColor)
                }
                HStack {
                    Label("AI Segments", systemImage: "rectangle.split.3x1")
                    Spacer()
                    Text("\(storageStats.segments)")
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(theme.secondaryTextColor)
                }
                HStack {
                    Label("Tasks", systemImage: "checklist")
                    Spacer()
                    Text("\(TodoStore.shared.todos.count) tasks · \(TodoStore.shared.timerSessions.count) sessions")
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(theme.secondaryTextColor)
                }
                HStack {
                    Label("Database Size", systemImage: "internaldrive")
                    Spacer()
                    Text(formatBytes(storageStats.bytes))
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(theme.secondaryTextColor)
                }
                Button("Refresh") { refreshStats() }
                    .font(.caption)
                    .foregroundStyle(theme.accentColor)
            }
            .onAppear { refreshStats() }

            // ── Activity Data ──────────────────────────────────────────────────
            Section("Activity Data") {
                Button("Clear Today's Activity") {
                    showClearTodayConfirm = true
                }
                .foregroundStyle(theme.warningColor)

                HStack {
                    Text("Clear older than")
                        .font(.callout)
                    Spacer()
                    Picker("", selection: $clearDaysOption) {
                        Text("7 days").tag(7)
                        Text("30 days").tag(30)
                        Text("90 days").tag(90)
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    Button("Clear") { showClearOldConfirm = true }
                        .foregroundStyle(theme.warningColor)
                }

                Button("Clear All Activity Data") {
                    showClearConfirm = true
                }
                .foregroundStyle(theme.errorColor)

                Button("Clear Today's AI Analysis") {
                    showClearAIConfirm = true
                }
                .foregroundStyle(theme.secondaryTextColor)
            }

            // ── Tasks & Timer ──────────────────────────────────────────────────
            Section("Tasks & Timer") {
                Button("Clear Completed Tasks") {
                    TodoStore.shared.clearCompletedTodos()
                    setResult("Completed tasks cleared")
                }
                .foregroundStyle(theme.warningColor)

                Button("Clear Timer Sessions") {
                    TodoStore.shared.clearTimerSessions()
                    setResult("Timer sessions cleared")
                }
                .foregroundStyle(theme.warningColor)

                Button("Clear All Tasks & Sessions") {
                    showClearTasksConfirm = true
                }
                .foregroundStyle(theme.errorColor)
            }

            // ── API Keys ───────────────────────────────────────────────────────
            Section("API Keys") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("API keys are stored securely in the macOS Keychain.")
                        .font(.caption)
                        .foregroundStyle(theme.secondaryTextColor)
                }
                Button("Remove All API Keys") {
                    for provider in AIProviderType.allCases where provider.needsAPIKey {
                        SecureStore.shared.deleteKey(for: provider.rawValue)
                    }
                    setResult("All API keys removed")
                }
                .foregroundStyle(theme.errorColor)
            }

            // ── Nuclear Option ─────────────────────────────────────────────────
            Section {
                Button(role: .destructive) {
                    showClearEverythingConfirm = true
                } label: {
                    Label("Clear Everything", systemImage: "trash.fill")
                        .font(.body.weight(.semibold))
                }
            } footer: {
                Text("Permanently deletes all activities, AI data, tasks, and timer sessions. Cannot be undone.")
                    .font(.caption)
                    .foregroundStyle(theme.errorColor.opacity(0.7))
            }

            if let result = clearResult {
                Section {
                    Label(result, systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(theme.successColor)
                }
            }
        }
        .formStyle(.grouped)
        // ── Alerts ────────────────────────────────────────────────────────────
        .alert("Clear Today's Activity?", isPresented: $showClearTodayConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Clear", role: .destructive) {
                do {
                    try Database.shared.clearTodaysActivities()
                    Task { await AppState.shared.refreshData() }
                    setResult("Today's activity cleared")
                } catch { clearError = error.localizedDescription }
            }
        } message: { Text("This will delete all activity records for today.") }

        .alert("Clear Old Data?", isPresented: $showClearOldConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Clear", role: .destructive) {
                do {
                    try Database.shared.clearActivitiesOlderThan(days: clearDaysOption)
                    Task { await AppState.shared.refreshData() }
                    refreshStats()
                    setResult("Data older than \(clearDaysOption) days cleared")
                } catch { clearError = error.localizedDescription }
            }
        } message: { Text("This will permanently delete all activity records older than \(clearDaysOption) days.") }

        .alert("Clear Today's AI Analysis?", isPresented: $showClearAIConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Clear", role: .destructive) {
                do {
                    try Database.shared.clearTodaysAIAnalysis()
                    Task { await AppState.shared.refreshData(force: true) }
                    refreshStats()
                    setResult("Today's AI analysis cleared")
                } catch { clearError = error.localizedDescription }
            }
        } message: { Text("This will remove today's AI-generated analysis. Activity data is kept and AI will re-analyze on next run.") }

        .alert("Clear All Activity Data?", isPresented: $showClearConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Clear", role: .destructive) {
                do {
                    try Database.shared.clearAllData()
                    Task { await AppState.shared.refreshData(force: true) }
                    refreshStats()
                    setResult("All activity data cleared")
                    NotificationCenter.default.post(name: .init("FlowTrackDataCleared"), object: nil)
                } catch { clearError = error.localizedDescription }
            }
        } message: { Text("This will permanently delete all activity records and AI summaries. Tasks and timer sessions will NOT be affected.") }

        .alert("Clear All Tasks?", isPresented: $showClearTasksConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Clear", role: .destructive) {
                TodoStore.shared.clearAll()
                setResult("All tasks and timer sessions cleared")
            }
        } message: { Text("This will delete all tasks and timer sessions. Activity tracking data will NOT be affected.") }

        .alert("Clear Everything?", isPresented: $showClearEverythingConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Delete All Data", role: .destructive) {
                do {
                    try Database.shared.clearAllData()
                    TodoStore.shared.clearAll()
                    Task { await AppState.shared.refreshData(force: true) }
                    refreshStats()
                    setResult("Everything cleared")
                    NotificationCenter.default.post(name: .init("FlowTrackDataCleared"), object: nil)
                } catch { clearError = error.localizedDescription }
            }
        } message: { Text("This will permanently delete ALL activities, AI summaries, tasks, and timer sessions. This cannot be undone.") }

        .alert("Error", isPresented: Binding(get: { clearError != nil }, set: { if !$0 { clearError = nil } })) {
            Button("OK", role: .cancel) { clearError = nil }
        } message: { Text(clearError ?? "") }
    }

    private func setResult(_ msg: String) {
        clearResult = msg
        refreshStats()
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { clearResult = nil }
    }

    private func refreshStats() {
        storageStats = Database.shared.storageStats()
    }

    private func formatBytes(_ bytes: Int64) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1024 * 1024 { return String(format: "%.1f KB", Double(bytes) / 1024) }
        return String(format: "%.1f MB", Double(bytes) / (1024 * 1024))
    }
}

// MARK: - Export Tab
struct ExportTab: View {
    @State private var exportResult: String?
    @Environment(Theme.self) private var theme

    var body: some View {
        Form {
            Section("Export Activities") {
                Text("Export your activity data as CSV or JSON for analysis in other tools.")
                    .font(.caption)
                    .foregroundStyle(theme.secondaryTextColor)

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
                        .foregroundStyle(theme.successColor)
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
