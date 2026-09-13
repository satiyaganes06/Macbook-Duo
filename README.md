<p align="center">
<img src="https://github.com/satiyaganes06/Macbook-Duo/Resources/AppIcon.png" width = "306"  class="center">
</p>
<h1 align="center">lastPiece : M-Commerce App</h1>

# MacBook Duo

A native Swift + Metal + ScreenCaptureKit menu bar app that makes your desktop follow
your MacBook lid. As you close the lid, the built-in display is captured and rendered
as a rigid pane that rotates around the hinge, expands, blurs and dims until it
disappears into the hinge. Stop the lid and the effect holds; open it and the effect
reverses back to the sharp desktop.

Desktop frames never leave this Mac: the latest captured frame lives in GPU memory only.
Nothing is written to disk, uploaded, or analyzed.

## Requirements

- Apple silicon MacBook with the continuous lid-angle sensor. Macs that only expose an open/closed switch run in
  manual mode (the preview still works, automatic lid-following is disabled).
- macOS 13 or newer, Xcode 16 or newer to build.
- Screen Recording permission (requested on first launch).

## Build and run

```bash
scripts/build-app.sh
open "build/MacBook Duo.app"
```

To package a drag-to-install disk image (`build/MacBook-Duo-<version>.dmg`, with an
Applications shortcut inside):

```bash
scripts/build-dmg.sh
```

The script signs with your Apple Development identity when one is present. Keep the
same identity between rebuilds, otherwise macOS forgets the Screen Recording grant.

Unit tests cover the geometry, progress mapping, sensor filter, reference tracking and
the Metal pipeline (rendered headlessly and read back):

```bash
swift test
```

### If only Fade works after a rebuild

macOS ties the Screen Recording grant to the app's signature. With ad-hoc signing
that is the code hash, which changes every build, so the grant silently disappears
and the capture-based styles stop arming (the menu shows "Screen Recording permission
needed"). Create a stable local identity once:

```bash
scripts/make-signing-identity.sh
```

Then rebuild, re-enable *MacBook Duo* under *System Settings > Privacy & Security >
Screen & System Audio Recording* one last time, and relaunch. Later rebuilds keep
the grant. A valid Apple Development certificate does the same and is preferred
automatically when present.

### If the app does not appear in the menu bar

- **Revoked or missing Apple Development certificate.** The build script checks each
  identity with `spctl` and falls back to ad-hoc signing. An ad-hoc app is held by
  Gatekeeper on first launch (`syspolicyd` logs "Code did not match any currently
  allowed policy") until you approve it in *System Settings > Privacy & Security*, and
  it needs re-approval after every rebuild. The durable fix is a fresh certificate:
  *Xcode > Settings > Accounts > Manage Certificates > + > Apple Development*, then
  rebuild.
- **Launching from a terminal or IDE.** That process needs *Developer Tools*
  permission (*Privacy & Security > Developer Tools*) to run locally built apps.
- **Diagnostics.** `DUO_DEBUG=1 "build/MacBook Duo.app/Contents/MacOS/MacbookDuo"`
  prints sensor, permission and state changes to stderr. Lifecycle events also go to
  the unified log under subsystem `com.satiyaganes.MacbookDuo`
  (`/usr/bin/log stream --predicate 'subsystem == "com.satiyaganes.MacbookDuo"'`).
- **Metal toolchain.** If `xcrun metal` is missing, shaders compile at launch from the
  bundled source. `xcodebuild -downloadComponent MetalToolchain` enables precompiling.

## Using it

The app lives in the menu bar (laptop icon). The menu shows the live lid angle, the
resting angle it calibrated against, and the current state.

- **Enabled** turns lid-following on or off.
- **Effect** picks one of the styles below. With *Reduce Motion* enabled in
  Accessibility settings, *Fade* is used automatically.

| Style | What you see |
| --- | --- |
| **Duo** (default) | The desktop tilts around the hinge, expands toward you, softens and disappears. |
| **Shutter** | Six rigid panels slide down behind one another, with overlapping edges and contact shadows, until the stack rests on the hinge. |
| **Iris** | Eight dark blades close around the desktop with a restrained 35° mechanical twist, bevelled edges and seams. |
| **Roll** | A roller rises from the hinge and the desktop winds down onto it like a retracting projector screen, shaded as a cylinder. |
| **Accordion** | The desktop pleats into horizontal folds that collapse toward the hinge, faces alternating light and dark with crease shadows. |
| **Fade** | A plain black veil. Needs no screen capture. |

Every style renders the desktop pixel-for-pixel at rest, so the overlay never pops
when it appears, and every style ends black so the display sleeps on a blank frame.
- **Preview Effect** plays the whole close-and-reopen arc without touching the lid.
- **Use Current Angle as Resting Position** re-calibrates immediately. The app also
  re-baselines on its own after the lid has been parked at a new angle for 20 seconds.
- **Emergency Stop** (`⌃⌥⌘F`, works system-wide) removes the overlay instantly and
  pauses the effect until you press it again or choose *Resume*.

## How it works

```
Lid sensor (IOKit HID feature report, polled 30-120 Hz)
    -> ReferenceAngleTracker   resting angle, re-baseline
    -> LidProgressModel        movement beyond dead zone -> progress (ease-out)
    -> CriticallyDampedFilter  smooth whole-degree reports, no overshoot
    -> EffectCurves            tilt / blur level / brightness
ScreenCaptureKit (own process excluded, overlay window sharingType = none)
    -> FrameStore              one IOSurface-backed frame, wrapped as a Metal texture
    -> FoldRenderer            blur pyramid (4 levels) + projective fold composite
    -> OverlayWindow           borderless, click-through, built-in display only
```

`EffectEngine` owns the state machine: `idle -> arming (capture starting) -> ready
(capture running, overlay hidden) -> active (overlay rendering)`. Capture starts on
the first degree of closing motion and stops two seconds after the effect clears.
Any failure (sensor timeout, capture error, permission revoked, display change)
tears the overlay down and restores the desktop.

The fold geometry is documented in `Sources/DuoCore/Model/FoldGeometry.swift` and
mirrored one-to-one in `foldVertex` in `Shaders.metal`.

## Layout

```
Sources/DuoCore/
  Model/      LidProgressModel, EffectCurves, FoldGeometry, CriticallyDampedFilter, ReferenceAngleTracker
  Sensor/     LidAngleSensor (IOKit HID)
  Capture/    ScreenCaptureManager, FrameStore
  Renderer/   FoldRenderer (+ BlurPyramid), OverlayWindow, BuiltInDisplay, ShaderLibrary
  Engine/     EffectEngine (state machine, render loop, preview)
  Shaders/    Shaders.metal
Sources/MacbookDuo/   main, AppDelegate, MenuBarController, HotKey
Tests/DuoCoreTests/   geometry, progress, filter and tracker tests
scripts/build-app.sh  builds, bundles, compiles shaders, signs
```
