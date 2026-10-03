# MacStats Audio Control Design

**Date:** 2026-09-17

**Status:** Implemented; hardware verification pending (see #3–#5)

## Context

MacStats is a macOS 13+ menu-bar monitor implemented with SwiftPM, AppKit, and
SwiftUI. The popover currently contains the system-stat cards and Settings is a
separate AppKit window. It has no audio subsystem.

The requested direction is a Mac-native mixer similar in spirit to VoiceMeeter:
show audio sources, choose input and output devices, and independently control
the sound from applications. The product must make its platform limits clear:
macOS exposes audio devices and system output controls on macOS 13, while the
public Core Audio tap APIs needed to capture and re-render selected application
audio require macOS 14.2 or later. A browser tab is not a stable Core Audio
source; applications are the first-class unit.

## Product decisions

1. MacStats keeps its macOS 13 minimum deployment target.
2. The popover gains two tabs: **System** (the existing statistics cards) and
   **Audio**.
3. Audio on macOS 13 provides device inspection and selection, output master
   volume, and mute. It never claims application-level mixing is active.
4. The true per-application mixer is a macOS 14.2+ capability. It is opt-in,
   requests system-audio capture permission before activation, and presents a
   clear unavailable state when the OS or permission does not support it.
5. A browser is one application source. Tab-level controls require a separate
   browser extension or browser-specific integration and are excluded from this
   milestone.
6. Virtual microphones, arbitrary routing graphs, recording, persistent audio
   capture, and a custom Audio Server Driver Plug-in are excluded. They are a
   separate product and security milestone.

## User experience

### System tab

The present `StatsView` becomes the System tab without changing card behaviour
or existing settings. The first displayed tab remains System, so a current user
sees the same monitor after updating.

### Audio tab on every supported Mac

The Audio tab has a compact, read-only-first layout:

- **Output**: the current default output device, a picker for eligible output
  devices, a master-volume slider, and a mute toggle.
- **Input**: the current default input device and a picker for eligible input
  devices. It does not record or monitor microphone content.
- **App mixer**: an explanatory state. On macOS 13–14.1 it says that
  application mixing requires macOS 14.2 or later. On newer systems it offers
  an explicit “Enable app mixer” action.

Device changes write only the user’s default input/output selection. Sliders
and mute changes are immediately reflected from Core Audio. If the selected
device lacks a writable master volume or mute control, the corresponding
control is disabled and its reason is displayed.

### App mixer on macOS 14.2+

Choosing “Enable app mixer” explains that MacStats must capture system audio to
separate app streams. It asks for the OS permission only after the user chooses
to enable this feature; refusing permission leaves normal device controls
available.

When enabled, the tab lists active, audible processes with application name,
icon, volume slider, mute control, and a status indicator. A process with no
bundle identity uses its executable name. Each row controls an app stream that
MacStats has tapped and re-rendered to the selected output. Processes that
cannot be tapped remain visible only when Core Audio reports them, labelled as
unavailable rather than silently treated as muted.

The app mixer automatically stops and removes its aggregate/tap resources when
the Audio tab closes, the feature is toggled off, the output device changes,
audio permission is revoked, or MacStats terminates. The app restores normal
system output rather than retaining a routing configuration.

## Architecture

### Audio device layer: macOS 13+

`AudioDeviceService` is the single Core Audio owner for enumerating devices,
reading default device IDs, observing device/default-device changes, and safely
reading or writing device volume and mute properties. It exposes UI-safe value
types:

- `AudioDevice`: stable ID, name, input/output capability, and whether volume
  and mute are writable.
- `AudioDeviceState`: default input/output IDs, selected output volume, mute,
  and unavailable-control reasons.

It validates property support and writability before every mutation, then
re-reads the property before publishing state. Errors are typed locally and
shown as non-destructive status messages.

### App mixer layer: macOS 14.2+

`AppMixerService` is a separate, availability-gated component. It manages Core
Audio process discovery, a process tap per selected active source, and the
private aggregate device used to render mixed streams to the current output.
`AppMixerSession` owns all transient tap/aggregate identifiers and teardown.

The audio render path must not invoke SwiftUI, allocate, log, or access
`UserDefaults`. It uses a small real-time-safe gain/mute state indexed by stream
identifier. UI changes update that state atomically; the audio callback reads
it. `AppMixerService` publishes process metadata and non-real-time failures on
the main actor.

MacStats will request system-audio capture permission at enable time and check
the result before creating a session. It does not start a tap at launch or while
the Audio tab is idle. One session has one output device. Changing the output
stops the old session, cleans up its objects, selects the new device, and may
restart only after the user re-enables the mixer.

### UI and lifecycle

`StatsView` owns a `PopoverTab` selection and embeds `SystemStatsTab` and
`AudioTab`. `AppDelegate` owns long-lived `AudioDeviceService` observation and
calls `AppMixerService.stop()` from the existing idempotent termination path.
The Audio tab owns only presentation, not Core Audio object lifetime.

The Audio capability is separate from `StatsEngine` because audio hardware
events and audio rendering have different cadence, permissions, failure modes,
and lifecycle requirements.

## Data and persistence

The normal audio controls do not persist a duplicate of macOS’s default-device,
volume, or mute state; Core Audio remains the source of truth. MacStats stores
only the user’s local preference for whether the app-mixer section is expanded.
It never persists a captured stream, audio data, device identifier for forced
routing, or a background “mixer enabled” state.

Per-app volume/mute applies only while an explicit `AppMixerSession` runs. It
is intentionally ephemeral in this milestone, avoiding unexpected routing or
capture after restart.

## Error handling and privacy

- No devices: show a refreshable empty state; do not crash or fabricate a
  built-in device.
- Unsupported/writable property: leave that control disabled and identify the
  device limitation.
- Permission denial/revocation: stop the mixer session, remove transient
  objects, and keep normal device controls usable.
- Tap, aggregate-device, or render failure: stop the session, release every
  created Core Audio object, report an actionable status, and never loop retry.
- Output-device disappearance: stop the session and refresh devices.

MacStats neither records audio nor sends it over the network. System-audio
capture exists only for the active in-app mixer session, remains on-device, and
ends when that session ends.

## Non-goals and follow-up milestones

This scope deliberately excludes browser-tab sliders, full routing matrices,
virtual input/output devices, audio effects, saving profiles, recording, and
launch-time background audio capture. The future routing milestone requires a
separately designed Audio Server Driver Plug-in, dedicated code-signing and
installation path, privacy review, device recovery design, and broad hardware
testing.

## Verification strategy

Unit tests use a protocol-backed Core Audio facade and fakes. They cover device
classification, unavailable/writable control states, default-device mutations,
capability gating, permission-denied cleanup, gain/mute state, and idempotent
session teardown. No unit test accesses a real audio device or captures audio.

Manual verification runs on both macOS 13 and macOS 14.2+:

1. Device list, default input/output, volume, and mute changes update correctly
   and reflect external System Settings changes.
2. macOS 13/14.1 shows the app-mixer requirement without requesting permission.
3. macOS 14.2+ requests permission only after enable; denial leaves device
   controls usable.
4. With permission, two separate apps can be muted and have independent gain;
   closing the popover, changing output, revoking permission, and quitting all
   stop the session cleanly.
5. The pre-existing System tab, stats polling policy, and settings window retain
   their current behaviour.

## Acceptance criteria

This milestone is complete when a macOS 13 user can safely inspect/select
input/output devices and control available output master volume/mute from the
Audio tab; a macOS 14.2+ user can explicitly enable and later stop an on-device
application mixer; unsupported systems and controls state their limits clearly;
and termination/output-change/permission-loss paths tear down every temporary
audio object.
