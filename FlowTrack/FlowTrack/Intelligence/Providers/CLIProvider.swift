@preconcurrency import Foundation

struct CLIProvider: AIProvider, Sendable {
    let command: String
    let model: String

    func categorize(appName: String, bundleID: String, windowTitle: String, url: String?) async throws -> Category {
        let prompt = AIPromptBuilder.categorizationPrompt(appName: appName, bundleID: bundleID, windowTitle: windowTitle, url: url)
        let text = try await runCLI(prompt: prompt)
        guard let cat = AIPromptBuilder.parseCategory(text) else {
            throw AIError.invalidResponse("Could not parse: \(text)")
        }
        return cat
    }

    func generateTitle(activities: [ActivitySummary], category: Category) async throws -> String {
        let prompt = AIPromptBuilder.titlePrompt(activities: activities, category: category)
        return try await runCLI(prompt: prompt).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func summarize(activities: [ActivitySummary]) async throws -> String {
        let prompt = AIPromptBuilder.summaryPrompt(activities: activities)
        return try await runCLI(prompt: prompt).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func chat(messages: [ChatTurn], systemPrompt: String) async throws -> String {
        // Flatten conversation + system context into a single prompt for CLI tools
        var parts: [String] = [systemPrompt, "---"]
        for turn in messages.suffix(10) {  // only last 10 turns for CLI (token-safe)
            let prefix = turn.role == "user" ? "User" : "Assistant"
            parts.append("\(prefix): \(turn.content)")
        }
        parts.append("Assistant:")
        return try await runCLI(prompt: parts.joined(separator: "\n\n"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func checkHealth() async throws -> Bool {
        guard findCLIPath() != nil else {
            throw AIError.cliNotFound(command)
        }
        return true
    }

    static func detectCLI(command: String) -> String? {
        let provider = CLIProvider(command: command, model: "")
        return provider.findCLIPath()
    }

    private func findCLIPath() -> String? {
        let commonPaths: [String]
        if command == "claude" {
            commonPaths = [
                "\(NSHomeDirectory())/.local/bin/claude",
                "/usr/local/bin/claude",
                "/opt/homebrew/bin/claude",
            ]
        } else {
            commonPaths = [
                "/usr/local/bin/codex",
                "/opt/homebrew/bin/codex",
                "\(NSHomeDirectory())/.local/bin/codex",
            ]
        }
        for path in commonPaths {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        // Try `which`
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = [command]
        process.environment = buildEnvironment()
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try? process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return path.isEmpty ? nil : path
    }

    private func buildEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let extraPaths = [
            "/usr/local/bin",
            "/opt/homebrew/bin",
            "\(NSHomeDirectory())/.local/bin",
            "\(NSHomeDirectory())/.nvm/versions/node/*/bin",
            "/usr/bin",
        ]
        let currentPath = env["PATH"] ?? "/usr/bin:/bin"
        env["PATH"] = (extraPaths + [currentPath]).joined(separator: ":")
        return env
    }

    private func runCLI(prompt: String) async throws -> String {
        guard let cliPath = findCLIPath() else {
            throw AIError.cliNotFound(command)
        }

        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: cliPath)
            process.environment = buildEnvironment()

            // Use stdin to pass prompt — avoids exposing user data in `ps` output
            let stdinPipe = Pipe()
            process.standardInput = stdinPipe

            if command == "claude" {
                process.arguments = ["--model", model, "--output-format", "text"]
            } else {
                process.arguments = ["--model", model]
            }

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: AIError.cliError("Failed to start \(command): \(error.localizedDescription)"))
                return
            }

            // Write prompt to stdin and close to signal EOF
            if let data = prompt.data(using: .utf8) {
                stdinPipe.fileHandleForWriting.write(data)
            }
            stdinPipe.fileHandleForWriting.closeFile()

            // Use terminationHandler to avoid blocking a cooperative thread pool thread.
            // waitUntilExit() would block for up to 30s — terminationHandler is event-driven.
            // Timeout is detected via proc.terminationReason == .uncaughtSignal (SIGTERM we sent).
            let commandName = command
            let timeoutItem = DispatchWorkItem {
                if process.isRunning { process.terminate() }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 30, execute: timeoutItem)

            process.terminationHandler = { proc in
                timeoutItem.cancel()
                let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                let stdout = String(data: stdoutData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let stderr = String(data: stderrData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

                if proc.terminationReason == .uncaughtSignal {
                    continuation.resume(throwing: AIError.cliError("\(commandName) timed out after 30s"))
                    return
                }
                if proc.terminationStatus != 0 {
                    let errorMsg = !stderr.isEmpty ? stderr : (!stdout.isEmpty ? stdout : "CLI exited with code \(proc.terminationStatus)")
                    continuation.resume(throwing: AIError.cliError(errorMsg))
                    return
                }
                if stdout.isEmpty {
                    continuation.resume(throwing: AIError.invalidResponse("Empty CLI response"))
                    return
                }
                continuation.resume(returning: stdout)
            }
        }
    }
}