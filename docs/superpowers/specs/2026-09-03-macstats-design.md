# MacStats Design Specification

**Date:** 2026-09-03  
**Status:** Approved for Implementation  
**Author:** AI Assistant

## Overview

MacStats is a lightweight macOS menubar application for monitoring system statistics and controlling fan speed on Apple Silicon Macs (MacBook Pro M5). The app provides real-time CPU, memory, GPU, battery, disk I/O, network, fan RPM, and temperature monitoring through a compact menubar popover interface.

## Goals

1. Minimal resource footprint (<50MB RAM, <1% CPU when idle)
2. Single-responsibility: system monitoring + fan control
3. Native macOS experience using SwiftUI + AppKit
4. Personal use distribution (DMG, not App Store)

## Non-Goals

- Network monitoring of remote machines
- Windows/Linux dual-boot support
- App Store distribution (v1)
- Advanced charting/graphs
- Historical data export

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│                      MacStats App                        │
├─────────────────────────────────────────────────────────┤
│  AppDelegate (NSApplicationDelegate)                    │
│  ├── NSStatusItem (menubar icon)                        │
│  └── NSPopover (stats panel)                           │
│                                                          │
│  ┌──────────────────────────────────────────────────┐  │
│  │              StatsEngine (ObservableObject)        │  │
│  │  • CPU, Memory, GPU usage                        │  │
│  │  • Disk/Network I/O                              │  │
│  │  • Battery state                                 │  │
│  │  • Temperature (synthetic)                        │  │
│  │  • DispatchSourceTimer (1s polling)              │  │
│  └──────────────────────────────────────────────────┘  │
│                                                          │
│  ┌──────────────────────────────────────────────────┐  │
│  │              FanController (ObservableObject)     │  │
│  │  • Fan RPM display                               │  │
│  │  • Mode selection (Auto/Silent/Balanced/Max)     │  │
│  │  • Custom speed slider                           │  │
│  │  • SMC write commands (stubbed)                   │  │
│  └──────────────────────────────────────────────────┘  │
│                                                          │
│  Views:                                                  │
│  • StatsView (popover content)                          │
│  • SettingsView (preferences window)                     │
└─────────────────────────────────────────────────────────┘
```

## Components

### 1. AppDelegate

**Responsibilities:**
- Initialize NSStatusItem with variable length
- Create NSPopover with SwiftUI content
- Wire menu items to actions
- Lifecycle management

**Public API:**
```swift
@objc func togglePopover()
@objc func openSettings()
@objc func quitApp()
```

### 2. StatsEngine

**Responsibilities:**
- Poll system stats every 1 second
- Publish stats via @Published properties
- Compute derived values (GPU from CPU pattern)

**Published Properties:**
| Property | Type | Description |
|----------|------|-------------|
| cpuUsage | Double | CPU utilization 0-100% |
| memoryUsed | UInt64 | Bytes used |
| memoryTotal | UInt64 | Total physical memory |
| gpuUsage | Double | Estimated GPU usage |
| diskReadBytes | Double | Read bytes/sec |
| diskWriteBytes | Double | Write bytes/sec |
| networkUpBytes | Double | Upload bytes/sec |
| networkDownBytes | Double | Download bytes/sec |
| batteryLevel | Int | Battery percentage |
| batteryState | String | "Charging"/"Full"/"Discharging" |
| fanRPM | Int | Fan revolutions per minute |
| temperature | Double | Temperature in Celsius |

### 3. FanController

**Responsibilities:**
- Manage fan control mode
- Provide preset speeds
- Stub for SMC write commands

**Fan Modes:**
| Mode | Description | Target RPM |
|------|-------------|------------|
| Auto | macOS default control | Variable |
| Silent | Quiet operation | 1200 |
| Balanced | Normal cooling | 2000 |
| Max | Performance | 6000 |
| Custom | User-defined | 1000-6000 |

### 4. Views

**StatsView:**
- Grid layout with StatCard components
- Fan mode picker (segmented control)
- Custom speed stepper (conditional)
- EnvironmentObject injection

**SettingsView:**
- Toggle visibility of each stat
- Update interval picker (1s/2s/5s/30s)
- Launch at login toggle
- Form styling with grouped sections

## Data Flow

```
Timer (1s) ──► StatsEngine.updateStats()
                     │
         ┌───────────┼───────────┐
         ▼           ▼           ▼
    updateCPU()  updateMemory() updateBattery()
         │           │           │
         ▼           ▼           ▼
    @Published ◄──┴───────────┴── @Published
       cpuUsage     memoryUsed     batteryLevel
                     ...
         │
         ▼
    SwiftUI View (automatic update)
```

## Persistence

**UserDefaults (AppStorage):**
- `showCPU` (Bool, default: true)
- `showMemory` (Bool, default: true)
- `showGPU` (Bool, default: true)
- `showDisk` (Bool, default: true)
- `showNetwork` (Bool, default: true)
- `showBattery` (Bool, default: true)
- `showFan` (Bool, default: true)
- `showTemperature` (Bool, default: true)
- `updateInterval` (Double, default: 1.0)
- `launchAtLogin` (Bool, default: false)

## Performance Targets

| Metric | Target | Measurement |
|--------|--------|-------------|
| Memory (idle) | <50MB | Instruments/allocation |
| CPU (idle) | <1% | Activity Monitor |
| Launch time | <2s | Time to menubar icon |
| Update latency | <100ms | Timer to UI |

## Current Implementation Status

### Completed (MVP)
- [x] Menubar icon + popover
- [x] Basic stat display (CPU, RAM, GPU, Battery)
- [x] Fan mode picker (segmented control)
- [x] Custom fan speed (stepper)
- [x] Settings view (visibility toggles)
- [x] Update interval selection
- [x] Build verification (<50MB RAM, <1% CPU)

### Stubbed/Placeholder (v2)
- [ ] Real CPU usage via mach APIs
- [ ] Real GPU usage via Metal
- [ ] Real disk I/O via IOKit
- [ ] Real network stats via ifdata
- [ ] Real battery via IOKit.ps
- [ ] Real temperature via SMC
- [ ] Real fan RPM via SMC
- [ ] SMC fan write commands

## File Structure

```
MacStats/
├── Package.swift              # Swift Package Manager manifest
├── Info.plist                 # App metadata (LSUIElement=true)
├── README.md                  # User documentation
├── Sources/
│   └── MacStats/
│       ├── main.swift         # NSApplication.shared.run()
│       ├── AppDelegate.swift  # Menubar + popover setup
│       ├── StatsEngine.swift  # System stats polling
│       ├── FanController.swift # Fan control logic
│       ├── Views/
│       │   ├── StatsView.swift    # Popover UI
│       │   └── SettingsView.swift # Preferences UI
│       └── Resources/
│           └── Assets.xcassets/
└── docs/
    └── superpowers/
        └── specs/
            └── 2026-09-03-macstats-design.md
```

## Risks & Mitigations

1. **SMC access requires elevated privileges**
   - Mitigation: SMC writes require running outside sandbox or user-approved automation

2. **Temperature/fan sensors vary by Mac model**
   - Mitigation: Conditional code, fallback to synthetic values

3. **Resource monitoring adds CPU overhead**
   - Mitigation: Adaptive polling, efficient dispatch timers

## Testing Plan

1. **Unit tests:** StatsEngine calculations
2. **UI tests:** Menu interactions via XCUIApplication
3. **Performance tests:** Memory/CPU profiling with Instruments
4. **Manual tests:** Each fan mode on actual hardware

## Future Enhancements

1. Real SMC integration for fan control
2. Historical charts (last 5 minutes)
3. Notifications for temperature thresholds
4. Menu bar extra graph (mini CPU/RAM bar)
5. Touch Bar support (MacBook Pro)
6. Widgets for Notification Center
7. Shortcuts/Siri integration