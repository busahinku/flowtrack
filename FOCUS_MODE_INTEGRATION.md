# FlowTrack Focus Mode Integration Guide

## 1. SIDEBAR UI STRUCTURE (DashboardView.swift)

**File:** `/Users/buraksahinkucuk/Desktop/CODING/startup/flowtrack/FlowTrack/UI/DashboardView.swift`

### Complete SidebarView Components:

#### **Status Section** (Lines 90-113)
```swift
Section("Status") {
    Label {
        HStack {
            Text(tracker.isTracking ? "Tracking" : "Paused")  // Line 94
            Spacer()
            if !tracker.currentApp.isEmpty {
                Text(tracker.currentApp)  // Line 97
                    .font(.caption2)
                    .foregroundStyle(theme.secondaryText)
                    .lineLimit(1)
            }
        }
    } icon: {
        Circle()
            .fill(tracker.isTracking ? theme.successColor : theme.errorColor)  // Line 105
            .frame(width: 8, height: 8)
    }
}
```
**Styling:** Uses `theme.secondaryText` for color, no custom padding

#### **Today Stats Section** (Lines 115-130)
```swift
Section("Today") {
    HStack(spacing: 14) {
        focusRing  // Circular progress ring below
        VStack(alignment: .leading, spacing: 4) {
            statRow("Distraction", distractionTime)  // Line 120
            statRow("Active",      totalActiveTime)  // Line 121
            statRow("Timer",       todayTrackedTime) // Line 122
        }
        Spacer()
    }
    .padding(.vertical, 2)  // Line 126 - minimal vertical padding
}
```

**Focus Ring (Lines 143-161):**
- **Width/Height:** 46x46 pt frame
- **Styling:**
  - Outer circle: `theme.secondaryText.opacity(0.15)`, lineWidth 5
  - Progress stroke: `theme.accentColor`, lineWidth 5, `.round` lineCap
  - Animation: `.easeInOut(duration: 0.6)`
  - Text inside: 12pt bold, rounded design
  - Displays: `{Int(focusScorePercent * 100)}%` with "Focus" label

**Stat Row Helper (Lines 202-210):**
```swift
VStack(alignment: .leading, spacing: 0) {
    Text(value)
        .font(.system(size: 13, weight: .semibold, design: .rounded))
    Text(label)
        .font(.caption2)
        .foregroundStyle(theme.secondaryText)
}
```

#### **Views Section** (Lines 132-139)
```swift
Section("Views") {
    ForEach(DashboardTab.allCases, id: \.self) { tab in
        Label(tab.rawValue, systemImage: tab.icon)  // Line 135
            .tag(tab as DashboardTab?)
    }
}
```
**Available Tabs:** timeline, stats, heatmap, chat, todos, timer, journal, blocker

#### **Bottom Bar (Lines 165-198)** 
- AI Processing Status: Uses `theme.warningColor` when active
- Settings Link: `.plain` button style
- Background: `.regularMaterial` (macOS frosted glass effect)
- Divider at top

### Key Visual Properties Available:
- **cornerRadius:** Not explicitly used in sidebar (uses macOS defaults)
- **Padding:** Horizontal 14pt, Vertical varies (7pt for AI bar, 8pt for settings)
- **Shadows:** None in sidebar (delegated to card components)
- **Font sizes:** Subheading for main items, caption2 for labels

---

## 2. REAL-TIME DISTRACTION DETECTION HOOKPOINTS

**File:** `/Users/buraksahinkucuk/Desktop/CODING/startup/flowtrack/FlowTrack/Tracking/ActivityTracker.swift`

### The Complete Flow:

#### **HOOK POINT #1: App Switch Handler (Lines 280-345)**
```swift
private func handleAppSwitch(app: NSRunningApplication) {  // Line 280
    let appName = app.localizedName ?? "Unknown"
    let bundleID = app.bundleIdentifier ?? ""
    guard !AppSettings.shared.excludedBundleIDs.contains(bundleID) else { return }  // Line 287
    
    currentApp = appName  // Line 289
    
    // === EARLIEST STATIC CATEGORY ASSIGNMENT (Non-Browser) ===
    // Line 341: For non-browsers, category is resolved IMMEDIATELY
    let cat = resolveCategory(appName: appName, bundleID: bundleID, title: title, url: nil, isIdle: false)
    checkDistractionAlert(category: cat)  // Line 342 - DISTRACTION DETECTION FIRES HERE
    lastSavedCategory = cat  // Line 343 - category cached
    
    // === FOR BROWSERS: Async category assignment ===
    // Lines 313-345: Browser fetch task fires in background
    // After fetch completes:
    //   Line 334: cat = self.resolveCategory(..., contentMetadata: metadata)
    //   Line 335: self.checkDistractionAlert(category: cat)  ← DISTRACTION ALERT FOR BROWSER
}
```

#### **HOOK POINT #2: Category Resolution (Line 526-529)**
```swift
private func resolveCategory(appName: String, bundleID: String, title: String, 
                            url: String?, isIdle: Bool, 
                            contentMetadata: ContentMetadata? = nil) -> Category {
    if isIdle { return .idle }
    return RuleEngine.shared.categorize(appName: appName, bundleID: bundleID, 
                                       windowTitle: title, url: url, 
                                       contentMetadata: contentMetadata) ?? .uncategorized
}
```

**Where it's called:**
1. **Line 334** - After browser URL fetch completes (async)
2. **Line 341** - On non-browser app switch (sync)
3. **Line 393** - On initial capture at tracker startup (sync)
4. **Line 513** - On browser window title change, after URL update (async)
5. **Line 518** - On non-browser window title change (sync)

#### **HOOK POINT #3: Distraction Alert Mechanism (Lines 772-814)**
```swift
private func checkDistractionAlert(category: Category) {  // Line 772
    let alertMinutes = AppSettings.shared.distractionAlertMinutes  // Line 773
    guard alertMinutes > 0 else { 
        distractionStartTime = nil
        distractionPausedAt = nil
        return 
    }
    
    // === STATE MACHINE FOR DISTRACTION DETECTION ===
    if category == .distraction {  // Line 776
        if let paused = distractionPausedAt {
            // Grace period active — check if enough time passed to reset timer
            if Date().timeIntervalSince(paused) > 60 {
                distractionStartTime = Date()  // Reset if away >60s
            }
            distractionPausedAt = nil
        } else if distractionStartTime == nil {
            distractionStartTime = Date()  // Start timer on first distraction
        }
        
        // Check if threshold reached
        guard let start = distractionStartTime else { return }
        let elapsed = Date().timeIntervalSince(start)  // Line 789
        let threshold = TimeInterval(alertMinutes * 60)  // Line 790
        
        // Fire notification only once per threshold interval
        let canFire = lastDistractionAlertFired.map { 
            Date().timeIntervalSince($0) > threshold 
        } ?? true  // Line 791
        
        if elapsed >= threshold && canFire {
            lastDistractionAlertFired = Date()
            fireDistractionNotification(minutes: alertMinutes)  // Line 794
        }
    } else {
        // Switched away from distraction
        if distractionStartTime != nil && distractionPausedAt == nil {
            distractionPausedAt = Date()  // Enter 60s grace period
        }
    }
}
```

**Private State Variables (Lines 74-76):**
```swift
private var distractionStartTime: Date?          // When distraction started
private var distractionPausedAt: Date?           // Grace period timer
private var lastDistractionAlertFired: Date?     // Rate limiter for alerts
```

#### **HOOK POINT #4: Write Record (Lines 531-579)**
```swift
private func writeRecord(
    appName: String, bundleID: String, title: String, url: String?, 
    category: Category,  // ← CATEGORY ALREADY DETERMINED BY THIS POINT
    isIdle: Bool, duration: TimeInterval, 
    segmentStart: Date? = nil, 
    contentMetadata: ContentMetadata? = nil
) {  // Line 531
    guard duration >= 5 || isIdle else { return }  // Line 532
    
    // Extract/resolve content metadata (Lines 535-544)
    let resolvedMetadata: ContentMetadata?
    if let m = contentMetadata {
        resolvedMetadata = m
    } else if let url = url {
        resolvedMetadata = ContentMetadataExtractor.extract(url: url, windowTitle: title, appName: appName)
    } else if !title.isEmpty {
        resolvedMetadata = ContentMetadataExtractor.extractNativeApp(windowTitle: title, appName: appName, bundleID: bundleID)
    } else {
        resolvedMetadata = nil
    }
    
    // Create ActivityRecord with all context (Line 552-559)
    let record = ActivityRecord(
        timestamp: segmentStart ?? Date(),  // Line 556 - timestamp of segment START
        appName: appName, bundleID: bundleID,
        windowTitle: title, url: url, category: category,  // Line 558
        isIdle: isIdle, duration: duration, contentMetadata: metadataJSON
    )
    
    // Async DB write with retry logic (Lines 561-578)
    Task(priority: .utility) {
        for attempt in 0..<maxRetries {
            try Database.shared.saveActivity(record)  // Line 566
        }
    }
}
```

---

## 3. FOCUS MODE INTEGRATION POINTS

### **Where to Insert Focus Mode Detection:**

#### **PRIMARY HOOK: After Category Resolution** (BEST FOR REAL-TIME)
**Location:** Line 335 (browser) and Line 342 (non-browser) in `handleAppSwitch()`

```swift
// AFTER this line:
let cat = resolveCategory(appName: appName, bundleID: bundleID, title: title, ...)
checkDistractionAlert(category: cat)

// ADD THIS:
if focusModeEnabled && cat == .distraction {
    focusModeDetectDistraction(
        appName: appName, 
        bundleID: bundleID, 
        title: title,
        url: url,
        category: cat
    )
}
```

**Why this is best:**
- Fires IMMEDIATELY after category is determined ✅
- Before any DB write (low latency) ✅
- Works for both browsers and native apps ✅
- Has all context: appName, bundleID, title, URL, category ✅

#### **SECONDARY HOOK: AX Title Change Detection** (For Real-time Title/Tab Switches)
**Location:** Line 439-490 in `handleAXTitleChange()`

After title change is resolved (line 513 or 518), you could inject:
```swift
let cat = resolveCategory(appName: appName, bundleID: bundleID, title: resolvedTitle, url: info.url, isIdle: false)
checkDistractionAlert(category: cat)
// NEW:
if focusModeEnabled && cat == .distraction {
    focusModeDetectTitleChange(oldTitle: lastSavedTitle, newTitle: resolvedTitle, category: cat)
}
```

#### **TERTIARY HOOK: Window Segment End** (For Session Summary)
**Location:** Line 531 in `writeRecord()`

After category is determined but before DB write:
```swift
private func writeRecord(..., category: Category, ...) {
    // INJECT HERE - before DB write:
    if focusModeEnabled && category == .distraction {
        focusModeRecordSegment(
            appName: appName,
            category: category,
            duration: duration,
            segmentStart: segmentStart
        )
    }
    
    // Then proceed with normal write
    let record = ActivityRecord(...)
}
```

---

## 4. APPBLOCKERMONITOR: Existing Blocking Mechanism

**File:** `/Users/buraksahinkucuk/Desktop/CODING/startup/flowtrack/FlowTrack/Storage/AppBlockerMonitor.swift`

### How It Works:

#### **Enforcement Timer (Lines 25-44)**
```swift
func updateActive() {  // Line 31
    let hasActiveBlocks = store.cards.contains(where: \.isEnabled)  // Line 32
    if hasActiveBlocks && tickTimer == nil {
        tickTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }  // Line 36
        }
    }
}
```

#### **Main Enforcement Loop (Lines 48-94)**
```swift
private func tick() {  // Line 48
    let now = Date()
    let elapsed = min(Int(now.timeIntervalSince(lastTickDate)), 10)  // Line 51
    
    let currentBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""  // Line 58
    
    for card in store.cards where card.isEnabled {  // Line 60
        // --- App Enforcement ---
        if !card.apps.isEmpty, !currentBundleID.isEmpty {  // Line 62
            if let matched = card.apps.first(where: { $0.bundleID.lowercased() == currentBundleID.lowercased() }) {
                if card.isAlwaysBlock {
                    terminateApp(bundleID: currentBundleID, ...)  // Line 68
                } else {
                    store.recordUsage(cardId: card.id, addSeconds: elapsed)  // Line 70
                    if store.usageToday(for: card.id) >= card.dailyLimitMinutes * 60 {
                        terminateApp(...)  // Line 74 - Time limit exceeded
                    }
                }
            }
        }
        
        // --- Website Time-Limit Enforcement ---
        if !card.websites.isEmpty && !card.isAlwaysBlock {  // Line 82
            if store.usageToday(for: card.id) >= card.dailyLimitMinutes * 60 {
                store.blockCardNow(cardId: card.id)  // Line 86
                sendBlockNotification(...)  // Line 89
            }
        }
    }
}
```

#### **Enforcement Actions**

**App Termination (Lines 98-107):**
```swift
private func terminateApp(bundleID: String, cardId: String, cardName: String, limitMinutes: Int) {
    for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID) {
        app.forceTerminate()  // Line 100 - FORCEFUL, NO GRACE PERIOD
    }
    sendBlockNotification(name: cardName, limitMinutes: limitMinutes)
}
```

**Website Blocking (Line 86):**
```swift
store.blockCardNow(cardId: card.id)  // Delegates to AppBlockerStore
// Likely redirects browser traffic, not terminating it
```

#### **Notification System (Lines 109-123)**
```swift
private func sendBlockNotification(name: String, limitMinutes: Int) {
    let content = UNMutableNotificationContent()
    content.title = "Blocked by FlowTrack"
    content.body = limitMinutes == 0
        ? "\(name) is blocked to keep you focused."
        : "\(name) reached its \(limitMinutes)-minute daily limit."
    content.sound = .default
    UNUserNotificationCenter.current().add(UNNotificationRequest(...))
}
```

### **Can Focus Mode Reuse AppBlockerMonitor?**

✅ **YES - Partially:**
- **Reusable:** The 5-second tick timer pattern, notification system, time tracking
- **Not reusable:** The enforcement is too aggressive for Focus Mode
  - Focus Mode should suggest/notify, not force-terminate
  - Focus Mode needs softer UX (popup, snooze options, etc.)
  - AppBlockerMonitor is designed for strict blocking, not optional focus assistance

**Recommendation:** Create `FocusModeMonitor` following same pattern but with:
- Same 5s tick timer
- Softer notifications (optional, with snooze/dismiss)
- No force termination, just visual alerts
- Integration with macOS Focus/Do Not Disturb if desired

---

## 5. THEME.SWIFT: UI STYLING REFERENCE

**File:** `/Users/buraksahinkucuk/Desktop/CODING/startup/flowtrack/FlowTrack/UI/Theme.swift`

### **AppTheme Enum** (Lines 7-190)

#### Available Themes:
- `.system` - Uses macOS system appearance
- `.light` - Light mode
- `.dark` - Dark mode
- `.pastel` - Purple pastels
- `.midnight` - Deep blue/purple

#### **Color Properties** (for Focus Mode Button):

```swift
// Line 75-81: Accent Color (Primary brand color)
var accentColor: Color {
    switch self {
    case .system, .light, .dark: return .blue        // Standard blue
    case .pastel: return Color(red: 0.6, green: 0.4, blue: 0.8)   // Purple
    case .midnight: return Color(red: 0.3, green: 0.4, blue: 0.9) // Bright blue
    }
}

// Line 104-112: Success Color (Green - for "Focus Active")
var successColor: Color {
    switch self {
    case .system: return .green
    case .light: return Color(red: 0.18, green: 0.65, blue: 0.32)
    case .dark: return Color(red: 0.25, green: 0.82, blue: 0.45)
    case .pastel: return Color(red: 0.28, green: 0.68, blue: 0.52)
    case .midnight: return Color(red: 0.18, green: 0.88, blue: 0.62)
    }
}

// Line 114-123: Error Color (Red - for "Focus Alert")
var errorColor: Color {
    switch self {
    case .system: return .red
    case .light: return Color(red: 0.85, green: 0.20, blue: 0.20)
    case .dark: return Color(red: 1.0, green: 0.40, blue: 0.40)
    case .pastel: return Color(red: 0.88, green: 0.40, blue: 0.55)
    case .midnight: return Color(red: 1.0, green: 0.32, blue: 0.48)
    }
}

// Line 125-134: Warning Color (Orange - for "Focus Paused")
var warningColor: Color {
    switch self {
    case .system: return .orange
    case .light: return Color(red: 0.92, green: 0.55, blue: 0.10)
    case .dark: return Color(red: 1.0, green: 0.72, blue: 0.28)
    case .pastel: return Color(red: 0.93, green: 0.62, blue: 0.38)
    case .midnight: return Color(red: 1.0, green: 0.76, blue: 0.28)
    }
}

// Line 25-43: Card Background
var cardBg: Color {
    switch self {
    case .system: return Color(nsColor: .textBackgroundColor)
    case .light: return .white
    case .dark: return Color(red: 0.15, green: 0.15, blue: 0.17)
    case .pastel: return Color(red: 0.96, green: 0.95, blue: 0.98)
    case .midnight: return Color(red: 0.10, green: 0.10, blue: 0.18)
    }
}
```

#### **Typical Card/Button Pattern in FlowTrack:**

From DashboardView sidebar (Lines 117-127):
```swift
HStack(spacing: 14) {
    focusRing                      // Custom component
    VStack(alignment: .leading, spacing: 4) {
        statRow("Distraction", distractionTime)
    }
    Spacer()
}
.padding(.vertical, 2)             // MINIMAL vertical padding
.listRowSeparator(.hidden)         // No separator
```

From Theme helper (Line 277-283):
```swift
static func formatDuration(_ seconds: Double) -> String {
    let h = Int(seconds) / 3600
    let m = (Int(seconds) % 3600) / 60
    if h > 0 { return "\(h)h \(m)m" }
    if m > 0 { return "\(m)m" }
    return "<1m"
}
```

#### **What's Missing (for Focus Mode Button):**
- No explicit `cornerRadius` property (use standard: 8pt)
- No `shadow` helper (add using SwiftUI's `.shadow(...)`)
- No `padding` constants (sidebar uses: 14pt horizontal, 7-8pt vertical)

#### **Recommended Focus Mode Button Style:**
```swift
Label("Focus Mode", systemImage: "scope")
    .font(.subheadline)
    .foregroundStyle(theme.selectedForeground)
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, 14)      // Match sidebar
    .padding(.vertical, 8)         // Match settings button
    .background(theme.successColor) // Green when active
    .cornerRadius(8)
    .contentShape(Rectangle())
```

---

## 6. APPSETTINGS.SWIFT: Existing Settings Infrastructure

**File:** `/Users/buraksahinkucuk/Desktop/CODING/startup/flowtrack/FlowTrack/Storage/Models.swift` (Lines 318-439)

### **Current Focus/Productivity Settings:**

```swift
// Lines 369-371: Existing Distraction Alert Setting
var distractionAlertMinutes: Int {
    didSet { UserDefaults.standard.set(distractionAlertMinutes, forKey: "distractionAlertMinutes") }
}

// Lines 366-368: Idle Detection Threshold
var idleThresholdSeconds: Int {
    didSet { UserDefaults.standard.set(idleThresholdSeconds, forKey: "idleThresholdSeconds") }
}

// Lines 375-386: Pomodoro Settings (work/break/long break durations)
var pomodoroWorkMinutes: Int { didSet {...} }
var pomodoroBreakMinutes: Int { didSet {...} }
var pomodoroLongBreakMinutes: Int { didSet {...} }
var pomodoroSessionsBeforeLong: Int { didSet {...} }
```

### **Persistence Pattern:**
All settings use `UserDefaults.standard` with `didSet` observers:
```swift
var myNewSetting: Bool {
    didSet { UserDefaults.standard.set(myNewSetting, forKey: "myNewSetting") }
}
```

### **Initialization Pattern** (Lines 400-426):
```swift
private init() {
    let defaults = UserDefaults.standard
    self.myNewSetting = defaults.object(forKey: "myNewSetting") as? Bool ?? false  // Default value
}
```

### **For Focus Mode, Add These Settings:**

```swift
// In AppSettings class:
var focusModeEnabled: Bool {
    didSet { UserDefaults.standard.set(focusModeEnabled, forKey: "focusModeEnabled") }
}

var focusModeDistrictionsLimit: Int {  // How many distractions before alert
    didSet { UserDefaults.standard.set(focusModeDistrictionsLimit, forKey: "focusModeDistrictionsLimit") }
}

var focusModeNotificationLevel: FocusModeNotificationLevel {
    didSet { UserDefaults.standard.set(focusModeNotificationLevel.rawValue, forKey: "focusModeNotificationLevel") }
}

// In init():
self.focusModeEnabled = defaults.object(forKey: "focusModeEnabled") as? Bool ?? false
self.focusModeDistrictionsLimit = defaults.object(forKey: "focusModeDistrictionsLimit") as? Int ?? 3
self.focusModeNotificationLevel = FocusModeNotificationLevel(rawValue: defaults.string(forKey: "focusModeNotificationLevel") ?? "") ?? .balanced
```

---

## 7. APPSTATE.SWIFT: Real-time State Management

**File:** `/Users/buraksahinkucuk/Desktop/CODING/startup/flowtrack/FlowTrack/AppState.swift`

### **Current Focus-Related State:**

```swift
// Line 22: Deep work detection (already exists!)
var isInDeepWork: Bool = false  // True when in productive session ≥20 min

// Line 337-348: Deep work detection logic
private func updateDeepWorkState() {
    let deepWorkThreshold: TimeInterval = 20 * 60
    let hasDeepWork = timeSlots.contains {
        !$0.isIdle && $0.category.isProductive && $0.duration >= deepWorkThreshold
    }
    if hasDeepWork != isInDeepWork {
        isInDeepWork = hasDeepWork
        if hasDeepWork {
            log.info("Deep work session detected")
        }
    }
}
```

### **For Focus Mode, Add:**

```swift
@Observable
final class AppState {
    // ... existing properties ...
    
    // NEW: Focus Mode State
    var focusModeActive: Bool = false
    var focusModeStartedAt: Date?
    var focusModeDistractionCount: Int = 0
    var focusModeLastDistractionApp: String?
    
    // Method to start focus mode
    func startFocusMode() {
        focusModeActive = true
        focusModeStartedAt = Date()
        focusModeDistractionCount = 0
        focusModeLastDistractionApp = nil
        log.info("Focus Mode started")
    }
    
    // Method to end focus mode
    func endFocusMode() {
        focusModeActive = false
        log.info("Focus Mode ended")
    }
    
    // Method to record a distraction during focus mode
    func recordFocusModeDistraction(app: String) {
        guard focusModeActive else { return }
        focusModeDistractionCount += 1
        focusModeLastDistractionApp = app
    }
}
```

---

## 8. INTEGRATION FLOW DIAGRAM

```
┌─ NSWorkspace Notification ─────────────────────┐
│  (App switched: frontmost app changed)         │
└────────────────────┬────────────────────────────┘
                     │
                     ▼
        ┌─ handleAppSwitch() ────────────────┐
        │  Line 280 in ActivityTracker.swift │
        └────────────┬────────────────────────┘
                     │
         ┌───────────▼───────────┐
         │  Get app name/bundle  │
         │  Get window title (AX)│
         │  Check if excluded    │
         └───────────┬───────────┘
                     │
         ┌───────────▼──────────────────────────┐
         │  FOR BROWSER:                        │
         │  Async fetch URL + page title        │
         │  (via AppleScript)                   │
         │                                      │
         │  FOR NATIVE APP:                     │
         │  Use window title directly           │
         └───────────┬──────────────────────────┘
                     │
         ┌───────────▼─────────────────────────────┐
         │ ⭐ PRIMARY HOOK POINT ⭐               │
         │                                       │
         │ resolveCategory(...) → Category       │
         │ Line 334 (browser) or 341 (native)    │
         │                                       │
         │ RuleEngine.categorize() checks:       │
         │  • BundleID rules                     │
         │  • URL domain rules                   │
         │  • Content metadata AI tags           │
         │  • Falls back to .uncategorized       │
         └───────────┬─────────────────────────────┘
                     │
         ┌───────────▼──────────────────────────┐
         │ checkDistractionAlert()              │
         │ Line 335 or 342                      │
         │                                      │
         │ IF category == .distraction:        │
         │  • Start distraction timer           │
         │  • Check if >= alert threshold       │
         │  • Fire UNNotification               │
         │                                      │
         │ ELSE (category == .work/.idle):     │
         │  • Enter grace period (60s)          │
         └───────────┬──────────────────────────┘
                     │
         ┌───────────▼──────────────────────────┐
         │ ⭐ FOCUS MODE HOOK ⭐               │
         │                                      │
         │ if focusModeEnabled &&               │
         │    category == .distraction:         │
         │                                      │
         │    focusModeDetectDistraction(       │
         │      appName, bundleID,              │
         │      title, url, category            │
         │    )                                 │
         │                                      │
         │ UPDATE: AppState.recordFocusMode... │
         │ NOTIFY: Show Focus Mode UI           │
         └───────────┬──────────────────────────┘
                     │
         ┌───────────▼─────────────────────────────┐
         │ Continue normal tracking...             │
         │ Store state in memory for checkpoint    │
         │ (line 310-312: lastSavedBundleID, etc) │
         └──────────────────────────────────────────┘
                     │
                     ▼
         (Periodically via checkpoint timer)
         ┌──────────────────────────────────┐
         │ endCurrentSegment() writes DB    │
         │ → writeRecord(category: cat)     │
         │ Line 531                         │
         └──────────────────────────────────┘
                     │
         ┌───────────▼──────────────────────────┐
         │ ⭐ SECONDARY HOOK: Write Record ⭐ │
         │                                      │
         │ if focusModeEnabled &&               │
         │    category == .distraction:         │
         │                                      │
         │    focusModeRecordSegment(...)       │
         │                                      │
         │ Store analytics: duration,           │
         │ time of day, etc.                    │
         └──────────────────────────────────────┘
```

---

## SUMMARY: All Hook Points for Focus Mode

| **Hook** | **Location** | **Timing** | **Data Available** | **Use Case** |
|----------|------------|----------|------------------|-----------|
| **#1: App Switch** | ActivityTracker.swift:335, 342 | Immediate on switch | appName, bundleID, title, URL, category | Real-time detection, alerts |
| **#2: Title Change** | ActivityTracker.swift:513, 518 | Async after URL fetch | Old/new title, URL, category | Browser tab switch detection |
| **#3: Write Record** | ActivityTracker.swift:531 | Before DB persist | Full segment context | Session analytics, streak tracking |
| **#4: Distraction Alert** | ActivityTracker.swift:772 | On category determination | category, timing, duration so far | Integrate with Focus UI |

**Recommended:** Use Hook #1 for primary Focus Mode detection (lowest latency, most reliable)

**Settings Required:**
- `AppSettings.focusModeEnabled: Bool`
- `AppSettings.focusModeNotificationLevel: Enum`
- `AppState.focusModeActive: Bool`
- `AppState.focusModeDistractionCount: Int`

**UI Integration:** Add button to sidebar "Today" section (next to focusRing at line 118) or as a new "Focus" section after Status

