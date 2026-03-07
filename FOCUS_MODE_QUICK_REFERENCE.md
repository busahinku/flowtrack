# FlowTrack Focus Mode - Quick Hookpoints Reference

## 🎯 PRIMARY DISTRACTION DETECTION HOOK

**Location:** `/Users/buraksahinkucuk/Desktop/CODING/startup/flowtrack/FlowTrack/Tracking/ActivityTracker.swift`

### Hook #1: App Switch (BEST - Lowest Latency)
```
Lines 280-345: handleAppSwitch()

CATEGORY DETERMINED AT:
  • Line 334 (browser): cat = resolveCategory(..., url: info.url, ...)
  • Line 341 (native):  cat = resolveCategory(..., url: nil, ...)

AFTER CATEGORY RESOLVED, INSERT HERE:
  Line 335 (after browser cat resolved):
    ✨ YOUR FOCUS MODE CODE ✨
    
  Line 342 (after native cat resolved):
    ✨ YOUR FOCUS MODE CODE ✨

AVAILABLE CONTEXT AT THIS POINT:
  ✓ appName (e.g., "Safari", "Xcode")
  ✓ bundleID (e.g., "com.apple.Safari")
  ✓ title (window title)
  ✓ url (for browsers)
  ✓ category (resolved: .distraction, .work, .idle, .uncategorized)
  ✓ isTracking, isScreenAsleep, isCurrentlyIdle states
```

### Hook #2: Category Resolver (Core Logic)
```
Line 526-529: resolveCategory()

private func resolveCategory(
    appName: String, 
    bundleID: String, 
    title: String, 
    url: String?, 
    isIdle: Bool, 
    contentMetadata: ContentMetadata? = nil
) -> Category

Returns: .distraction | .work | .idle | .uncategorized

CALLS:
  RuleEngine.shared.categorize(...)
    • Checks BundleID rules
    • Checks URL domain rules  
    • Checks ContentMetadata AI tags
    • Returns .distraction if user is on Reddit/YouTube/Twitter
```

### Hook #3: Existing Distraction Alert (Reference)
```
Line 772-814: checkDistractionAlert()

LOGIC:
  if category == .distraction {
    if (elapsed >= alertMinutes * 60 && can_fire_notification) {
      fireDistractionNotification(minutes: alertMinutes)
    }
  }

PRIVATE STATE:
  Line 74: private var distractionStartTime: Date?
  Line 75: private var distractionPausedAt: Date?
  Line 76: private var lastDistractionAlertFired: Date?

YOUR CODE CAN:
  ✓ Monitor distractionStartTime to track elapsed
  ✓ Fire notifications alongside existing system
  ✓ Check if user is in "grace period" (distractionPausedAt != nil)
```

### Hook #4: Segment Recording (For Analytics)
```
Line 531-579: writeRecord()

CALLED WHEN:
  • Checkpoint timer fires (every 5 min)
  • Segment ends (user switches app)
  • At tracker shutdown

PARAMETERS AT THIS POINT:
  appName, bundleID, title, url, category, duration, isIdle

CATEGORY IS ALREADY FINAL HERE - use for post-analysis
```

---

## 🎨 SIDEBAR UI INTEGRATION

**File:** `/Users/buraksahinkucuk/Desktop/CODING/startup/flowtrack/FlowTrack/UI/DashboardView.swift`

### Current Sidebar Structure:
```
┌─ SidebarView ─────────────────────────────────┐
│                                               │
│  ┌─ Section("Status") ─────────────────────┐  │  Lines 90-113
│  │ • Tracking/Paused indicator (green/red) │  │
│  │ • Current app name                      │  │
│  └─────────────────────────────────────────┘  │
│                                               │
│  ┌─ Section("Today") ──────────────────────┐  │  Lines 115-130
│  │ ◯ Focus Ring (46x46, animated)    │  │  │
│  │ │ Distraction: 45m                 │  │  │
│  │ │ Active: 2h 30m                   │  │  │
│  │ │ Timer: 50m                       │  │  │
│  └─────────────────────────────────────────┘  │
│                                               │
│  ┌─ Section("Views") ──────────────────────┐  │  Lines 132-139
│  │ • Timeline                              │  │
│  │ • Statistics                            │  │
│  │ • Heatmap                               │  │
│  │ • AI Chat                               │  │
│  │ • Tasks / Timer / Journal / Blocker     │  │
│  └─────────────────────────────────────────┘  │
│                                               │
│  ┌─ Bottom Bar ──────────────────────────┐    │  Lines 165-198
│  │ ✨ AI Processing... | ⚙️ Settings    │    │
│  └──────────────────────────────────────┘    │
└───────────────────────────────────────────────┘
```

### Where to Add Focus Mode Button:

**Option A: New Section After Status** (Recommended)
```swift
private var focusModeSection: some View {
    Section("Focus Mode") {
        Button(action: toggleFocusMode) {
            HStack {
                Image(systemName: focusModeActive ? "target.fill" : "target")
                Text(focusModeActive ? "Focus Active" : "Start Focus")
                Spacer()
                if focusModeActive {
                    Text(focusModeDuration)
                        .font(.caption2)
                        .foregroundStyle(theme.secondaryText)
                }
            }
        }
        .foregroundStyle(focusModeActive ? theme.successColor : theme.primaryText)
        .listRowSeparator(.hidden)
        .selectionDisabled()
    }
}

// Add in body after statusSection:
statusSection
focusModeSection  // ← NEW
todaySection
```

**Option B: Inline with Focus Ring** (Less invasive)
```swift
// Line 118 - modify existing Today section:
HStack(spacing: 12) {
    // Existing focus ring
    focusRing
    
    // NEW: Toggle button
    Button(action: toggleFocusMode) {
        Image(systemName: "target.fill")
            .foregroundStyle(focusModeActive ? theme.successColor : theme.secondaryText)
    }
    .buttonStyle(.plain)
    
    // Existing stats
    VStack(alignment: .leading, spacing: 4) {
        statRow("Distraction", distractionTime)
        statRow("Active", totalActiveTime)
        statRow("Timer", todayTrackedTime)
    }
    Spacer()
}
```

### Sidebar Styling Reference:
```
COLORS:
  • Active: theme.successColor (green)
  • Inactive: theme.secondaryText
  • Text: theme.primaryText

SPACING:
  • Section horizontal padding: 14pt
  • Section vertical padding: 8pt (between items)
  • HStack spacing: 12-14pt

FONT:
  • Main label: .subheadline
  • Secondary: .caption2 or .caption
  • Number: .system(size: 13, weight: .semibold, design: .rounded)

CORNERS:
  • Not used in sidebar (system defaults)
  • Use 8pt if you add cards

SHADOWS:
  • None in sidebar (use .material background if needed)
```

---

## ⚙️ SETTINGS INTEGRATION

**File:** `/Users/buraksahinkucuk/Desktop/CODING/startup/flowtrack/FlowTrack/Storage/Models.swift` (Lines 318-439)

### Add to AppSettings class:

```swift
final class AppSettings {
    // ... existing code ...
    
    // NEW: Focus Mode Settings
    var focusModeEnabled: Bool {
        didSet { UserDefaults.standard.set(focusModeEnabled, forKey: "focusModeEnabled") }
    }
    
    var focusModeNotificationLevel: String {  // "aggressive" | "balanced" | "gentle"
        didSet { UserDefaults.standard.set(focusModeNotificationLevel, forKey: "focusModeNotificationLevel") }
    }
    
    var focusModeBreakFrequency: Int {  // minutes between suggestions
        didSet { UserDefaults.standard.set(focusModeBreakFrequency, forKey: "focusModeBreakFrequency") }
    }
    
    // In init():
    self.focusModeEnabled = defaults.object(forKey: "focusModeEnabled") as? Bool ?? false
    self.focusModeNotificationLevel = defaults.string(forKey: "focusModeNotificationLevel") ?? "balanced"
    self.focusModeBreakFrequency = defaults.object(forKey: "focusModeBreakFrequency") as? Int ?? 5
}
```

---

## 📊 STATE MANAGEMENT

**File:** `/Users/buraksahinkucuk/Desktop/CODING/startup/flowtrack/FlowTrack/AppState.swift`

### Add to AppState class:

```swift
@Observable
final class AppState {
    // ... existing code ...
    
    // NEW: Focus Mode Runtime State
    var focusModeActive: Bool = false
    var focusModeStartedAt: Date?
    var focusModeDistractionCount: Int = 0
    var focusModeLastDistractionApp: String?
    var focusModeSessionDuration: TimeInterval { 
        if let start = focusModeStartedAt {
            return Date().timeIntervalSince(start)
        }
        return 0
    }
    
    func startFocusMode() {
        focusModeActive = true
        focusModeStartedAt = Date()
        focusModeDistractionCount = 0
        focusModeLastDistractionApp = nil
    }
    
    func endFocusMode() -> (duration: TimeInterval, distractionCount: Int) {
        focusModeActive = false
        return (focusModeSessionDuration, focusModeDistractionCount)
    }
    
    func recordFocusModeDistraction(app: String) {
        guard focusModeActive else { return }
        focusModeDistractionCount += 1
        focusModeLastDistractionApp = app
    }
}
```

---

## 🔗 EXACT INSERTION POINTS (Copy-Paste Locations)

### 1. Real-time Distraction Detection
**File:** `ActivityTracker.swift`
**After Line 341** (non-browser) and **After Line 334** (browser):
```swift
// ⭐ NEW: Focus Mode Detection
if AppSettings.shared.focusModeEnabled && category == .distraction {
    AppState.shared.recordFocusModeDistraction(app: appName)
    // TODO: Show UI overlay or notification
}
```

### 2. Sidebar Button
**File:** `DashboardView.swift`
**After Line 112** (end of statusSection):
```swift
private var focusModeSection: some View {
    Section("Focus") {
        Button(action: { 
            if appState.focusModeActive {
                appState.endFocusMode()
            } else {
                appState.startFocusMode()
            }
        }) {
            HStack {
                Image(systemName: appState.focusModeActive ? "target.fill" : "target")
                Text(appState.focusModeActive ? "Focus Active" : "Start Focus")
                Spacer()
                if appState.focusModeActive {
                    Text(Theme.formatDuration(appState.focusModeSessionDuration))
                        .font(.caption2)
                        .foregroundStyle(theme.secondaryText)
                }
            }
        }
        .foregroundStyle(appState.focusModeActive ? theme.successColor : theme.primaryText)
        .listRowSeparator(.hidden)
        .selectionDisabled()
    }
}

// In body after statusSection:
statusSection
focusModeSection  // ← INSERT HERE
todaySection
```

### 3. Settings
**File:** `Models.swift` Line 398
```swift
// After existing @Published properties, add:
var focusModeEnabled: Bool {
    didSet { UserDefaults.standard.set(focusModeEnabled, forKey: "focusModeEnabled") }
}

// In init() after line 425:
self.focusModeEnabled = defaults.object(forKey: "focusModeEnabled") as? Bool ?? false
```

---

## 📈 WHAT THE FLOW LOOKS LIKE

```
User switches to Reddit (distraction site)
         │
         ▼
handleAppSwitch() fires
         │
         ▼
resolveCategory("Google Chrome", "com.google.Chrome", "Reddit - Front Page", url, ...)
         │
         ▼
RuleEngine.categorize() → Category.distraction
         │
         ▼
⭐ YOUR HOOK #1 ⭐ (Line 335 or 342)
  
  if focusModeEnabled && category == .distraction {
      AppState.recordFocusModeDistraction("Google Chrome")
      // focusModeDistractionCount now incremented
      // You can show a toast, beep, or update UI
  }
         │
         ▼
checkDistractionAlert() 
  (existing system fires notification after N minutes)
         │
         ▼
User continues on Reddit for 5 min
         │
         ▼
Checkpoint timer fires / user switches app
         │
         ▼
writeRecord(..., category: .distraction, duration: 5*60, ...)
         │
         ▼
⭐ YOUR HOOK #2 ⭐ (Line 531)
  
  if focusModeEnabled && category == .distraction {
      // Store session analytics:
      // - App: Google Chrome
      // - Duration: 5 min
      // - Time: 2:15 PM
  }
```

---

## 🚀 IMPLEMENTATION CHECKLIST

- [ ] Add `focusModeEnabled`, `focusModeNotificationLevel` to `AppSettings`
- [ ] Add `focusModeActive`, `focusModeDistractionCount` to `AppState` 
- [ ] Insert Hook #1 code after line 334 and 341 in `ActivityTracker.swift`
- [ ] Add `focusModeSection` to `DashboardView.swift` sidebar
- [ ] Add Focus Mode button styling and toggle logic
- [ ] Create `FocusModeOverlayView` (optional: similar to distraction notification)
- [ ] Test with real distraction sites (Reddit, Twitter, YouTube)
- [ ] Add Focus Mode analytics to `StatsView` (optional)

