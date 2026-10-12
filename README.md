# OpenDente

Battery charge limiter for macOS. Menu bar app - pick a target level (e.g. 80%), the system stops charging when it gets there.

Open-source alternative to AlDente, GPL-3 licensed. Based on [killerk3emstar/OpenDente](https://github.com/killerk3emstar/OpenDente). Built to stay out of the way: 2-second SMC poll, no animated UI in the background, no telemetry.

<p align="center">
  <img src="screenshots/popover.png" width="280" alt="Sailing mode">
  <img src="screenshots/popover-detailed.png" width="280" alt="Detailed view with full SMC and adapter info">
</p>

## Status

Beta. SMC charging control was originally tested on an M4 MacBook with macOS Tahoe (26). When macOS reports a supported native charge limit, OpenDente uses that system policy as the primary charging control, even if SMC charging keys are also available. SMC control is used on Macs without a compatible native limit backend.

SMC mode supports the older (`CH0B`/`CH0C`) and newer (`CHTE`) charging-control key sets. Native mode discovers the limits offered by macOS, applies a requested limit and checks the effective value. The UI follows changes made in System Settings as well.

SMC mode uses a privileged helper and restores temporary charging controls on quit, helper crash or watchdog timeout. Native mode changes a persistent system setting, which remains active during sleep and after quitting. You use it at your own risk. No warranty.

## Compared to AlDente

Core charging features overlap with what AlDente puts behind its Pro tier: charge limit, sailing mode, heat protection, force discharge, MagSafe LED control, sleep handling.

What's different here:

- Open source, GPL-3. No Pro tier, no paywalled features.
- No telemetry, no analytics, no automatic updates. Battery history and events stay local. The helper diagnostics can query GitHub release metadata to compare versions; they do not upload battery data or history.
- Fixed 2-second polling and no animated power-flow visualization - AlDente's drain on the battery itself was the original motivation to write this.
- English and Spanish UI, with an option to follow the system language. No calibration mode or fancy onboarding.

## Apple's native charge limit

OpenDente prefers `PowerUISmartChargeClient` in the private PowerUI framework when its runtime capabilities and methods report a compatible native charge-limit policy. The native backend needs no privileged helper. The UI offers only reported supported limits (80–100% in 5% steps on the tested Mac), adopts the effective system limit at startup, follows changes in System Settings, and reports failed writes or reads instead of claiming success. Discovering support does not overwrite the existing macOS limit with an old app preference.

Native mode delegates charging decisions to macOS. Charging can resume after the battery falls more than 5% below the limit, and macOS occasionally charges to 100% for state-of-charge calibration. A paused or charging status reflects battery telemetry, rather than assuming the requested limit has stopped the battery. The setting persists through sleep and app exit. Choose 100% to permit a full charge; other macOS charging policies can still affect timing.

Optimized Battery Charging can also be read and changed through macOS when the required methods are available. OpenDente verifies the effective setting after a change and reports errors or unsupported states. The optional monthly full-charge schedule uses macOS's separate temporary full-charge operation; it does not replace the saved limit with a permanent 100% setting.

Sailing mode, heat-protection pause, force discharge, the SMC top-up action, MagSafe LED and sleep-inhibition controls require the SMC backend. They are disabled while native policy is active without changing their saved preferences. OpenDente releases its own SMC charging controls when handing charging over to macOS. Native mode does not offer unsupported limits or an immediate charging-inhibit command. Since PowerUI is private, capability checks may reject future incompatible versions; monitoring remains available if charging control is unavailable.

## Features

- Native macOS charge limit as the primary control when supported; 20–100% with SMC control on other compatible Macs
- Native Optimized Battery Charging controls with effective-state verification
- Optional monthly full-charge schedule, disabled by default
- Separate Apple maximum-capacity and OpenDente full-capacity/design percentages
- English/Spanish localization, or follow the system language
- Local battery history and event log with configurable retention and local export
- Helper connection, installed version, compatibility, and release-comparison diagnostics
- SMC sailing mode - let the battery drain to a lower threshold before topping up, instead of trickle-charging at the cap
- SMC force discharge while plugged in
- SMC heat protection - pause charging above a configurable temperature
- SMC sleep handling - stop charging during sleep; optionally inhibit sleep until the limit is reached
- SMC MagSafe LED reflects actual charging state
- Per-event native notifications

## Monthly full charging

Enable the monthly schedule explicitly and choose the next date. When a charge is due, OpenDente waits for external power and compatible native temporary full-charge support. The app must be running to start and observe the cycle. Completion is recorded only when battery telemetry actually reports a full charge.

Before requesting the temporary override, OpenDente records the previous charge-limit and optimized-charging policy locally. It restores the policy after completion, cancellation, or interruption, respects changes made externally, and retries a pending restoration at the next launch. Unsupported or failed operations are shown as errors. A cycle is cancelled when power is disconnected or after 24 hours; this schedule is not a battery calibration mode.

## Local history and privacy

History records minute-level battery and charging data, plus daily health readings. The default retention is 30 days for minute samples, 90 days for events, and 366 days for health readings. Retention can be configured, and the settings provide local export and deletion controls. Events record charging requests and results, external policy changes, monthly-cycle progress, helper reconnections, and app sessions.

These records are stored on the Mac. OpenDente sends no telemetry or analytics and does not upload history, event logs, or preferences. Helper version diagnostics query the [official upstream GitHub releases](https://github.com/killerk3emstar/OpenDente/releases) and, when available, the release's `opendente-release.json` metadata. A tag alone does not prove the helper version. Missing metadata or an unavailable release is shown as unverifiable rather than claiming the installed helper is up to date. This lookup does not download or install an app or helper update.

## What it shows

Even if you don't care about charge limiting itself, the popover surfaces a fair amount of data read directly from the SMC and IORegistry that's otherwise awkward to get at:

- Real-time adapter power, system power draw, and battery charge/discharge wattage
- Battery temperature, cycle count, design and current capacity, full-capacity/design ratio
- macOS maximum capacity and battery condition when published by the system
- Adapter info: manufacturer, model, serial, rated wattage, voltage, current
- Decoded `NotChargingReason` when something pauses charging - so you can tell whether it's heat, sleep, the system limit, or OpenDente itself

If you've ever wanted to see exactly how many watts your charger is delivering vs. how much your machine is actually pulling, that view is there.

The capacity ratio is full charge capacity divided by design capacity; it is not the complete health assessment used by macOS. The two values are shown separately. Missing or invalid data is reported as unavailable, and estimated remaining capacity is labelled. Raw capacities can fall back to IORegistry without treating normalized IOPS percentages as mAh. Hardware charge percentage is decoded using key metadata, including the changed B0RM format in newer SMC firmware.

## Requirements

- macOS 14 (Sonoma) or newer
- Apple Silicon Mac
- Privileged helper approval for SMC charging control; native charging limits need no helper

## How it works

Battery state is read via IOKit and SMC. Charging uses the native macOS charge-limit service when supported, or a compatible SMC gate otherwise. SMC writes require root, so the app ships an XPC daemon (`com.opendente.helper`) installed via `SMAppService`. The native PowerUI backend runs in the main app as the ordinary user and verifies each change by reading the system policy back.

The relevant SMC keys differ between Apple Silicon generations:

- M1, M2, M3: `CH0B`, `CH0C` to gate charging; `CH0I` to force discharge
- Newer chips (≈2023+, macOS Sequoia and Tahoe): `CHTE`, `CHIE`

OpenDente probes the SMC keys and the native charge-limit backend at startup. A compatible native policy takes priority even when an SMC key set responds. Battery monitoring stays available when neither backend can control charging. The helper panel reports registration and connection separately and checks the version returned by the running helper against the app's required version.

In SMC mode, OpenDente actively flips the charge gate as the battery crosses the threshold. In native mode, macOS maintains the charge limit itself.

## Build

The Xcode project is generated by [XcodeGen](https://github.com/yonaskolb/XcodeGen):

```
brew install xcodegen
xcodegen generate
open OpenDente.xcodeproj
```

Configure `DEVELOPMENT_TEAM` in `project.yml` with your own signing team before building.

Use the same signing team for the app and helper. Installed helpers authenticate the app against an Apple-anchored signature and the helper's own Team ID, including Debug builds. Unsigned/ad-hoc test builds do not authorize privileged SMC writes. The native backend does not use this XPC authorization path. `CFBundleVersion` remains numeric; the source commit is recorded separately as `OpenDenteGitRevision`.

## Tests

```
xcodebuild -project OpenDente.xcodeproj -scheme OpenDente -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO test
```

The scheme runs app tests and a hostless helper test target. Tests cover charging transitions and asynchronous failures, capacity decoding and independent health sources, helper authentication/recovery and version diagnostics, reconnect backoff, login-item state, counted notification delivery, native policy application/readback, external changes, monthly scheduling and restoration, local history/events, localization, and native UI presentation. Hardware and system registration operations use mocks. XCTest hosts skip app services, and helper tests exclude its executable entry point. CI also builds Release to compile the production authentication path.

## Layout

```
OpenDente/         main app (SwiftUI menu bar)
OpenDenteHelper/   privileged XPC helper tool
Shared/            XPC protocol + shared constants
OpenDenteTests/    unit tests
OpenDenteHelperTests/ hostless privileged-helper tests
project.yml        XcodeGen config
```

## Acknowledgements

This project leans on prior reverse-engineering work, in particular:

- [mhaeuser/Battery-Toolkit](https://github.com/mhaeuser/Battery-Toolkit) - XPC architecture, helper installation patterns
- [beltex/SMCKit](https://github.com/beltex/SMCKit) - SMC struct definitions and IOKit selector usage
- [actuallymentor/battery](https://github.com/actuallymentor/battery) - practical SMC key reference across Apple Silicon generations
- [charlie0129/batt](https://github.com/charlie0129/batt) - Apple Silicon charging behavior

## License

GPL-3.0. See [LICENSE](LICENSE).
