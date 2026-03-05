# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Run

This is a macOS Xcode project (no Makefile/SPM CLI). Build and run from Xcode or via command line:

```bash
# Build
xcodebuild -project FlowTrack/FlowTrack.xcodeproj -scheme FlowTrack -configuration Debug build

# Run tests (Swift Testing framework, not XCTest)
xcodebuild -project FlowTrack/FlowTrack.xcodeproj -scheme FlowTrack -configuration Debug test

# Clean build
xcodebuild -project FlowTrack/FlowTrack.xcodeproj -scheme FlowTrack clean
```

Deployment target: macOS 14.6. SPM dependencies (GRDB, KeychainSwift) resolve automatically.

## Swift 6 Concurrency Configuration

The project uses **Swift 6 strict concurrency** with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`. This means:

- **All types are `@MainActor` by default** — no need to annotate most types
- Files using `TimeInterval` need `import Foundation` explicitly (not auto-imported with just `CoreGraphics`)
- Types needing cross-actor use are marked `@unchecked Sendable` (Database, RuleEngine, CategoryManager)
- Use `nonisolated` when implementing `Sendable` protocol requirements or when code must run off the main actor

## Architecture

**App entry point:** `FlowTrackApp.swift` — MenuBarExtra (menu bar app) + Window scenes for dashboard/onboarding.

**Central state:** `AppState.swift` — `@Observable` singleton holding all UI state, refreshes on a 30s timer. All views observe this.

### Data Flow

```
ActivityTracker (5s poll) → Database (GRDB/SQLite) → AppState (30s refresh) → SwiftUI views
                          → RuleEngine (pattern match) → category assigned
                          → AI providers (batch, for uncategorized) → category/title/summary
```

### Key Subsystems

**Tracking** — `ActivityTracker` polls the frontmost app via `NSWorkspace`, reads window titles via Accessibility API (`AXUIElement`), and extracts browser URLs via AppleScript. Adaptive polling: 5s active, 10s on battery, 15s when idle (30s idle threshold via `CGEventSource`).

**Categorization** — Two-tier: `RuleEngine` matches app names/URLs against 122 built-in rules (`DefaultRules.json`) + custom rules. Unmatched items go to AI batch processing.

**AI Providers** — `AIProvider` protocol with 7 implementations (Claude/OpenAI/Gemini APIs, Ollama/LM Studio local, Claude CLI/ChatGPT CLI). Fallback chain: primary → secondary → tertiary, 2 retries each. Factory pattern via `AIProviderFactory`.

**Storage** — GRDB with 2 tables: `activities` (timestamped app records) and `session_ai` (AI-generated titles/summaries). `SecureStore` saves API keys to a file with 0o600 permissions. `CategoryManager` persists categories to JSON.

### Database Conventions

- Use `record.inserted(db)` (returns new record) instead of `var r = record; r.insert(db)` to avoid "never mutated" warnings
- Migrations are in `Database.swift` `migrate()` method
- Sessions are grouped from activity records with a 5-minute gap threshold

## Project Layout

All Swift sources live under `FlowTrack/FlowTrack/`:

| Directory | Purpose |
|-----------|---------|
| `Storage/` | Models (GRDB records), Database, SecureStore, CategoryManager |
| `Tracking/` | ActivityTracker (polling + AX API), PermissionChecker |
| `Intelligence/` | AIProvider protocol, RuleEngine, 6 provider implementations in `Providers/` |
| `UI/` | All SwiftUI views, Theme system (5 themes), reusable components |
| `Resources/` | `DefaultRules.json` (122 rules), asset catalog |

The Xcode project uses `PBXFileSystemSynchronizedRootGroup` — new files added to disk are auto-discovered without manual project file edits.

## UI Structure

`NavigationSplitView` with sidebar (Timeline/Statistics/Heatmap tabs) + detail pane. `MenuBarView` provides quick access from the menu bar. Settings is a sheet with 8+ sections. Dashboard is the main window scene.

## Settings System

`AppSettings` is `@Observable` and backed by `UserDefaults`. It holds AI provider config (primary/secondary/tertiary fallback), theme, polling preferences, and model names per provider.
