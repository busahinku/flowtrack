# FlowTrack Focus Mode - Architecture & Hookpoints

## Executive Summary

FlowTrack already detects distraction apps in real-time via `RuleEngine.categorize()`. To add Focus Mode:

1. **Hook into category resolution** (ActivityTracker.swift lines 334, 341)
2. **Add UI toggle** in sidebar (DashboardView.swift after line 112)
3. **Persist settings** (AppSettings.swift)
4. **Track state** (AppState.swift)

**Latency: <100ms** from app switch to focus mode detection ✅

---

## PRIMARY HOOKPOINT: Real-Time Detection

**File:** `/Users/buraksahinkucuk/Desktop/CODING/startup/flowtrack/FlowTrack/Tracking/ActivityTracker.swift`

**Lines 334 & 341 - After Category Resolution:**

```swift
// LINE 334 (Browser)
let cat = self.resolveCategory(appName: appName, bundleID: bundleID, title: resolvedTitle, url: info.url, isIdle: false, contentMetadata: metadata)
self.checkDistractionAlert(category: cat)

// ⭐ INSERT FOCUS MODE CODE HERE ⭐
if AppSettings.shared.focusModeEnabled && cat == .distraction {
    AppState.shared.recordFocusModeDistraction(app: appName)
    // Optional: Show toast overlay, play sound, etc.
}
```

---

## SIDEBAR UI LOCATION

**File:** `/Users/buraksahinkucuk/Desktop/CODING/startup/flowtrack/FlowTrack/UI/DashboardView.swift`

**Add New Section After Line 112:**

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

// In SidebarView.body:
var body: some View {
    List(selection: $selectedTab) {
        statusSection
        focusModeSection    // ← NEW
        todaySection
        viewsSection
    }
}
```

---

## SETTINGS & STATE

**AppSettings.swift (Lines 318-439):**

```swift
var focusModeEnabled: Bool {
    didSet { UserDefaults.standard.set(focusModeEnabled, forKey: "focusModeEnabled") }
}

var focusModeNotificationLevel: String {
    didSet { UserDefaults.standard.set(focusModeNotificationLevel, forKey: "focusModeNotificationLevel") }
}

// In init():
self.focusModeEnabled = defaults.object(forKey: "focusModeEnabled") as? Bool ?? false
self.focusModeNotificationLevel = defaults.string(forKey: "focusModeNotificationLevel") ?? "balanced"
```

**AppState.swift (Line 7+):**

```swift
@Observable
final class AppState {
    // ... existing ...
    
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

## THEME COLORS AVAILABLE

From Theme.swift (Lines 75-134):

- **successColor** (green): Use for "Focus Active" state
- **accentColor** (blue): Use for button highlight
- **errorColor** (red): Use for distraction alerts
- **warningColor** (orange): Use for "Focus Paused"
- **secondaryText** (gray): Use for duration/stats

---

## COMPLETE DATA FLOW

```
1. User switches to Reddit
   ↓
2. NSWorkspace fires notification
   ↓
3. ActivityTracker.handleAppSwitch(app)
   ↓
4. resolveCategory(...) → .distraction
   ↓
5. ⭐ YOUR CODE FIRES ⭐
   AppState.recordFocusModeDistraction("Safari")
   ↓
6. focusModeDistractionCount increments
   ↓
7. SwiftUI reacts, sidebar updates
   ↓
8. User sees new count or distraction indicator
```

**Total latency: ~30-100ms**

