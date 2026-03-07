# FlowTrack

**AI-powered productivity tracker for macOS** — automatically monitors your app usage, categorizes activities, and delivers insights to help you stay focused.

<p align="center">
  <img src="https://img.shields.io/badge/platform-macOS%2014.6+-blue?logo=apple" />
  <img src="https://img.shields.io/badge/swift-6-orange?logo=swift" />
  <img src="https://img.shields.io/badge/UI-SwiftUI-blue?logo=swift" />
  <img src="https://img.shields.io/badge/database-GRDB%2FSQLite-green" />
</p>

FlowTrack lives in your menu bar, silently recording which apps you use, what browser tabs you visit, and how long you spend on each. It uses a combination of 308 built-in rules and AI providers (Claude, OpenAI, Gemini, Ollama, LM Studio) to categorize every activity as **Work** or **Distraction**, then presents your day as a rich timeline with statistics, heatmaps, and AI-generated summaries.

---

## Features

### Activity Tracking
- **Real-time app monitoring** — detects the frontmost app via `NSWorkspace` notifications with <100ms latency
- **Window title capture** — reads titles through the macOS Accessibility API (`AXUIElement`)
- **Browser URL extraction** — fetches URLs and tab titles from Safari, Chrome, Firefox, Arc, Brave, Edge, Opera, and more via AppleScript
- **Idle detection** — automatically pauses tracking after a configurable inactivity threshold (default: 2 minutes)
- **Screen sleep awareness** — handles lid close/open and display sleep transitions
- **5-minute checkpoint writes** — crash-resilient segment recording so no data is lost
- **App switch counter** — tracks daily context switches as a fragmentation metric

### Intelligent Categorization
- **308 built-in rules** — ships with rules covering domains (164), window titles (74), app names (66), and bundle IDs (4), split roughly 57% Work / 43% Distraction
- **Three-tier matching** — Custom rules → AI-learned rules → Default rules, evaluated in priority order
- **Browser protection** — browsers are always re-categorized per domain visit to prevent category poisoning
- **AI batch processing** — uncategorized activities are sent in 30-minute windows to your configured AI provider for classification

### AI Providers
Seven provider implementations with automatic fallback:

| Provider | Type | Default Model |
|----------|------|---------------|
| Claude API | Cloud | claude-sonnet-4-5-20250929 |
| OpenAI API | Cloud | gpt-4o-mini |
| Gemini API | Cloud | gemini-2.5-flash |
| Ollama | Local | llama3.2 |
| LM Studio | Local | configurable |
| Claude CLI | CLI | haiku/sonnet/opus |
| ChatGPT CLI | CLI | gpt-4.1-mini |

- **Fallback chain** — configure primary → secondary → tertiary providers; retries twice per level before falling back
- **Window analysis** — AI generates titles and summaries for 30-minute activity blocks
- **Multi-turn chat** — ask questions about your productivity with full activity context
- **URL sanitization** — only domain names are sent to AI; query parameters, tokens, and sensitive paths are stripped

### Analytics & Visualization
- **Timeline** — scrollable activity cards showing app, duration, category, and AI summaries
- **Statistics** — category pie chart, hourly breakdown grid, app usage rankings, daily totals
- **Heatmap** — 7-day grid colored by productivity intensity
- **Focus score** — percentage of active time spent on productive tasks
- **Focus streak** — consecutive days with ≥50% productivity
- **App switch metrics** — daily count displayed in the sidebar and menu bar

### Productivity Tools
- **Pomodoro timer** — configurable work/short break/long break cycles with lap recording
- **Countdown & stopwatch** — additional timer modes for flexible workflows
- **Task management** — full to-do list with priorities (Low/Medium/High), subtasks, due dates, and timer integration
- **Encrypted journal** — daily entries protected with AES-256 encryption and optional password
- **App blocker** — block distracting apps and websites with daily time limits and a local HTTP block page
- **Focus Mode** — real-time distraction detection engine with session tracking
- **Study Tracker** — optimized tracking for learning sessions
- **Achievements** — milestone badges for productivity streaks and goals

### UI & Themes
- **Menu bar app** — always-accessible popover with current stats, timer, and quick task creation
- **Dashboard window** — 8-tab interface (Timeline, Statistics, Heatmap, AI Chat, Tasks, Timer, Journal, Blocker)
- **5 themes** — System, Light, Dark, Pastel (purple-tinted), and Midnight (deep blue)
- **Onboarding flow** — guided first-run experience with permission setup
- **Dock icon toggle** — run as a pure menu bar app or show in the Dock

---

## Architecture

```
NSWorkspace notification → ActivityTracker (event-driven + 30s idle poll)
                             │
                             ├─ AXUIElement → window title
                             ├─ AppleScript → browser URL + tab title
                             └─ CGEventSource → idle detection
                                    │
                                    ▼
                           RuleEngine (308 rules)
                             │ matched → category assigned
                             │ unmatched ↓
                           AI Provider (batch, fallback chain)
                                    │
                                    ▼
                           Database (GRDB/SQLite)
                             │ activities table (raw records)
                             │ window_segments table (30-min AI blocks)
                                    │
                                    ▼
                           AppState (@Observable, 30s refresh)
                                    │
                                    ▼
                           SwiftUI views (timeline, stats, heatmap, ...)
```

### Key Subsystems

| Subsystem | Description |
|-----------|-------------|
| **ActivityTracker** | Hybrid event/poll engine — app switches via `NSWorkspace`, title changes via `AXObserver`, idle via `CGEventSource`, browser URLs via AppleScript |
| **RuleEngine** | Three-tier pattern matching (custom → learned → default) with bundle ID caching and browser-aware domain matching |
| **AI Providers** | Protocol-based with factory pattern; 7 implementations, 3-level fallback, batch + streaming support |
| **Database** | GRDB/SQLite with 8 migrations; session building via idle-gap splitting → category-change splitting → same-category merging |
| **AppState** | Central `@Observable` singleton; all views observe it; refreshes on a 30-second timer |

### Session Building Pipeline
1. **Split on idle gaps** — any gap >5 minutes creates a new session
2. **Split on category changes** — sustained category runs (≥60s) break sessions
3. **Merge adjacent same-category** — consecutive same-category sessions within 10 minutes are combined

---

## Project Layout

```
FlowTrack/
├── FlowTrackApp.swift                # App entry: MenuBarExtra + Dashboard + Settings scenes
├── AppState.swift                    # @Observable singleton, central UI state
├── ContentView.swift
│
├── Storage/                          # Data layer
│   ├── Database.swift                # GRDB schema, migrations, queries
│   ├── Models.swift                  # ActivityRecord, Category, AppSettings, Rule, etc.
│   ├── SecureStore.swift             # Keychain-backed API key storage
│   ├── CategoryManager.swift         # Dynamic category definitions (JSON)
│   ├── TodoStore.swift               # Task persistence
│   ├── TimerStore.swift              # Pomodoro/timer state
│   ├── JournalStore.swift            # Journal entries
│   ├── JournalCrypto.swift           # AES-256 encryption
│   ├── JournalPasswordManager.swift  # Password management
│   ├── AppBlockerStore.swift         # Blocker state
│   ├── AppBlockerMonitor.swift       # Blocker enforcement
│   ├── BlockPageServer.swift         # Local HTTP block page server
│   ├── BackupManager.swift           # Data backup/export
│   └── CloudFolderDetector.swift     # Cloud storage detection
│
├── Tracking/                         # Activity tracking
│   ├── ActivityTracker.swift         # Main tracking engine
│   └── PermissionChecker.swift       # Accessibility permission checks
│
├── Intelligence/                     # AI & categorization
│   ├── AIProvider.swift              # Protocol + factory + fallback chain
│   ├── RuleEngine.swift              # Rule matching engine (308 rules)
│   ├── ContentMetadataExtractor.swift
│   ├── ContentAIClassifier.swift
│   ├── ChatEngine.swift              # Multi-turn AI conversation
│   ├── AchievementEngine.swift
│   ├── FocusModeEngine.swift
│   ├── StudyTrackerEngine.swift
│   └── Providers/                    # AI provider implementations
│       ├── ClaudeProvider.swift
│       ├── OpenAIProvider.swift
│       ├── GeminiProvider.swift
│       ├── OllamaProvider.swift
│       ├── LMStudioProvider.swift
│       └── CLIProvider.swift
│
├── UI/                               # SwiftUI views
│   ├── DashboardView.swift           # Main tabbed interface + sidebar
│   ├── MenuBarView.swift             # Menu bar popover
│   ├── TimelineView.swift            # Activity timeline
│   ├── StatsView.swift               # Statistics & analytics
│   ├── HeatmapView.swift             # Weekly heatmap
│   ├── ChatView.swift                # AI chat interface
│   ├── TodoView.swift                # Task management
│   ├── TimerView.swift               # Pomodoro/timer
│   ├── JournalView.swift             # Encrypted journal
│   ├── AppBlockerView.swift          # App/site blocker
│   ├── SettingsView.swift            # Configuration (8+ sections)
│   ├── SyncSettingsView.swift        # Cloud sync settings
│   ├── OnboardingView.swift          # First-run experience
│   ├── SessionDetailView.swift       # Session detail panel
│   ├── AchievementsView.swift        # Achievement display
│   ├── Theme.swift                   # 5 themes, colors, formatting helpers
│   └── AppIconProvider.swift         # App icon utilities
│
└── Resources/
    └── DefaultRules.json             # 308 categorization rules
```

**50 Swift files · ~19,500 lines of code**

---

## Tech Stack

| Component | Technology |
|-----------|-----------|
| Language | Swift 6 (strict concurrency, `@MainActor` default isolation) |
| UI | SwiftUI with `NavigationSplitView`, `MenuBarExtra` |
| Database | [GRDB](https://github.com/groue/GRDB.swift) 7.10 (SQLite) |
| Secrets | [KeychainSwift](https://github.com/evgenyneu/keychain-swift) 24.0 (macOS Keychain) |
| Networking | Native `URLSession` (no third-party HTTP libraries) |
| Platform | macOS 14.6+ (Sonoma) |
| Concurrency | Swift 6 strict concurrency with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` |

---

## Build & Run

### Requirements
- macOS 14.6 or later
- Xcode 16+ with Swift 6 toolchain
- SPM dependencies resolve automatically on first build

### Commands

```bash
# Build
xcodebuild -project FlowTrack.xcodeproj -scheme FlowTrack -configuration Debug build

# Run tests
xcodebuild -project FlowTrack.xcodeproj -scheme FlowTrack -configuration Debug test

# Clean
xcodebuild -project FlowTrack.xcodeproj -scheme FlowTrack clean
```

Or open `FlowTrack.xcodeproj` in Xcode and press **⌘+R**.

### Permissions
On first launch, FlowTrack will request:
1. **Accessibility** — needed to read window titles and detect app switches
2. **Automation (Apple Events)** — needed to fetch browser URLs via AppleScript

---

## Configuration

### AI Providers
Open **Settings → AI** to configure:
- **Primary / Secondary / Tertiary provider** — select from the 7 available providers
- **API keys** — stored securely in the macOS Keychain
- **Model selection** — each provider offers suggested models
- **Health check** — test provider connectivity
- **Batch settings** — interval (default: 30 min) and batch size (default: 30 windows)

### Themes
Five visual themes available in **Settings → Display**:

| Theme | Style |
|-------|-------|
| System | Follows macOS light/dark mode |
| Light | Bright white background |
| Dark | Dark gray tones |
| Pastel | Purple-tinted, soft colors |
| Midnight | Deep blue-purple, low light |

### Tracking
- **Idle threshold** — seconds of inactivity before marking idle (default: 120s)
- **Window title capture** — toggle on/off
- **Excluded apps** — bundle IDs to ignore
- **Data retention** — auto-delete records older than N days (default: 90)
- **Distraction alerts** — notify after N minutes on distraction apps

---

## Security & Privacy

FlowTrack is designed as a **local-first** application:

- **All data stays on your Mac** — activity records are stored in a local SQLite database at `~/Library/Application Support/FlowTrack/`
- **API keys in Keychain** — stored as a single JSON blob in the macOS Keychain with `.accessibleWhenUnlockedThisDeviceOnly` protection (no iCloud sync)
- **Journal encryption** — entries are encrypted with AES-256; optional password adds an extra layer
- **URL sanitization** — only domain names are sent to AI providers; query parameters, auth tokens, and sensitive paths are stripped before any API call
- **No telemetry** — FlowTrack does not phone home, collect analytics, or send data anywhere except your configured AI provider
- **Minimal permissions** — only Accessibility (window titles) and Automation (browser URLs)

---

## Release

Create a DMG and publish to GitHub Releases:

```bash
./release.sh [VERSION] [--notes "release notes"]

# Examples
./release.sh 1.2                         # Uses default notes
./release.sh 1.3 --notes "Added heatmap"  # Custom release notes
```

The script:
1. Archives with ad-hoc signing (no notarization)
2. Exports a standalone `.app` bundle
3. Creates a compressed DMG with an Applications symlink
4. Creates a GitHub release tag and uploads the DMG

Output: `FlowTrack-v{VERSION}.dmg`

---

## Contributing

### Code Conventions
- **Swift 6 strict concurrency** — all types default to `@MainActor`; mark cross-actor types as `@unchecked Sendable`
- **Use `nonisolated`** when implementing `Sendable` protocol requirements
- **`import Foundation` explicitly** in files using `TimeInterval` (not auto-imported with `CoreGraphics`)
- **Database records** — use `record.inserted(db)` (returns new record) instead of `var r = record; r.insert(db)`
- **Xcode auto-discovery** — the project uses `PBXFileSystemSynchronizedRootGroup`, so new files added to disk appear in Xcode automatically

### Testing
```bash
# Run the test suite (Swift Testing framework)
xcodebuild -project FlowTrack.xcodeproj -scheme FlowTrack -configuration Debug test
```

---

## License

All rights reserved. This is proprietary software.
