import SwiftUI
import AppKit

// MARK: - AppBlockerView
struct AppBlockerView: View {
    @Bindable private var store = AppBlockerStore.shared
    @Environment(Theme.self) private var theme
    @State private var showAddCard = false
    @State private var editingCard: BlockCard? = nil

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                header
                if store.cards.isEmpty {
                    emptyState
                } else {
                    LazyVStack(spacing: 14) {
                        ForEach(store.cards) { card in
                            BlockCardRow(card: card) {
                                editingCard = card
                            }
                        }
                    }
                }
            }
            .padding(20)
        }
        .background(theme.timelineBackgroundColor)
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button { showAddCard = true } label: {
                    Label("New Card", systemImage: "plus")
                }
            }
        }
        .sheet(isPresented: $showAddCard) {
            BlockCardSheet(isPresented: $showAddCard)
                .withEnvironment()
        }
        .sheet(item: $editingCard) { card in
            BlockCardSheet(isPresented: Binding(
                get: { editingCard != nil },
                set: { if !$0 { editingCard = nil } }
            ), editingCard: card)
                .withEnvironment()
        }
    }

    // MARK: - Header
    private var header: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 14)
                    .fill(LinearGradient(colors: [Color.purple, Color.indigo],
                                        startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 52, height: 52)
                    .shadow(color: Color.purple.opacity(0.4), radius: 10, y: 4)
                Image(systemName: "shield.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(theme.selectedForegroundColor)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text("Focus Shield")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(theme.primaryTextColor)
                Text("Block distracting sites and apps by creating focus cards.")
                    .font(.caption)
                    .foregroundStyle(theme.secondaryTextColor)
            }
            Spacer()
            Button { showAddCard = true } label: {
                Label("New Card", systemImage: "plus.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(theme.selectedForegroundColor)
                    .padding(.horizontal, 14).padding(.vertical, 7)
                    .background(theme.accentColor, in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
        }
        .padding(16)
        .background(theme.cardBackgroundColor, in: RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - Empty State
    private var emptyState: some View {
        VStack(spacing: 20) {
            Image(systemName: "shield.fill").font(.system(size: 52))
                .foregroundStyle(theme.secondaryTextColor.opacity(0.4))
            Text("No Focus Cards Yet")
                .font(.headline)
                .foregroundStyle(theme.primaryTextColor)
            Text("Create cards to group distracting websites and apps.\nEnable a card to block everything in it.")
                .font(.subheadline)
                .foregroundStyle(theme.secondaryTextColor)
                .multilineTextAlignment(.center)
            VStack(spacing: 10) {
                Button { showAddCard = true } label: {
                    Label("Create Card Manually", systemImage: "plus.circle.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(theme.selectedForegroundColor)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(theme.accentColor, in: RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
                Button {
                    showAddCard = true
                } label: {
                    Label("Generate with AI ✨", systemImage: "sparkles")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(theme.accentColor)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(theme.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
            }
            .frame(maxWidth: 260)
        }
        .frame(maxWidth: .infinity)
        .padding(40)
        .background(theme.cardBackgroundColor, in: RoundedRectangle(cornerRadius: 14))
    }
}

// MARK: - Block Card Row
private struct BlockCardRow: View {
    let card: BlockCard
    let onEdit: () -> Void
    @State private var expanded = false
    private var store: AppBlockerStore { AppBlockerStore.shared }
    @Environment(Theme.self) private var theme

    private var usedSeconds: Int { store.usageToday(for: card.id) }
    private var limitSeconds: Int { card.dailyLimitMinutes * 60 }
    private var usageFraction: Double {
        guard limitSeconds > 0 else { return card.isEnabled ? 1 : 0 }
        return min(1, Double(usedSeconds) / Double(limitSeconds))
    }

    var body: some View {
        VStack(spacing: 0) {
            mainRow
            if expanded { expandedDetail }
        }
        .background(theme.cardBackgroundColor, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(
            card.isEnabled ? card.accentColor.opacity(0.25) : theme.dividerColor.opacity(0.1),
            lineWidth: 1
        ))
    }

    @ViewBuilder private var mainRow: some View {
        HStack(spacing: 14) {
            // Emoji + color badge
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(card.accentColor.opacity(card.isEnabled ? 0.18 : 0.07))
                    .frame(width: 46, height: 46)
                Image(systemName: card.iconName)
                    .font(.system(size: 22))
                    .foregroundStyle(card.accentColor)
                    .grayscale(card.isEnabled ? 0 : 0.8)
            }

            cardInfo

            Spacer()

            // Toggle
            Toggle("", isOn: Binding(
                get: { card.isEnabled },
                set: { _ in store.toggleCard(id: card.id) }
            ))
            .toggleStyle(.switch)
            .scaleEffect(0.8)
            .labelsHidden()

            // Expand chevron
            Button {
                withAnimation(.spring(response: 0.3)) { expanded.toggle() }
            } label: {
                Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(theme.secondaryTextColor)
                    .frame(width: 24, height: 24)
                    .background(theme.dividerColor.opacity(0.1), in: Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .contentShape(Rectangle())
        .contextMenu {
            Button("Edit Card") { onEdit() }
            Divider()
            Button("Delete Card", role: .destructive) { store.deleteCard(id: card.id) }
        }
    }

    @ViewBuilder private var cardInfo: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text(card.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(card.isEnabled ? theme.primaryTextColor : theme.secondaryTextColor)
                if card.isEnabled {
                    Text(card.isAlwaysBlock ? "Always On" : "Active")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(card.accentColor)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(card.accentColor.opacity(0.12), in: Capsule())
                }
            }
            HStack(spacing: 6) {
                if !card.websites.isEmpty {
                    Label("\(card.websites.count) site\(card.websites.count == 1 ? "" : "s")", systemImage: "globe")
                        .font(.caption2).foregroundStyle(theme.secondaryTextColor)
                }
                if !card.apps.isEmpty {
                    Label("\(card.apps.count) app\(card.apps.count == 1 ? "" : "s")", systemImage: "app.fill")
                        .font(.caption2).foregroundStyle(theme.secondaryTextColor)
                }
                if card.websites.isEmpty && card.apps.isEmpty {
                    Text("Empty — add sites or apps")
                        .font(.caption2).foregroundStyle(theme.secondaryTextColor.opacity(0.6))
                }
            }
            if !card.isAlwaysBlock && card.isEnabled && limitSeconds > 0 {
                usageBar
            }
        }
    }

    @ViewBuilder private var usageBar: some View {
        HStack(spacing: 6) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2).fill(theme.dividerColor.opacity(0.15)).frame(height: 3)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(usageFraction >= 0.9 ? theme.errorColor : card.accentColor)
                        .frame(width: max(0, geo.size.width * CGFloat(usageFraction)), height: 3)
                }
            }.frame(height: 3)
            Text("\(usedSeconds / 60)/\(card.dailyLimitMinutes)m")
                .font(.system(size: 9).monospacedDigit())
                .foregroundStyle(usageFraction >= 0.9 ? theme.errorColor : theme.secondaryTextColor)
                .frame(width: 44, alignment: .trailing)
        }
    }

    @ViewBuilder private var expandedDetail: some View {
        Divider().padding(.horizontal, 14)
        VStack(alignment: .leading, spacing: 10) {
            if !card.websites.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Websites", systemImage: "globe")
                        .font(.caption.weight(.semibold)).foregroundStyle(theme.secondaryTextColor)
                    FlowLayout(spacing: 6) {
                        ForEach(card.websites, id: \.self) { site in
                            Text(site).font(.caption2).foregroundStyle(theme.primaryTextColor)
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .background(theme.dividerColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                        }
                    }
                }
            }
            if !card.apps.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Apps", systemImage: "app.fill")
                        .font(.caption.weight(.semibold)).foregroundStyle(theme.secondaryTextColor)
                    FlowLayout(spacing: 6) {
                        ForEach(Array(card.apps)) { app in
                            Text(app.displayName).font(.caption2).foregroundStyle(theme.primaryTextColor)
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .background(theme.dividerColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                        }
                    }
                }
            }
            HStack(spacing: 8) {
                Button("Edit Card") { onEdit() }
                    .font(.caption.weight(.semibold)).foregroundStyle(theme.accentColor).buttonStyle(.plain)
                Spacer()
                Button("Delete", role: .destructive) { store.deleteCard(id: card.id) }
                    .font(.caption).foregroundStyle(theme.errorColor).buttonStyle(.plain)
            }
        }
        .padding(14)
        .transition(.opacity.combined(with: .move(edge: .top)))
    }
}

// MARK: - Block Card Sheet (Create / Edit)
struct BlockCardSheet: View {
    @Binding var isPresented: Bool
    var editingCard: BlockCard? = nil
    @Environment(Theme.self) private var theme
    private var store: AppBlockerStore { AppBlockerStore.shared }

    // Card fields
    @State private var name: String = ""
    @State private var iconName: String = "nosign"
    @State private var colorName: String = "purple"
    @State private var alwaysBlock = true
    @State private var limitMinutes = 60
    @State private var websites: [String] = []
    @State private var apps: [BlockedApp] = []

    // UI state
    @State private var newSite = ""
    @State private var appSearchQuery = ""
    @State private var installedApps: [InstalledAppInfo] = []
    @State private var tab = 0 // 0=websites 1=apps
    @State private var aiPrompt = ""
    @State private var aiLoading = false
    @State private var aiError: String? = nil
    @State private var showAI = false
    @State private var showIconPicker = false

    private let colors = ["purple", "blue", "red", "orange", "green", "teal", "pink", "yellow"]
    private let colorValues: [String: Color] = [
        "purple": .purple, "blue": .blue, "red": .red, "orange": .orange,
        "green": Color(red: 0.2, green: 0.75, blue: 0.45), "teal": .teal, "pink": .pink, "yellow": .yellow
    ]
    private var accentColor: Color { colorValues[colorName] ?? .purple }
    private var isEditing: Bool { editingCard != nil }

    private var filteredApps: [InstalledAppInfo] {
        guard !appSearchQuery.isEmpty else { return installedApps }
        return installedApps.filter {
            $0.name.localizedCaseInsensitiveContains(appSearchQuery) ||
            $0.bundleID.localizedCaseInsensitiveContains(appSearchQuery)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 12) {
                Text(isEditing ? "Edit Card" : "New Focus Card")
                    .font(.headline)
                    .foregroundStyle(theme.primaryTextColor)
                Spacer()
                if !isEditing {
                    Button {
                        withAnimation { showAI.toggle() }
                    } label: {
                        Label("AI Setup", systemImage: "sparkles")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(showAI ? theme.selectedForegroundColor : theme.accentColor)
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(showAI ? theme.accentColor : theme.accentColor.opacity(0.1),
                                        in: RoundedRectangle(cornerRadius: 7))
                    }
                    .buttonStyle(.plain)
                }
                Button { isPresented = false } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(theme.secondaryTextColor)
                        .font(.title3)
                }
                .buttonStyle(.plain)
            }
            .padding(16)

            Divider()

            ScrollView {
                VStack(spacing: 16) {
                    // AI section
                    if showAI {
                        aiSection
                    }

                    // Card identity
                    VStack(spacing: 12) {
                        HStack(spacing: 12) {
                            // Icon picker
                            Button {
                                showIconPicker.toggle()
                            } label: {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 10)
                                        .fill(accentColor.opacity(0.12))
                                        .frame(width: 44, height: 44)
                                    Image(systemName: iconName)
                                        .font(.system(size: 20))
                                        .foregroundStyle(accentColor)
                                }
                            }
                            .buttonStyle(.plain)
                            .popover(isPresented: $showIconPicker) {
                                IconPickerView(selected: $iconName, isPresented: $showIconPicker)
                            }

                            TextField("Card name (e.g. Social Media)", text: $name)
                                .textFieldStyle(.roundedBorder)
                                .font(.subheadline)
                        }

                        // Color picker
                        HStack(spacing: 8) {
                            ForEach(colors, id: \.self) { c in
                                let col = colorValues[c] ?? .purple
                                Circle()
                                    .fill(col)
                                    .frame(width: 22, height: 22)
                                    .overlay(
                                        Circle().stroke(theme.primaryTextColor.opacity(0.9), lineWidth: colorName == c ? 2 : 0)
                                            .padding(2)
                                    )
                                    .overlay(
                                        Circle().stroke(col, lineWidth: colorName == c ? 2 : 0)
                                    )
                                    .onTapGesture { colorName = c }
                            }
                            Spacer()
                        }
                    }
                    .padding(14)
                    .background(theme.cardBackgroundColor, in: RoundedRectangle(cornerRadius: 12))

                    // Limit
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle("Always block (no time limit)", isOn: $alwaysBlock)
                            .font(.subheadline)
                            .toggleStyle(.switch)
                        if !alwaysBlock {
                            HStack {
                                Text("Daily limit:")
                                    .font(.subheadline)
                                    .foregroundStyle(theme.secondaryTextColor)
                                Spacer()
                                Stepper("\(limitMinutes) min/day", value: $limitMinutes, in: 5...480, step: 5)
                                    .font(.subheadline)
                            }
                        }
                    }
                    .padding(14)
                    .background(theme.cardBackgroundColor, in: RoundedRectangle(cornerRadius: 12))

                    // Content tabs
                    VStack(spacing: 10) {
                        HStack(spacing: 0) {
                            tabButton(title: "Websites (\(websites.count))", index: 0)
                            tabButton(title: "Apps (\(apps.count))", index: 1)
                        }
                        .background(theme.dividerColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))

                        if tab == 0 {
                            websiteTab
                        } else {
                            appTab
                        }
                    }
                    .padding(14)
                    .background(theme.cardBackgroundColor, in: RoundedRectangle(cornerRadius: 12))
                }
                .padding(16)
            }

            Divider()

            // Footer
            HStack(spacing: 10) {
                Button { isPresented = false } label: {
                    Text("Cancel")
                        .frame(maxWidth: .infinity).padding(.vertical, 9)
                        .background(theme.dividerColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 9))
                }
                .buttonStyle(.plain)
                .foregroundStyle(theme.secondaryTextColor)

                Button { save() } label: {
                    Text(isEditing ? "Save Changes" : "Create Card")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(name.isEmpty ? theme.secondaryTextColor : theme.selectedForegroundColor)
                        .frame(maxWidth: .infinity).padding(.vertical, 9)
                        .background(name.isEmpty ? theme.dividerColor.opacity(0.1) : theme.accentColor,
                                    in: RoundedRectangle(cornerRadius: 9))
                }
                .buttonStyle(.plain)
                .disabled(name.isEmpty)
            }
            .padding(16)
        }
        .frame(width: 440, height: 620)
        .background(theme.sidebarBackgroundColor)
        .onAppear { populate() }
    }

    // MARK: - AI Section
    private var aiSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles").foregroundStyle(theme.accentColor).font(.caption.weight(.semibold))
                Text("Generate with AI").font(.subheadline.weight(.semibold)).foregroundStyle(theme.primaryTextColor)
            }
            Text("Describe what to block (e.g. \"social media\", \"gaming sites\", \"news\")")
                .font(.caption)
                .foregroundStyle(theme.secondaryTextColor)
            HStack(spacing: 8) {
                TextField("e.g. social media distractions", text: $aiPrompt)
                    .textFieldStyle(.roundedBorder)
                    .font(.subheadline)
                Button {
                    Task { await generateWithAI() }
                } label: {
                    if aiLoading {
                        ProgressView().scaleEffect(0.7).frame(width: 70, height: 28)
                    } else {
                        Text("Generate")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(aiPrompt.isEmpty ? theme.secondaryTextColor : theme.selectedForegroundColor)
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(aiPrompt.isEmpty ? theme.dividerColor.opacity(0.1) : theme.accentColor,
                                        in: RoundedRectangle(cornerRadius: 7))
                    }
                }
                .buttonStyle(.plain)
                .disabled(aiPrompt.isEmpty || aiLoading)
            }
            if let err = aiError {
                Text(err).font(.caption).foregroundStyle(theme.errorColor)
            }
        }
        .padding(14)
        .background(theme.accentColor.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(theme.accentColor.opacity(0.15), lineWidth: 1))
    }

    // MARK: - Website Tab
    private var websiteTab: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                TextField("e.g. reddit.com", text: $newSite)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { addSite() }
                Button("Add", action: addSite)
                    .buttonStyle(.plain)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(newSite.isEmpty ? theme.secondaryTextColor : theme.accentColor)
                    .disabled(newSite.isEmpty)
            }
            if websites.isEmpty {
                Text("No websites added yet")
                    .font(.caption)
                    .foregroundStyle(theme.secondaryTextColor.opacity(0.5))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
            } else {
                VStack(spacing: 0) {
                    ForEach(websites, id: \.self) { site in
                        HStack {
                            Image(systemName: "globe").font(.caption).foregroundStyle(theme.secondaryTextColor)
                            Text(site).font(.subheadline).foregroundStyle(theme.primaryTextColor)
                            Spacer()
                            Button { websites.removeAll { $0 == site } } label: {
                                Image(systemName: "xmark").font(.caption2).foregroundStyle(theme.secondaryTextColor)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.vertical, 7)
                        if site != websites.last { Divider() }
                    }
                }
            }
        }
    }

    // MARK: - App Tab
    private var appTab: some View {
        VStack(spacing: 8) {
            TextField("Search apps…", text: $appSearchQuery)
                .textFieldStyle(.roundedBorder)
            if installedApps.isEmpty {
                Text("Loading apps…")
                    .font(.caption).foregroundStyle(theme.secondaryTextColor)
                    .frame(maxWidth: .infinity).padding(.vertical, 12)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(filteredApps.prefix(60))) { app in
                            appRow(app)
                        }
                    }
                }
                .frame(height: 180)
            }
        }
    }

    @ViewBuilder private func appRow(_ app: InstalledAppInfo) -> some View {
        let isSelected = apps.contains(where: { $0.bundleID == app.bundleID })
        Button {
            if isSelected {
                apps.removeAll { $0.bundleID == app.bundleID }
            } else {
                apps.append(BlockedApp(displayName: app.name, bundleID: app.bundleID))
            }
        } label: {
            HStack(spacing: 10) {
                if let icon = app.icon {
                    Image(nsImage: icon).resizable().frame(width: 22, height: 22)
                } else {
                    Image(systemName: "app.fill").frame(width: 22, height: 22)
                        .foregroundStyle(theme.secondaryTextColor)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(app.name).font(.subheadline)
                        .foregroundStyle(isSelected ? theme.accentColor : theme.primaryTextColor)
                    Text(app.bundleID).font(.caption2).foregroundStyle(theme.secondaryTextColor)
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(theme.accentColor)
                }
            }
            .padding(.horizontal, 6).padding(.vertical, 6)
            .background(isSelected ? theme.accentColor.opacity(0.07) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Tab Button
    private func tabButton(title: String, index: Int) -> some View {
        Button { tab = index } label: {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(tab == index ? theme.selectedForegroundColor : theme.secondaryTextColor)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .background(tab == index ? theme.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .padding(2)
    }

    // MARK: - Helpers
    private func addSite() {
        let cleaned = newSite
            .lowercased()
            .replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
            .replacingOccurrences(of: "www.", with: "")
            .components(separatedBy: "/").first ?? newSite
        let site = cleaned.trimmingCharacters(in: .whitespaces)
        guard !site.isEmpty, !websites.contains(site) else { newSite = ""; return }
        websites.append(site)
        newSite = ""
    }

    private func save() {
        var card = editingCard ?? BlockCard(name: name)
        card.name = name
        card.iconName = iconName
        card.colorName = colorName
        card.dailyLimitMinutes = alwaysBlock ? 0 : limitMinutes
        card.websites = websites
        card.apps = apps
        if isEditing {
            store.updateCard(card)
        } else {
            store.addCard(card)
        }
        isPresented = false
    }

    private func populate() {
        if let c = editingCard {
            name = c.name; iconName = c.iconName; colorName = c.colorName
            alwaysBlock = c.isAlwaysBlock
            limitMinutes = c.dailyLimitMinutes == 0 ? 60 : c.dailyLimitMinutes
            websites = c.websites; apps = c.apps
        }
        Task.detached(priority: .utility) {
            let apps = loadInstalledApps()
            await MainActor.run { installedApps = apps }
        }
    }

    private func generateWithAI() async {
        guard !aiPrompt.isEmpty else { return }
        aiLoading = true; aiError = nil
        let systemPrompt = """
        You are a productivity assistant that generates focus cards for blocking distracting websites.
        Always respond with ONLY a valid JSON object — no markdown, no code blocks, no extra text.
        Use this exact format:
        {"name": "card name (2-3 words)", "websites": ["domain1.com", "domain2.com"]}
        Include 5-15 relevant domain names without www or https prefixes.
        """
        let userMessage = "Create a focus card for blocking: \"\(aiPrompt)\""
        let settings = SettingsStorage.shared
        let provider = AIProviderFactory.create(for: settings.aiProvider, model: settings.modelName(for: settings.aiProvider))
        do {
            let raw = try await provider.chat(
                messages: [ChatTurn(role: "user", content: userMessage)],
                systemPrompt: systemPrompt
            )
            // Extract JSON, handling optional markdown code fences
            let jsonString: String
            if let start = raw.firstIndex(of: "{"), let end = raw.lastIndex(of: "}") {
                jsonString = String(raw[start...end])
            } else {
                await MainActor.run { aiError = "AI returned unexpected format. Try again."; aiLoading = false }
                return
            }
            if let data = jsonString.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                await MainActor.run {
                    if let n = json["name"] as? String, !n.isEmpty { name = n }
                    if let sites = json["websites"] as? [String] {
                        for site in sites where !websites.contains(site) {
                            websites.append(site)
                        }
                    }
                    aiLoading = false
                }
            } else {
                await MainActor.run { aiError = "AI returned unexpected format. Try again."; aiLoading = false }
            }
        } catch {
            await MainActor.run { aiError = "AI error: \(error.localizedDescription)"; aiLoading = false }
        }
    }

    nonisolated private func loadInstalledApps() -> [InstalledAppInfo] {
        var seen = Set<String>(); var apps: [InstalledAppInfo] = []
        for app in NSWorkspace.shared.runningApplications {
            guard let name = app.localizedName, let bid = app.bundleIdentifier,
                  app.activationPolicy == .regular, seen.insert(bid).inserted else { continue }
            apps.append(InstalledAppInfo(name: name, bundleID: bid, icon: app.icon))
        }
        for dir in ["/Applications", "/Applications/Utilities",
                    FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path] {
            guard let items = try? FileManager.default.contentsOfDirectory(atPath: dir) else { continue }
            for item in items where item.hasSuffix(".app") {
                let url = URL(fileURLWithPath: dir).appendingPathComponent(item)
                guard let bundle = Bundle(url: url), let bid = bundle.bundleIdentifier,
                      seen.insert(bid).inserted else { continue }
                let name = (bundle.infoDictionary?["CFBundleDisplayName"] as? String)
                    ?? (bundle.infoDictionary?["CFBundleName"] as? String)
                    ?? item.replacingOccurrences(of: ".app", with: "")
                let icon = NSWorkspace.shared.icon(forFile: url.path)
                apps.append(InstalledAppInfo(name: name, bundleID: bid, icon: icon))
            }
        }
        return apps.sorted { $0.name < $1.name }
    }
}

// MARK: - Icon Picker
private struct IconPickerView: View {
    @Binding var selected: String
    @Binding var isPresented: Bool
    @Environment(Theme.self) private var theme
    private let icons = [
        "nosign", "shield.fill", "phone.down.fill", "xmark.octagon.fill", "lock.fill",
        "gamecontroller.fill", "iphone", "bubble.left.fill", "newspaper.fill", "film.fill",
        "music.note", "cart.fill", "dollarsign.circle.fill", "figure.run", "books.vertical.fill",
        "lightbulb.fill", "scope", "alarm.fill", "moon.fill", "cup.and.saucer.fill",
        "figure.mind.and.body", "dumbbell.fill", "flame.fill", "bolt.fill", "water.waves"
    ]
    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(40)), count: 5), spacing: 4) {
            ForEach(icons, id: \.self) { icon in
                Button {
                    selected = icon
                    isPresented = false
                } label: {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(selected == icon ? theme.accentColor.opacity(0.15) : Color.clear)
                            .frame(width: 36, height: 36)
                        Image(systemName: icon)
                            .font(.system(size: 18))
                            .foregroundStyle(selected == icon ? theme.accentColor : theme.primaryTextColor)
                    }
                    .frame(width: 40, height: 40)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(10)
        .frame(width: 220)
    }
}

// MARK: - Flow Layout (wrapping chips)
private struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0; var y: CGFloat = 0; var rowH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > width && x > 0 { y += rowH + spacing; x = 0; rowH = 0 }
            x += s.width + spacing; rowH = max(rowH, s.height)
        }
        return CGSize(width: width, height: y + rowH)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX; var y = bounds.minY; var rowH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > bounds.maxX && x > bounds.minX { y += rowH + spacing; x = bounds.minX; rowH = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing; rowH = max(rowH, s.height)
        }
    }
}

// MARK: - InstalledAppInfo helper
private struct InstalledAppInfo: Identifiable {
    let id = UUID()
    let name: String; let bundleID: String; let icon: NSImage?
}

