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

    // Gradient colors per step
    private var gradientColors: [Color] {
        switch step {
        case 0: return [Color(red: 0.10, green: 0.08, blue: 0.20), Color(red: 0.18, green: 0.14, blue: 0.40)]
        case 1: return [Color(red: 0.08, green: 0.16, blue: 0.28), Color(red: 0.12, green: 0.28, blue: 0.42)]
        case 2: return [Color(red: 0.08, green: 0.20, blue: 0.18), Color(red: 0.12, green: 0.32, blue: 0.26)]
        default: return [Color(red: 0.12, green: 0.20, blue: 0.14), Color(red: 0.18, green: 0.36, blue: 0.22)]
        }
    }

    var body: some View {
        ZStack {
            // Animated background
            LinearGradient(colors: gradientColors, startPoint: .topLeading, endPoint: .bottomTrailing)
                .animation(.easeInOut(duration: 0.6), value: step)
                .ignoresSafeArea()

            // Subtle noise texture overlay
            Color.white.opacity(0.02)
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
                    .fill(i == step ? Color.white : Color.white.opacity(0.25))
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
                    .fill(Color.white.opacity(0.08))
                    .frame(width: 120, height: 120)
                Circle()
                    .fill(Color.white.opacity(0.05))
                    .frame(width: 96, height: 96)
                ThemeAwareMenuIcon(size: 56)
            }

            VStack(spacing: 10) {
                Text("Welcome to FlowTrack")
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(.white)

                Text("Your intelligent Mac productivity tracker.\nUnderstands how you work and helps you do more of what matters.")
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Color.white.opacity(0.70))
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
        .background(Color.white.opacity(0.10))
        .clipShape(Capsule())
        .foregroundStyle(Color.white.opacity(0.85))
    }

    // MARK: - Step 1: Permissions

    private var permissionsStep: some View {
        VStack(spacing: 20) {
            Spacer()

            ZStack {
                Circle()
                    .fill(Color.blue.opacity(0.15))
                    .frame(width: 110, height: 110)
                Image(systemName: accessibilityGranted ? "lock.open.fill" : "lock.shield.fill")
                    .font(.system(size: 50))
                    .foregroundStyle(accessibilityGranted ? Color.green : Color.white)
                    .animation(.spring(response: 0.4), value: accessibilityGranted)
            }

            VStack(spacing: 10) {
                Text("Allow Accessibility Access")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(.white)
                Text("FlowTrack reads app names and window titles to understand your work. This data never leaves your Mac.")
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Color.white.opacity(0.70))
                    .lineSpacing(4)
            }

            Spacer()

            if accessibilityGranted {
                Label("Accessibility access granted!", systemImage: "checkmark.circle.fill")
                    .font(.callout.bold())
                    .foregroundStyle(.green)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(Color.green.opacity(0.12))
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
                    .tint(Color.white.opacity(0.20))
                    .foregroundStyle(.white)

                    Button("Open Accessibility Settings →") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                    }
                    .font(.callout)
                    .foregroundStyle(Color.white.opacity(0.60))
                    .buttonStyle(.plain)

                    Text("Waiting for permission… (the app will detect it automatically)")
                        .font(.caption)
                        .foregroundStyle(Color.white.opacity(0.40))
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
                        .foregroundStyle(.white)
                    Text("AI categorizes your sessions and writes smart summaries. Choose your provider below — or skip and set it up in Settings later.")
                        .font(.callout)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(Color.white.opacity(0.65))
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
                                .foregroundStyle(Color.white.opacity(0.55))
                            TextField("e.g. mistral, llama3.2", text: $ollamaModel)
                                .textFieldStyle(.plain)
                                .padding(10)
                                .background(Color.white.opacity(0.08))
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .foregroundStyle(.white)
                            Text("Free & private. Install at ollama.ai, then run: ollama pull mistral")
                                .font(.caption2)
                                .foregroundStyle(Color.white.opacity(0.40))
                        }
                    case .claude, .openai, .gemini:
                        VStack(alignment: .leading, spacing: 6) {
                            Text("API Key")
                                .font(.caption)
                                .foregroundStyle(Color.white.opacity(0.55))
                            SecureField("Paste your \(selectedProvider.rawValue) API key", text: $apiKey)
                                .textFieldStyle(.plain)
                                .padding(10)
                                .background(Color.white.opacity(0.08))
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .foregroundStyle(.white)
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
                            HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Testing…") }
                        } else {
                            Label("Test Connection", systemImage: "bolt.fill")
                        }
                    }
                    .buttonStyle(.bordered)
                    .tint(Color.white.opacity(0.25))
                    .foregroundStyle(.white)
                    .disabled(isTesting)

                    if let result = testResult {
                        Label(result, systemImage: testIsSuccess ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(testIsSuccess ? Color.green : Color.red)
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
            .background(selected ? Color.white.opacity(0.18) : Color.white.opacity(0.06))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(selected ? Color.white.opacity(0.50) : Color.clear, lineWidth: 1.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .foregroundStyle(selected ? .white : Color.white.opacity(0.55))
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
                        .fill(Color.green.opacity(0.06 + Double(i) * 0.04))
                        .frame(width: CGFloat(140 - i * 28), height: CGFloat(140 - i * 28))
                }
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(Color.green)
            }

            VStack(spacing: 10) {
                Text("You're all set!")
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(.white)
                Text("FlowTrack is now tracking your activity in the background. Check the menu bar icon anytime to see what you're working on.")
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Color.white.opacity(0.70))
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
                .foregroundStyle(Color.green.opacity(0.80))
                .frame(width: 22)
            Text(text)
                .font(.callout)
                .foregroundStyle(Color.white.opacity(0.70))
            Spacer()
        }
    }

    // MARK: - Navigation

    private var navButtons: some View {
        HStack {
            if step > 0 {
                Button {
                    withAnimation { step -= 1 }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                        Text("Back")
                    }
                    .foregroundStyle(Color.white.opacity(0.55))
                }
                .buttonStyle(.plain)
            }

            Spacer()

            if step == 2 {
                Button("Skip") {
                    withAnimation { step += 1 }
                }
                .foregroundStyle(Color.white.opacity(0.40))
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
                    .background(canProgress ? Color.white.opacity(0.18) : Color.white.opacity(0.06))
                    .clipShape(Capsule())
                    .foregroundStyle(canProgress ? .white : Color.white.opacity(0.30))
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
                        .background(Color.green.opacity(0.75))
                        .clipShape(Capsule())
                        .foregroundStyle(.white)
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
