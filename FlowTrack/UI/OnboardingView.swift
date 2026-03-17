import SwiftUI
import ApplicationServices

struct OnboardingView: View {
    @Binding var isPresented: Bool
    @State private var step = 0

    // Permission step
    @State private var accessibilityGranted = AXIsProcessTrusted()
    @State private var permissionTimer: Timer?

    // AI setup step
    @State private var selectedProvider: AIProviderType = .ollama
    @State private var apiKey = ""
    @State private var ollamaModel = "mistral"
    @State private var isTesting = false
    @State private var testResult: String?
    @State private var testIsSuccess = false

    private var theme: AppTheme { AppSettings.shared.appTheme }
    private let totalSteps = 4

    /// Whether the current theme uses a dark background
    private var isDarkGradient: Bool {
        switch theme {
        case .dark, .midnight: return true
        case .light, .pastel: return false
        case .system: return NSApp?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        }
    }

    // Theme-aware gradient colors per step
    private var gradientColors: [Color] {
        if isDarkGradient {
            switch step {
            case 0: return [Color(red: 0.10, green: 0.08, blue: 0.20), Color(red: 0.18, green: 0.14, blue: 0.40)]
            case 1: return [Color(red: 0.08, green: 0.16, blue: 0.28), Color(red: 0.12, green: 0.28, blue: 0.42)]
            case 2: return [Color(red: 0.08, green: 0.20, blue: 0.18), Color(red: 0.12, green: 0.32, blue: 0.26)]
            default: return [Color(red: 0.12, green: 0.20, blue: 0.14), Color(red: 0.18, green: 0.36, blue: 0.22)]
            }
        } else {
            switch step {
            case 0: return [Color(red: 0.92, green: 0.90, blue: 0.98), Color(red: 0.85, green: 0.82, blue: 0.95)]
            case 1: return [Color(red: 0.88, green: 0.93, blue: 0.98), Color(red: 0.82, green: 0.90, blue: 0.97)]
            case 2: return [Color(red: 0.88, green: 0.96, blue: 0.93), Color(red: 0.82, green: 0.94, blue: 0.90)]
            default: return [Color(red: 0.90, green: 0.96, blue: 0.90), Color(red: 0.84, green: 0.94, blue: 0.86)]
            }
        }
    }

    /// Foreground color that contrasts with the onboarding gradient
    private var onboardingPrimary: Color { theme.primaryText }
    private var onboardingSecondary: Color { theme.secondaryText }
    /// Subtle overlay for cards/chips on the gradient background
    private var overlayBg: Color { isDarkGradient ? Color.white : Color.black }

    var body: some View {
        ZStack {
            // Animated background
            LinearGradient(colors: gradientColors, startPoint: .topLeading, endPoint: .bottomTrailing)
                .animation(.easeInOut(duration: 0.6), value: step)
                .ignoresSafeArea()

            // Subtle noise texture overlay
            overlayBg.opacity(0.02)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                // Progress dots
                progressDots
                    .padding(.top, 28)

                // Step content with slide transition
                ZStack {
                    if step == 0 { welcomeStep.transition(stepTransition) }
                    if step == 1 { permissionsStep.transition(stepTransition) }
                    if step == 2 { aiSetupStep.transition(stepTransition) }
                    if step == 3 { readyStep.transition(stepTransition) }
                }
                .animation(.easeInOut(duration: 0.38), value: step)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                // Navigation
                navButtons
                    .padding(.bottom, 32)
                    .padding(.horizontal, 40)
            }
        }
        .frame(width: 580, height: 500)
        .interactiveDismissDisabled()
        .onAppear { startPermissionPolling() }
        .onDisappear { permissionTimer?.invalidate() }
    }

    private var stepTransition: AnyTransition {
        .asymmetric(
            insertion: .move(edge: .trailing).combined(with: .opacity),
            removal: .move(edge: .leading).combined(with: .opacity)
        )
    }

    // MARK: - Progress Dots

    private var progressDots: some View {
        HStack(spacing: 8) {
            ForEach(0..<totalSteps, id: \.self) { i in
                Capsule()
                    .fill(i == step ? onboardingPrimary : onboardingSecondary.opacity(0.4))
                    .frame(width: i == step ? 24 : 8, height: 8)
                    .animation(.spring(response: 0.35), value: step)
            }
        }
    }

    // MARK: - Step 0: Welcome

    private var welcomeStep: some View {
        VStack(spacing: 20) {
            Spacer()

            ZStack {
                Circle()
                    .fill(overlayBg.opacity(0.08))
                    .frame(width: 120, height: 120)
                Circle()
                    .fill(overlayBg.opacity(0.05))
                    .frame(width: 96, height: 96)
                ThemeAwareMenuIcon(size: 56)
            }

            VStack(spacing: 10) {
                Text("Welcome to FlowTrack")
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(onboardingPrimary)

                Text("Your intelligent Mac productivity tracker.\nUnderstands how you work and helps you do more of what matters.")
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(onboardingSecondary)
                    .lineSpacing(4)
            }

            Spacer()

            HStack(spacing: 24) {
                featurePill(icon: "brain", text: "AI Insights")
                featurePill(icon: "chart.bar", text: "Deep Stats")
                featurePill(icon: "shield.checkered", text: "Private")
            }

            Spacer()
        }
        .padding(.horizontal, 48)
    }

    private func featurePill(icon: String, text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.caption.bold())
            Text(text)
                .font(.caption.bold())
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(overlayBg.opacity(0.10))
        .clipShape(Capsule())
        .foregroundStyle(onboardingPrimary.opacity(0.85))
    }

    // MARK: - Step 1: Permissions

    private var permissionsStep: some View {
        VStack(spacing: 20) {
            Spacer()

            ZStack {
                Circle()
                    .fill(theme.infoColor.opacity(0.15))
                    .frame(width: 110, height: 110)
                Image(systemName: accessibilityGranted ? "lock.open.fill" : "lock.shield.fill")
                    .font(.system(size: 50))
                    .foregroundStyle(accessibilityGranted ? theme.successColor : onboardingPrimary)
                    .animation(.spring(response: 0.4), value: accessibilityGranted)
            }

            VStack(spacing: 10) {
                Text("Allow Accessibility Access")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(onboardingPrimary)
                Text("FlowTrack reads app names and window titles to understand your work. This data never leaves your Mac.")
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(onboardingSecondary)
                    .lineSpacing(4)
            }

            Spacer()

            if accessibilityGranted {
                Label("Accessibility access granted!", systemImage: "checkmark.circle.fill")
                    .font(.callout.bold())
                    .foregroundStyle(theme.successColor)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(theme.successColor.opacity(0.12))
                    .clipShape(Capsule())
                    .transition(.scale.combined(with: .opacity))
            } else {
                VStack(spacing: 10) {
                    Button {
                        PermissionChecker.requestAccessibility()
                    } label: {
                        Label("Grant Permission", systemImage: "hand.raised.fill")
                            .font(.callout.bold())
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(theme.accentColor)
                    .foregroundStyle(theme.selectedForeground)

                    Button("Open Accessibility Settings \u{2192}") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                    }
                    .font(.callout)
                    .foregroundStyle(onboardingSecondary)
                    .buttonStyle(.plain)

                    Text("Waiting for permission\u{2026} (the app will detect it automatically)")
                        .font(.caption)
                        .foregroundStyle(onboardingSecondary.opacity(0.7))
                }
            }

            Spacer()
        }
        .padding(.horizontal, 48)
    }

    // MARK: - Step 2: AI Setup

    private var aiSetupStep: some View {
        ScrollView {
            VStack(spacing: 20) {
                Spacer(minLength: 8)

                ZStack {
                    Circle()
                        .fill(Color.teal.opacity(0.18))
                        .frame(width: 90, height: 90)
                    Image(systemName: "brain.head.profile")
                        .font(.system(size: 42))
                        .foregroundStyle(Color.teal)
                }

                VStack(spacing: 8) {
                    Text("Set Up AI")
                        .font(.system(size: 26, weight: .bold))
                        .foregroundStyle(onboardingPrimary)
                    Text("AI categorizes your sessions and writes smart summaries. Choose your provider below \u{2014} or skip and set it up in Settings later.")
                        .font(.callout)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(onboardingSecondary)
                        .lineSpacing(3)
                }

                // Provider picker chips
                LazyVGrid(columns: [.init(.flexible()), .init(.flexible()), .init(.flexible())], spacing: 10) {
                    ForEach([AIProviderType.ollama, .claude, .openai, .gemini], id: \.self) { p in
                        providerChip(p)
                    }
                }

                // Config fields
                Group {
                    switch selectedProvider {
                    case .ollama:
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Ollama model (must be installed locally)")
                                .font(.caption)
                                .foregroundStyle(onboardingSecondary)
                            TextField("e.g. mistral, llama3.2", text: $ollamaModel)
                                .textFieldStyle(.plain)
                                .padding(10)
                                .background(overlayBg.opacity(0.08))
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .foregroundStyle(onboardingPrimary)
                            Text("Free & private. Install at ollama.ai, then run: ollama pull mistral")
                                .font(.caption2)
                                .foregroundStyle(onboardingSecondary.opacity(0.7))
                        }
                    case .claude, .openai, .gemini:
                        VStack(alignment: .leading, spacing: 6) {
                            Text("API Key")
                                .font(.caption)
                                .foregroundStyle(onboardingSecondary)
                            SecureField("Paste your \(selectedProvider.rawValue) API key", text: $apiKey)
                                .textFieldStyle(.plain)
                                .padding(10)
                                .background(overlayBg.opacity(0.08))
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .foregroundStyle(onboardingPrimary)
                        }
                    default:
                        EmptyView()
                    }
                }

                // Test button + result
                HStack(spacing: 12) {
                    Button {
                        Task { await testConnection() }
                    } label: {
                        if isTesting {
                            HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Testing\u{2026}") }
                        } else {
                            Label("Test Connection", systemImage: "bolt.fill")
                        }
                    }
                    .buttonStyle(.bordered)
                    .tint(theme.accentColor.opacity(0.5))
                    .foregroundStyle(onboardingPrimary)
                    .disabled(isTesting)

                    if let result = testResult {
                        Label(result, systemImage: testIsSuccess ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(testIsSuccess ? theme.successColor : theme.errorColor)
                    }
                }

                Spacer(minLength: 8)
            }
            .padding(.horizontal, 44)
        }
    }

    private func providerChip(_ provider: AIProviderType) -> some View {
        let selected = selectedProvider == provider
        return Button {
            selectedProvider = provider
            apiKey = SecureStore.shared.loadKey(for: provider.rawValue) ?? ""
            testResult = nil
        } label: {
            VStack(spacing: 4) {
                Image(systemName: providerIcon(provider))
                    .font(.title3)
                Text(providerShortName(provider))
                    .font(.caption.bold())
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(selected ? theme.accentColor.opacity(0.18) : overlayBg.opacity(0.06))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(selected ? theme.accentColor.opacity(0.50) : Color.clear, lineWidth: 1.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .foregroundStyle(selected ? onboardingPrimary : onboardingSecondary)
        }
        .buttonStyle(.plain)
    }

    private func providerIcon(_ p: AIProviderType) -> String {
        switch p {
        case .claude:  return "c.circle.fill"
        case .openai:  return "o.circle.fill"
        case .gemini:  return "g.circle.fill"
        case .ollama:  return "cpu.fill"
        default:       return "brain"
        }
    }

    private func providerShortName(_ p: AIProviderType) -> String {
        switch p {
        case .claude:  return "Claude"
        case .openai:  return "OpenAI"
        case .gemini:  return "Gemini"
        case .ollama:  return "Ollama"
        default:       return p.rawValue
        }
    }

    // MARK: - Step 3: Ready

    private var readyStep: some View {
        VStack(spacing: 20) {
            Spacer()

            ZStack {
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .fill(theme.successColor.opacity(0.06 + Double(i) * 0.04))
                        .frame(width: CGFloat(140 - i * 28), height: CGFloat(140 - i * 28))
                }
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(theme.successColor)
            }

            VStack(spacing: 10) {
                Text("You're all set!")
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(onboardingPrimary)
                Text("FlowTrack is now tracking your activity in the background. Check the menu bar icon anytime to see what you're working on.")
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(onboardingSecondary)
                    .lineSpacing(4)
            }

            Spacer()

            VStack(spacing: 10) {
                infoRow(icon: "menubar.rectangle", text: "Click the menu bar icon for a quick summary")
                infoRow(icon: "chart.bar.fill", text: "Open the dashboard for detailed analytics")
                infoRow(icon: "brain", text: "AI builds session summaries every 30 minutes")
            }

            Spacer()
        }
        .padding(.horizontal, 48)
    }

    private func infoRow(icon: String, text: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.body)
                .foregroundStyle(theme.successColor.opacity(0.80))
                .frame(width: 22)
            Text(text)
                .font(.callout)
                .foregroundStyle(onboardingSecondary)
            Spacer()
        }
    }

    // MARK: - Navigation

    private var navButtons: some View {
        HStack {
            if step > 0 {
                Button {
                    withAnimation { step = max(0, step - 1) }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                        Text("Back")
                    }
                    .foregroundStyle(onboardingSecondary)
                }
                .buttonStyle(.plain)
            }

            Spacer()

            if step == 2 {
                Button("Skip") {
                    withAnimation { step += 1 }
                }
                .foregroundStyle(onboardingSecondary.opacity(0.7))
                .buttonStyle(.plain)
                .padding(.trailing, 12)
            }

            if step < totalSteps - 1 {
                let canProgress = step != 1 || accessibilityGranted
                Button {
                    if step == 2 { saveAISettings() }
                    withAnimation { step += 1 }
                } label: {
                    HStack(spacing: 4) {
                        Text(step == 2 ? "Save & Continue" : "Continue")
                        Image(systemName: "chevron.right")
                    }
                    .font(.callout.bold())
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(canProgress ? theme.accentColor.opacity(0.22) : overlayBg.opacity(0.06))
                    .clipShape(Capsule())
                    .foregroundStyle(canProgress ? onboardingPrimary : onboardingSecondary.opacity(0.5))
                }
                .buttonStyle(.plain)
                .disabled(!canProgress)
            } else {
                Button {
                    AppSettings.shared.hasCompletedOnboarding = true
                    isPresented = false
                } label: {
                    Text("Open FlowTrack")
                        .font(.callout.bold())
                        .padding(.horizontal, 24)
                        .padding(.vertical, 10)
                        .background(theme.successColor.opacity(0.75))
                        .clipShape(Capsule())
                        .foregroundStyle(theme.selectedForeground)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Logic

    private func startPermissionPolling() {
        permissionTimer?.invalidate()
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            Task { @MainActor in
                let granted = AXIsProcessTrusted()
                withAnimation(.spring(response: 0.4)) {
                    accessibilityGranted = granted
                }
            }
        }
        RunLoop.main.add(permissionTimer!, forMode: .common)
    }

    private func saveAISettings() {
        AppSettings.shared.aiProvider = selectedProvider
        switch selectedProvider {
        case .ollama:
            AppSettings.shared.setModelName(ollamaModel, for: .ollama)
        case .claude, .openai, .gemini:
            if !apiKey.isEmpty {
                SecureStore.shared.save(key: apiKey, for: selectedProvider.rawValue)
            }
        default:
            break
        }
    }

    private func testConnection() async {
        isTesting = true
        testResult = nil
        saveAISettings()
        do {
            let provider = AIProviderFactory.create(for: selectedProvider)
            let healthy = try await provider.checkHealth()
            testIsSuccess = healthy
            testResult = healthy ? "Connected!" : "Provider unreachable"
        } catch {
            testIsSuccess = false
            testResult = "Failed: \(error.localizedDescription.prefix(50))"
        }
        isTesting = false
    }
}
