# FlowTrack Focus Mode - Documentation Index

## 📖 Quick Navigation

### 🚀 **START HERE**
📄 **README_FOCUS_MODE.md** - 15-minute implementation guide
- What you have (existing systems)
- What you need to add (4 things)
- Step-by-step code with line numbers
- Testing checklist

### 📋 **QUICK LOOKUP**
📄 **FOCUS_MODE_QUICK_REFERENCE.md** - Instant reference for hookpoints
- Primary distraction detection hook
- Exact insertion points (line numbers)
- Sidebar UI integration
- Settings & state management
- Implementation checklist

### 🏗️ **DEEP DIVE**
📄 **FOCUS_MODE_INTEGRATION.md** - Comprehensive technical details (760 lines)
- Complete SidebarView component breakdown
- ActivityTracker.swift full analysis (lines 300-560)
- Category resolution logic
- Distraction alert state machine
- AppBlockerMonitor reference (what NOT to do)
- Theme colors and styling
- AppSettings infrastructure
- AppState management
- Integration flow diagram

### 🎨 **ARCHITECTURE**
📄 **FOCUS_MODE_ARCHITECTURE.md** - Data flow & system design
- Distraction detection architecture diagram
- Sidebar UI structure (visual)
- AppBlocker comparison
- Implementation architecture
- State machines (Focus Mode + Distraction Detection)
- Testing checklist
- Edge cases

---

## 📊 File Locations & Line Numbers

### Core Hookpoints

| File | Lines | What | Action |
|------|-------|------|--------|
| **ActivityTracker.swift** | 280-345 | handleAppSwitch() | ⭐ PRIMARY HOOK |
| **ActivityTracker.swift** | 334 | Browser category resolved | Insert: record distraction |
| **ActivityTracker.swift** | 341 | Native app category resolved | Insert: record distraction |
| **ActivityTracker.swift** | 519 | Browser title change | Insert: record distraction |
| **ActivityTracker.swift** | 526-529 | resolveCategory() | Reference: category logic |
| **ActivityTracker.swift** | 531-579 | writeRecord() | Optional: analytics hook |
| **ActivityTracker.swift** | 772-814 | checkDistractionAlert() | Reference: state machine |

### UI Integration

| File | Lines | What | Action |
|------|-------|------|--------|
| **DashboardView.swift** | 70-242 | SidebarView | Complete structure |
| **DashboardView.swift** | 90-113 | statusSection | Reference positioning |
| **DashboardView.swift** | 115-130 | todaySection | Reference styling |
| **DashboardView.swift** | 143-161 | focusRing | Reference animation |
| **DashboardView.swift** | 165-198 | bottomBar | Reference material effect |
| **DashboardView.swift** | 140+ | [AFTER] | ➕ Add: focusModeSection |

### Settings & State

| File | Lines | What | Action |
|------|-------|------|--------|
| **AppState.swift** | 7-349 | AppState class | Location to add properties |
| **AppState.swift** | 22 | isInDeepWork | Reference: existing state |
| **Models.swift** | 318-439 | AppSettings class | Location to add settings |
| **Models.swift** | 369-371 | distractionAlertMinutes | Reference: pattern |

### Reference Materials

| File | Lines | What | Purpose |
|------|-------|------|---------|
| **Theme.swift** | 75-134 | AppTheme colors | Colors for Focus button |
| **AppBlockerMonitor.swift** | 1-125 | Blocking system | What NOT to do |
| **Models.swift** | 1-30 | Category enum | Distraction/Work/Idle |

---

## 🎯 Implementation Order

1. **Read:** README_FOCUS_MODE.md (5 min)
2. **Read:** FOCUS_MODE_QUICK_REFERENCE.md (3 min)
3. **Code:** Step 1 - AppState (2 min) → Test in debugger
4. **Code:** Step 2 - Settings (1 min) → Verify UserDefaults
5. **Code:** Step 3 - Hooks (2 min) → Test with Reddit
6. **Code:** Step 4 - UI (3 min) → Polish styling
7. **Test:** Full cycle (5 min)

**Total: 20 minutes**

---

## 🔗 Connections Between Systems

```
┌─ User Input ──────────┐
│ Clicks on Safari      │
└──────────┬────────────┘
           │
           ▼
┌─ OS Level ────────────┐
│ NSWorkspace fires     │
│ didActivate notify    │
└──────────┬────────────┘
           │
           ▼
┌─ ActivityTracker ─────────────┐
│ handleAppSwitch()             │
│ (Lines 280-345)               │
└──────────┬────────────────────┘
           │
           ▼
┌─ RuleEngine ──────────────────┐
│ categorize()                  │
│ (resolveCategory 526-529)     │
│ Returns: .distraction         │
└──────────┬────────────────────┘
           │
    ┌──────┴──────┐
    │             │
    ▼             ▼
System A:      System B:
Alerts         Focus Mode ⭐
─────────      ────────────
Check if >= N  Record count
minutes        Update UI
Fire notif     Track session
    │             │
    └──────┬──────┘
           ▼
┌─ AppState ────────────────────┐
│ @Observable properties        │
│ React to changes              │
└──────────┬────────────────────┘
           │
           ▼
┌─ SwiftUI ─────────────────────┐
│ DashboardView re-renders      │
│ Sidebar updates               │
│ Button color, count shows     │
└───────────────────────────────┘
```

---

## 💾 Database & Persistence

**Settings Storage:**
- **Location:** UserDefaults.standard (macOS system settings)
- **Key:** "focusModeEnabled"
- **Timing:** Persists across app restarts

**Runtime State:**
- **Location:** AppState.shared (in-memory)
- **Timing:** Resets when app quits
- **Scope:** Observable by SwiftUI (auto UI updates)

**Activity Records:**
- **Location:** Database (SQLite, managed by GRDB)
- **Timing:** Persisted every 5min checkpoint or on segment end
- **Schema:** ActivityRecord (lines 45-63 in Models.swift)

---

## 🎨 Visual Design Reference

### Colors (from Theme.swift)

```
Success (Green):     .successColor     → "Focus Active" state
Accent (Blue):       .accentColor      → Button highlight
Primary Text:        .primaryText      → Main labels
Secondary Text:      .secondaryText    → Timer, stats
Error (Red):         .errorColor       → Warning state
Warning (Orange):    .warningColor     → Caution state
```

### Sidebar Spacing

```
HStack spacing:        12-14pt
VStack spacing:        4pt (stats), 0pt (label+value)
Horizontal padding:    14pt
Vertical padding:      2-8pt
Font size (main):      .subheadline
Font size (labels):    .caption2
Font size (numbers):   .system(size: 13, weight: .semibold, design: .rounded)
```

### UI Patterns

```
Button style:    .plain (transparent background)
List separator:  .hidden (in sidebar)
Selection:       .selectionDisabled() (non-navigable items)
Background:      .regularMaterial (frosted glass effect)
Animation:       .easeInOut(duration: 0.6)
```

---

## 🧪 Testing Strategy

### Unit Tests
- [ ] Focus Mode toggle on/off
- [ ] Distraction count increments
- [ ] Session duration calculates
- [ ] Settings persist across restarts

### Integration Tests
- [ ] Switch to distraction app → count increments
- [ ] Switch to work app → count stays same
- [ ] Browser tab switch → handled correctly
- [ ] Window lock/sleep → state preserved

### UI Tests
- [ ] Button appears in sidebar
- [ ] Color changes on toggle
- [ ] Timer displays correctly
- [ ] Sidebar updates reactively

### Performance Tests
- [ ] App switch <100ms to detection
- [ ] No jank in sidebar
- [ ] Memory stays <5MB overhead

---

## 🐛 Debugging Tips

### Enable Logging
```swift
// In ActivityTracker.swift, add:
trackerLogger.info("Focus Mode: distraction detected \(appName)")
```

### Check State
```swift
// In LLDB debugger:
po AppState.shared.focusModeActive
po AppState.shared.focusModeDistractionCount
po AppSettings.shared.focusModeEnabled
```

### Monitor Category Resolution
```swift
// Add temporary print in resolveCategory():
print("Category for \(appName): \(category.rawValue)")
```

### Watch State Changes
```swift
// In SwiftUI preview, add:
.onReceive(AppState.shared.objectWillChange) {
    print("AppState changed")
}
```

---

## 📱 Next Level Features (Optional)

After basic implementation works:

1. **Settings UI Toggle** - Add to SettingsView
2. **Focus Presets** - Quick buttons: 15min, 25min, 50min
3. **Notifications** - Toast when distraction detected
4. **Statistics** - Chart focus sessions in StatsView
5. **Achievements** - Badge for distraction-free sessions
6. **Pomodoro Integration** - Focus Mode with timer
7. **macOS Focus** - Integrate with system Focus modes
8. **Focus Breaks** - Suggest break after N minutes
9. **Export** - Download focus sessions as CSV
10. **Analytics** - Dashboard of focus metrics

---

## ✅ Checklist Before Going Live

- [ ] Code compiles without warnings
- [ ] Basic functionality tested (on/off/count works)
- [ ] Settings persist across restarts
- [ ] UI looks good in all themes
- [ ] No memory leaks (Instruments)
- [ ] Documentation updated
- [ ] Team reviewed
- [ ] Beta tested with real usage

---

## 📞 Support

**Questions about specific lines?**
→ See FOCUS_MODE_QUICK_REFERENCE.md

**Need full context?**
→ See FOCUS_MODE_INTEGRATION.md

**Understanding the architecture?**
→ See FOCUS_MODE_ARCHITECTURE.md

**Ready to code?**
→ See README_FOCUS_MODE.md

---

## 📝 Version Info

- **Created:** 2024
- **FlowTrack Version:** Main branch
- **iOS/macOS Version:** macOS 13+
- **Swift Version:** 5.9+
- **Frameworks:** SwiftUI, Combine, AppKit

---

## 🙏 Summary

**FlowTrack Focus Mode integrates in 4 simple steps:**

1. Add state tracking (30 lines)
2. Add settings persistence (8 lines)
3. Hook into distraction detection (6 lines across 3 places)
4. Add UI button (30 lines)

**Result:** Real-time focus session tracking with <100ms latency

**Effort:** 15-20 minutes implementation + 5 minutes testing

**Impact:** Users can now track distraction-free focus sessions!

