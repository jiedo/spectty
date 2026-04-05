# Spectty Agent Context

This file captures the project-specific context that is worth keeping in
working memory for future tasks.

## Repo Shape

- Main app code lives in `Spectty/`.
- Core local packages:
  - `Packages/SpecttyTerminal`: terminal state, VT parser, key encoding.
  - `Packages/SpecttyUI`: Metal terminal view, renderer, gestures, SwiftUI bridge.
  - `Packages/SpecttyTransport`: SSH and Mosh transports.
  - `Packages/SpecttyKeychain`: credentials and key management.
- Main tests live in `SpecttyTests/`.

## Primary Runtime Path

For most terminal behavior, the main call chain is:

`SessionManager` -> `TerminalSession` -> `TerminalTransport` ->
`GhosttyTerminalEmulator` -> `TerminalView` / `TerminalMetalView`

Useful entry points:

- `Spectty/ViewModels/SessionManager.swift`
- `Spectty/Models/TerminalSession.swift`
- `Packages/SpecttyTransport/Sources/SpecttyTransport/TransportProtocol.swift`
- `Packages/SpecttyTerminal/Sources/SpecttyTerminal/GhosttyTerminalEmulator.swift`
- `Packages/SpecttyUI/Sources/SpecttyUI/TerminalView.swift`
- `Packages/SpecttyUI/Sources/SpecttyUI/TerminalMetalView.swift`
- `Packages/SpecttyUI/Sources/SpecttyUI/TerminalMetalRenderer.swift`

## UI / Rendering Notes

- `TerminalMetalView` is the critical terminal surface.
- `TerminalMetalRenderer` still does full-screen vertex rebuilding during
  active redraws. If active rendering is expensive, this file is the first
  place to inspect.
- `TerminalView` is only the SwiftUI wrapper. Most rendering/input behavior
  is below it in UIKit/Metal code.

## Input Bar / Keyboard Notes

- The iOS terminal helper keys now live in a persistent bottom bar owned by
  `TerminalMetalView`, not in `inputAccessoryView`.
- That bar must stay visible when the software keyboard is manually hidden so
  users can keep terminal control keys on screen while reclaiming space.
- The bar must be hidden when iOS expects hardware keyboard input.
- Current layout is two rows:
  `Esc`, `Tab`, `Ctrl`, `Shift`, arrow keys, plus `Del` (forward delete),
  `PgUp`, `PgDn`, and a software keyboard show/hide toggle.
- The terminal content/grid sizing in `TerminalMetalView` reserves space for
  this persistent bar, so future layout work should account for it before
  changing bottom insets or keyboard overlap handling.
- Main files for this behavior:
  `Packages/SpecttyUI/Sources/SpecttyUI/TerminalInputAccessory.swift`
  and `Packages/SpecttyUI/Sources/SpecttyUI/TerminalMetalView.swift`

## Power / Performance Context

The biggest confirmed power issue in this repo was idle terminal rendering.
It has already been changed from continuous `MTKView` rendering to
event-driven redraws.

Current behavior:

- Idle terminal sessions should not continuously render.
- Emulator content changes notify the view through
  `TerminalEmulator.onDisplayChange`.
- `TerminalMetalView` now redraws on demand and throttles content-driven
  redraws to 10 fps.
- Direct interaction paths such as explicit `setNeedsDisplay()` calls for
  scroll/selection still bypass that content throttle when needed.

Files involved in that change:

- `Packages/SpecttyTerminal/Sources/SpecttyTerminal/TerminalEmulator.swift`
- `Packages/SpecttyTerminal/Sources/SpecttyTerminal/GhosttyTerminalEmulator.swift`
- `Packages/SpecttyUI/Sources/SpecttyUI/TerminalMetalView.swift`

Observed result during real-device testing:

- Idle CPU dropped from about 10% to about 1%.
- CPU now rises mainly during active terminal output.

If a future task is about battery drain, first inspect whether someone
reintroduced continuous rendering or removed redraw throttling.

## Transport Notes

- SSH is the primary path to optimize unless the task explicitly mentions
  Mosh. The user stated they do not use Mosh for current power concerns.
- `SSHTransport` uses SwiftNIO and a keepalive loop.
- Mosh has its own heartbeat / roaming logic, but it is usually irrelevant
  unless the task specifically targets Mosh.

## Build / Verification

Project build command known to work:

```bash
env TMPDIR=/tmp SWIFTPM_ENABLE_PLUGINS=0 xcodebuild \
  -project Spectty.xcodeproj \
  -scheme Spectty \
  -destination 'generic/platform=iOS' \
  -derivedDataPath /tmp/SpecttyDerivedData \
  -clonedSourcePackagesDirPath /tmp/SpecttySourcePackages \
  build
```

For quick performance verification on device, focus on:

- idle CPU in Xcode Debug Navigator
- `Time Profiler`
- `Metal System Trace`

Expected idle result after the rendering fix:

- very low CPU
- no continuous 60 fps Metal submission while the terminal is idle

## Working Rules Specific To This Repo

- There may be unrelated local changes in `Info.plist` or
  `Spectty.xcodeproj/project.pbxproj`. Do not revert or include them unless
  the task actually requires it.
- When committing, prefer staging only the files relevant to the task.
- If a task touches terminal responsiveness, check whether the 10 fps redraw
  throttle should stay in place or be adjusted.
