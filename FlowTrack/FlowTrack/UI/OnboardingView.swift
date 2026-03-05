import SwiftUI

struct OnboardingView: View {
    @State private var step = 0
    @Binding var isPresented: Bool

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            switch step {
            case 0:
                welcomeStep
            case 1:
                permissionsStep
            default:
                readyStep
            }

            Spacer()

            HStack {
                if step > 0 {
                    Button("Back") { step -= 1 }
                        .buttonStyle(.bordered)
                }
                Spacer()
                if step < 2 {
                    Button("Next") { step += 1 }
                        .buttonStyle(.borderedProminent)
                } else {
                    Button("Get Started") {
                        AppSettings.shared.hasCompletedOnboarding = true
                        isPresented = false
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(40)
        .frame(width: 500, height: 400)
    }

    private var welcomeStep: some View {
        VStack(spacing: 16) {
            Image(systemName: "bolt.fill")
                .font(.system(size: 60))
                .foregroundStyle(.blue)
            Text("Welcome to FlowTrack")
                .font(.title.bold())
            Text("FlowTrack runs in your menu bar and automatically tracks how you spend time on your Mac.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
    }

    private var permissionsStep: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.shield")
                .font(.system(size: 60))
                .foregroundStyle(.orange)
            Text("Accessibility Permission")
                .font(.title.bold())
            Text("FlowTrack needs Accessibility permission to read window titles and track which apps you're using.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            Button("Grant Permission") {
                PermissionChecker.requestAccessibility()
            }
            .buttonStyle(.borderedProminent)

            if PermissionChecker.hasAccessibility {
                Label("Permission Granted", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
        }
    }

    private var readyStep: some View {
        VStack(spacing: 16) {
            Image(systemName: "sparkles")
                .font(.system(size: 60))
                .foregroundStyle(.purple)
            Text("You're All Set!")
                .font(.title.bold())
            Text("FlowTrack will now track your activities and AI will categorize and summarize your work sessions automatically.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
    }
}
