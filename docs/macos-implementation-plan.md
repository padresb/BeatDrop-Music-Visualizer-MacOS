# BeatDrop macOS implementation plan

## Objective

Ship a fully functional macOS version of BeatDrop that preserves the product value of the current Windows build:

- MilkDrop preset compatibility
- strong beat reaction
- speaker and microphone capture modes
- preset browsing, drag/drop, randomization, ratings, and startup behavior
- borderless / fullscreen window modes
- screenshot export
- external video output for live workflows

## Execution status

- Phase 0 is ready: the replacement program and delivery phases are now fixed in code and docs.
- Phase 1 is ready: a shared `core/` module owns the cross-platform contracts and project-status model.
- Phase 2 is ready: the macOS app now produces live microphone and system-output PCM through the shared audio service and ring buffer.
- Phase 3 is active again: preset/session state, system-output PCM, and the real libprojectM renderer are live, but preset responsiveness is inconsistent across the `.milk` corpus and needs better diagnostics.
- Phase 6 is implemented but not the active bottleneck: the Syphon publisher is wired to the renderer surface, and the main remaining work is receiver validation plus long-session tuning.

## Recommendation

Do not line-by-line port the Win32 + Direct3D 9 code.

The current Windows implementation is deeply coupled to obsolete or Windows-only APIs:

- [vis_milk2/plugin.cpp](/Users/bretpadres/Documents/projects/BeatDrop-Music-Visualizer/vis_milk2/plugin.cpp)
- [vis_milk2/pluginshell.cpp](/Users/bretpadres/Documents/projects/BeatDrop-Music-Visualizer/vis_milk2/pluginshell.cpp)
- [vis_milk2/Milkdrop2PcmVisualizer.cpp](/Users/bretpadres/Documents/projects/BeatDrop-Music-Visualizer/vis_milk2/Milkdrop2PcmVisualizer.cpp)
- [audio/loopback-capture.cpp](/Users/bretpadres/Documents/projects/BeatDrop-Music-Visualizer/audio/loopback-capture.cpp)
- [audio/audiodevicehandler.cpp](/Users/bretpadres/Documents/projects/BeatDrop-Music-Visualizer/audio/audiodevicehandler.cpp)

`plugin.cpp` alone is about 12k lines and mixes renderer logic, preset state, window/input behavior, shader compilation, file IO, and feature toggles. Directly translating that to Cocoa + Metal is the slowest and highest-risk route.

Recommended path:

1. Freeze the Windows code as the behavior reference.
2. Build a new native macOS app shell.
3. Reuse portable logic where it is genuinely portable.
4. Replace Windows-only subsystems with macOS-native ones.
5. Use a maintained MilkDrop-compatible rendering core as the shortest path to parity.

## Target architecture

### 1. App shell

Use:

- AppKit for the main application shell, menus, hotkeys, window modes, drag/drop, and preference panels
- Objective-C++ for the shell-to-core boundary
- C++17 for shared engine logic

Why:

- Objective-C++ is the lowest-friction bridge to the existing C++ code.
- AppKit is the most predictable route for real-time desktop apps with custom windows and keyboard handling.
- SwiftUI can be introduced later for settings screens, but should not be the first dependency for the render loop.

### 2. Rendering core

Recommended primary route:

- Build the macOS app around a forked `libprojectM`-based core and extend it with BeatDrop-specific behavior.

Why this is the right default:

- `projectM` is current, official, and MilkDrop-compatible.
- It already handles MilkDrop parsing, audio analysis, and rendering.
- It already runs on macOS.
- It avoids rewriting the full D3D9 + D3DX shader pipeline from scratch.

What this means in practice:

- Use libprojectM as the rendering/preset execution base.
- Create a `BeatDropCore` adapter/fork layer for BeatDrop-specific additions:
  - waveform and shape limits
  - startup behavior and preset history
  - hard cut / transition logic
  - screen-dependent mode
  - preset patch overrides
  - texture and resource lookup rules
  - BeatDrop-specific configuration semantics

Renderer implementation detail:

- First shipping version should use OpenGL via libprojectM on macOS.
- Keep the app shell renderer-agnostic so a future Metal renderer remains possible.

Why not force Metal immediately:

- The current BeatDrop renderer depends on D3D shader compilation and D3DX utility behavior.
- A direct HLSL-to-Metal reimplementation adds major complexity before any visible parity is delivered.
- OpenGL on macOS is deprecated, but still usable for a desktop visualizer and is already the backend libprojectM provides.

### 3. Audio capture

Use a dual-backend audio capture layer:

- System output capture:
  - first shipping backend: ScreenCaptureKit audio capture
  - later optimization path: CoreAudio process taps / aggregate device path on macOS 14.4+
- Microphone capture:
  - AVAudioEngine or AUHAL/CoreAudio path

Normalize all capture modes into a common PCM ring buffer:

- float stereo frames
- fixed internal sample rate
- consistent channel mapping
- latency tracking

### 4. External video output

Replace Spout with Syphon:

- first shipping output path: Syphon server
- keep a small abstraction so NDI can be added later if needed

### 5. Config and persistence

Do not keep Win32 INI calls in the app layer.

Use:

- native app preferences storage for runtime settings
- a migration importer for `beatdrop.ini`, `beatdrop_img.ini`, and `beatdrop_msg.ini`
- a portable config model in C++ so Windows and macOS settings can stay aligned conceptually

### 6. Resources

Preserve and reuse:

- `resources/Milkdrop2/presets`
- `resources/Milkdrop2/textures`
- `resources/Milkdrop2/data`

Bundle them for macOS app distribution, but keep user-overridable preset folders outside the bundle.

## Major replacement areas and exact solution

### Replacement area 1: Direct3D 9 and D3DX are not portable

Problem:

- The current renderer assumes `IDirect3DDevice9Ex`, D3DX font/texture helpers, HLSL compile paths, and Win32 presentation modes.

Solution:

- Stop trying to port the D3D9 renderer.
- Replace the renderer with a `BeatDropCore` abstraction:
  - `PresetEngine`
  - `AudioFeatures`
  - `RenderSurface`
  - `OutputPublisher`
- Use libprojectM as the concrete macOS render engine first.

Exit criteria:

- The render loop produces visuals from the bundled preset library on macOS.
- The app can switch presets, randomize presets, and react to live audio.

### Replacement area 2: WASAPI loopback does not exist on macOS

Problem:

- The current audio path is tightly tied to `IMMDevice`, `IAudioClient`, and loopback capture behavior.

Solution:

- Build a new `AudioCaptureService` with two backends:
  - `SystemAudioCaptureCoreAudioTap`
  - `SystemAudioCaptureScreenCaptureKit`
- Build a separate `MicrophoneCapture` backend.
- Feed both through the same resampler/downmixer and beat-analysis input.

Implementation detail:

- Preserve BeatDrop's preferred sample-rate behavior by resampling down to the engine's expected analysis rate instead of assuming the hardware rate.

Exit criteria:

- Default system audio capture works on supported macOS versions.
- Microphone mode works and can be toggled live.
- Device changes do not require app restart.

### Replacement area 3: Spout is Windows-only

Problem:

- Spout DX9 output is a core workflow feature for VJ / OBS / Resolume users on Windows.

Solution:

- Replace it with `SyphonOutputPublisher`.
- Publish the live render surface as a Syphon server.
- Match the UX semantics of the current Spout toggle where possible.

Exit criteria:

- A Syphon-capable receiver can subscribe to BeatDrop output live.
- Output resizing and window resizing do not break the published stream.

### Replacement area 4: Win32 windowing and input are mixed into core logic

Problem:

- Window styles, borderless behavior, key handling, help overlay, and fullscreen logic are mixed into the existing render entry point.

Solution:

- Move all app behavior to a `BeatDropMacApp` layer:
  - `MainWindowController`
  - `RenderView`
  - `HotkeyRouter`
  - `OverlayController`
  - `PreferencesController`
- Keep only platform-neutral state transitions in the core.

Exit criteria:

- Borderless window mode works.
- Fullscreen works.
- Drag and drop preset loading works.
- Keyboard controls match the documented behavior.

### Replacement area 5: Full preset compatibility is bigger than rendering alone

Problem:

- BeatDrop behavior includes more than preset loading:
  - patched presets
  - custom resource rules
  - randomization logic
  - transition behavior
  - screenshot support
  - feature flags

Solution:

- Treat preset compatibility as a tracked compatibility program, not as a yes/no claim.
- Build a visual regression suite over a curated preset corpus:
  - original MilkDrop presets
  - BeatDrop-patched presets
  - difficult shader-heavy presets
  - custom shape / wave heavy presets

Exit criteria:

- The compatibility suite passes a defined threshold.
- Known-incompatible presets are documented and tracked explicitly.

## Delivery plan

### Phase 0: Baseline and architecture freeze

Duration:

- 3 to 5 days

Tasks:

- Freeze the Windows build as the behavioral baseline.
- Enumerate all user-facing features from README, code, and config.
- Build a feature matrix:
  - must match for v1
  - can ship later
  - mac-only enhancements
- Decide minimum supported macOS version.

Recommendation:

- Target macOS 14.4+ for first full release because system audio capture is materially simpler with the newer CoreAudio tap APIs.
- Consider a degraded fallback path for macOS 13.x only if required by product goals.

Deliverables:

- feature matrix
- supported OS matrix
- parity checklist

### Phase 1: New project structure

Duration:

- 4 to 7 days

Tasks:

- Create new folders:
  - `core/`
  - `mac_app/`
  - `tests/`
  - `third_party/` or dependency bootstrap
- Keep `vis_milk2/` as the Windows reference implementation.
- Define clean interfaces:
  - audio input
  - preset library
  - renderer
  - publisher
  - config store
- Add CI for macOS build and unit tests.

Deliverables:

- builds on macOS
- unit test harness
- stable app skeleton

### Phase 2: Audio subsystem

Duration:

- 1 to 2 weeks

Tasks:

- Implement macOS system-output capture.
- Implement microphone capture.
- Add device enumeration and hot switching.
- Build resampling, buffering, silence handling, and underrun logging.
- Reproduce BeatDrop sensitivity and reaction tuning.

Deliverables:

- PCM capture running in real time
- latency measurements
- audio debug overlay

Acceptance:

- Visual debug graphs track audio reliably.
- Switching default output devices does not crash or stall capture.

Current repo status:

- device enumeration is implemented for both input and output devices
- microphone permission state is reported live
- microphone PCM capture is running through `AVAudioEngine` into a shared stereo ring buffer
- system-output PCM capture is running through `ScreenCaptureKit`
- known issue: the microphone permission flow is now wired into the macOS bundle, but the live microphone stream is temporarily pinned for follow-up hardening because an `AVAudioConverter` path can crash after permission grant; system-output capture is the stable runtime path for current testing
- the shared runtime coordinator drains live PCM into the preset-engine boundary
- the libprojectM offscreen path now renders into an OpenGL framebuffer-backed texture shared by the AppKit preview and Syphon publisher, replacing the earlier pbuffer-only render target
- the macOS app exposes a preset-library status card and a real offscreen libprojectM renderer path inside the existing AppKit shell, while retaining the telemetry fallback when the dependency is unavailable
- current renderer blocker: loading the bundled preset folder now reaches `RENDERER LIVE`, but some presets remain visually static or non-reactive even while render/audio telemetry keeps advancing
- the macOS app now publishes the live OpenGL render texture through Syphon when output is enabled, with persistent state stored in the shared config
- shared preset session logic now scans `.milk` libraries, parses `fRating`, supports next/previous/random navigation, and preserves random-mode history
- the macOS app now maps keyboard preset browsing and drag/drop preset loading onto that shared session
- the macOS app now imports `resources/beatdrop.ini`, restores the startup preset or random-start behavior, and persists the last active library, preset, and order mode into Application Support
- the native window shell now restores frame geometry, always-on-top, borderless startup, and fullscreen startup semantics from the shared config store
- the AppKit dashboard now lays out its shell cards responsively and clips long runtime strings so the status UI remains readable across window sizes
- the macOS shell now saves PNG screenshots of the live renderer to the user's Pictures folder using BeatDrop-style timestamped filenames
- the local development machine now has libprojectM 4.1.6 installed under `third_party/install/projectm` and Syphon.framework installed under `third_party/install/syphon/Frameworks`
- deviation from the earlier draft: `ScreenCaptureKit` shipped before CoreAudio process taps because it produced a working macOS-native stream faster with less platform plumbing
- deviation from the renderer draft: the first concrete libprojectM path uses an offscreen OpenGL drawable inside the existing AppKit shell rather than immediately swapping the UI over to a dedicated OpenGL view, because libprojectM's final pass renders to the default framebuffer and this preserves the shell work already landed
- deviation from the dependency draft: rather than using Homebrew's outdated `projectM` package, the repo now builds the current upstream `projectM` release from source locally and uses the official Syphon framework project directly
- deviation from the renderer implementation draft: the offscreen libprojectM target now uses an explicit OpenGL framebuffer/texture pair rather than a CGL pbuffer, so the same render surface can be read back for AppKit and published to Syphon more predictably
- deviation from the phase tracker: Phase 3 remains active because renderer bootstrap is no longer the blocker; preset compatibility and runtime diagnostics are now the limiting work even though preset session state, audio dispatch, and renderer dependency setup are all in place
- deviation from the phase ordering draft: shared preset browsing and drag/drop started before the concrete libprojectM adapter because they are portable parity work and unblock real user workflows immediately
- deviation from the persistence draft: the macOS app now uses a portable INI-backed config store in Application Support before a native preferences UI exists, because that restores real BeatDrop startup semantics immediately and keeps the config model shareable with Windows
- deviation from the windowing draft: startup window semantics landed before a dedicated macOS preferences screen because the INI model already exposed them and they are low-risk parity work
- deviation from the output draft: screenshot export landed before Syphon because it reuses the live AppKit renderer immediately and proves the native frame path can be serialized without waiting on an external framework
- deviation from the output draft: the first Syphon path publishes the renderer-owned OpenGL texture directly from the existing offscreen libprojectM context instead of adding a second render pass or a dedicated output-only context
- deviation from the validation draft: a headless CLI smoke executable now exists for the renderer, but the current agent session cannot fully initialize offscreen libprojectM because CoreGraphics rejects OpenGL context creation without a GUI connection
- preset-level compatibility debugging for non-responsive `.milk` files, microphone stream hardening after the post-grant `AVAudioConverter` crash, hot switching, latency reporting, reaction tuning, the optional process-tap backend, Syphon receiver validation, and GUI-session renderer validation are still outstanding

### Phase 3: Render engine integration

Duration:

- 1 to 2 weeks

Tasks:

- Integrate libprojectM into the mac app.
- Load BeatDrop preset and texture directories.
- Render to an embeddable view.
- Wire audio input into the renderer.
- Implement preset switching and randomization.

Deliverables:

- first end-to-end reactive visualizer

Acceptance:

- bundled presets render and react to live audio
- app remains stable for long-running sessions

### Phase 4: BeatDrop feature port

Duration:

- 2 to 4 weeks

Tasks:

- Port BeatDrop-specific behavior into `BeatDropCore` or a libprojectM fork:
  - hard cut modes
  - transition timing
  - startup preset
  - preset history
  - random/sequential modes
  - rating support
  - waveform/shape behavior expected from BeatDrop
  - screen-dependent rendering mode
  - screenshot export
- Import configuration semantics from current INI files.

Deliverables:

- parity-focused feature set

Acceptance:

- operator-facing controls behave like the Windows app
- settings persist across launches

### Phase 5: Native macOS UX

Duration:

- 1 to 2 weeks

Tasks:

- Implement:
  - Preferences window
  - help/hotkey overlay
  - borderless mode
  - fullscreen mode
  - drag/drop preset loading
  - preset browser
  - startup launch state restoration
- Add correct permission flows and explanatory dialogs for audio capture.

Deliverables:

- native-feeling desktop app

Acceptance:

- the app is usable without the terminal
- permissions failures are understandable and recoverable

### Phase 6: Syphon output

Duration:

- 3 to 5 days

Tasks:

- Integrate Syphon server publishing.
- Publish the render output at the chosen output resolution.
- Add live enable/disable toggle.
- Handle resize/recreate correctly.

Deliverables:

- Syphon-ready output

Acceptance:

- OBS/Resolume/VDMX/Syphon test receiver can consume the stream live

### Phase 7: Compatibility and performance hardening

Duration:

- 1 to 2 weeks

Tasks:

- Build a curated preset regression pack.
- Create deterministic offline audio fixtures.
- Add screenshot-based visual comparisons.
- Profile CPU, GPU, memory, and audio latency.
- Add shader/preset caching if needed by the chosen render path.

Deliverables:

- compatibility report
- performance report
- bug burn-down list

Acceptance:

- long session stability
- no major audio dropouts
- acceptable startup and preset switch latency

### Phase 8: Packaging and release

Duration:

- 3 to 5 days

Tasks:

- bundle presets/textures
- app signing and notarization
- Info.plist privacy strings
- release packaging
- migration notes for existing BeatDrop users

Deliverables:

- distributable `.app` and release artifact

## Suggested repository layout after rewrite

```text
core/
  audio/
  config/
  engine/
  presets/
  output/
mac_app/
  app/
  ui/
  audio/
  output/
  resources/
tests/
  unit/
  integration/
  visual-regression/
vis_milk2/
  # Windows reference implementation, no longer the source of truth for macOS
```

## What to preserve from the current repo

Preserve:

- preset library and textures
- projectM-eval dependency
- BeatDrop feature semantics where they are platform-neutral
- current README feature set as the parity target

Do not preserve as implementation dependencies:

- D3D9/D3DX abstractions
- Win32 INI and shell APIs
- WASAPI capture code
- Spout DX9 code

## Engineering rules for execution

1. Every feature port starts with a Windows behavior note and a macOS acceptance test.
2. New code goes into new modules; avoid adding more logic to `vis_milk2/`.
3. Keep platform-specific code behind interfaces.
4. Use curated preset fixtures for regressions.
5. Do not claim preset parity without automated evidence.

## Risks

### Risk: libprojectM does not match BeatDrop closely enough

Mitigation:

- Keep the render layer abstract.
- Maintain a BeatDrop fork if needed.
- Track specific incompatibilities as test cases.

### Risk: system audio capture permissions are brittle across macOS versions

Mitigation:

- Prefer macOS 14.4+ for first supported release.
- Keep ScreenCaptureKit fallback isolated.
- Build a permissions diagnostics view into the app.

### Risk: OpenGL backend performance or compatibility is insufficient

Mitigation:

- Structure renderer ownership so a future Metal backend can replace libprojectM rendering without replacing the whole app.
- Do not entangle app logic with GL details.

### Risk: licensing constraints from third-party dependencies

Mitigation:

- Review libprojectM license obligations before distribution.
- Avoid adopting a GPL frontend as a base app.
- Prefer linking to libprojectM as a library, not inheriting a frontend wholesale.

## Recommended order of execution

1. Lock the target OS/version and feature matrix.
2. Build the new app shell and clean interfaces.
3. Solve audio capture first.
4. Integrate libprojectM and get live rendering.
5. Add Syphon.
6. Port BeatDrop-specific behaviors one by one with tests.
7. Harden performance and compatibility.
8. Package, sign, notarize, release.

## Current implementation start

Implemented in this repo revision:

- `core/` library with initial interfaces for audio capture, preset engine, output publishing, and config storage
- project status model that tracks resource inventory, replacement areas, and delivery phases
- macOS app linked through the shared core instead of a shell-local status model
- smoke test target that compiles against the new contracts
- macOS audio service that reports microphone permission, CoreAudio input/output devices, and the system-audio backend path selected by the current OS version
- live microphone capture backed by `AVAudioEngine`, resampled into a shared stereo PCM ring buffer
- live system-output capture backed by `ScreenCaptureKit`
- shared runtime coordinator that dispatches buffered PCM into the preset-engine contract
- native fallback preset engine that loads the preset library, derives waveform/energy telemetry from live PCM, and feeds an audio-reactive AppKit visualizer
- automatic libprojectM package detection in the macOS build so the preferred backend can be enabled as soon as the dependency exists locally
- concrete offscreen libprojectM renderer integration inside `MacPresetEngine`, with live preset loading, audio ingestion, and frame capture into the existing AppKit shell
- concrete Syphon publisher integration on top of the live renderer-owned OpenGL texture, with persistent enable/disable state in the macOS shell
- shared preset session in `core/` that scans preset libraries, parses `fRating`, supports sequential/random order, and preserves preset history
- macOS keyboard controls for next/previous/random preset selection and drag/drop loading of `.milk` files or preset folders
- bootstrap UI cards that show live capture readiness, buffered audio depth, and renderer telemetry
- manual `beatdrop_macos_projectm_smoke` executable for renderer bring-up outside the GUI app

Next implementation slice:

- persist startup preset / order mode / last library root so the mac app starts with real BeatDrop session state
- add audio hot switching, latency metrics, and capture telemetry
- decide whether CoreAudio process taps are still worth adding after the renderer is online
- validate Syphon publishing with real receivers and tune the runtime detail surfaced in the macOS shell
- tune the libprojectM path against BeatDrop behavior gaps and validate it from a real GUI session

## Success definition

The macOS port is done when all of the following are true:

- It launches as a normal macOS app.
- It reacts to both system audio and microphone input.
- It renders bundled MilkDrop presets reliably.
- It supports the core BeatDrop operator workflow and hotkeys.
- It can publish live output to other macOS visual tools.
- It survives long-running sessions without audio stalls or renderer resets.

## External references used for stack decisions

- Apple ScreenCaptureKit WWDC session showing `SCStreamConfiguration.capturesAudio`:
  https://developer.apple.com/videos/play/wwdc2022/10155/
- Apple CoreAudio `AudioHardwareSystem` docs showing process tap support:
  https://developer.apple.com/documentation/coreaudio/audiohardwaresystem
- Apple AVFoundation capture overview:
  https://developer.apple.com/documentation/avfoundation/audio-and-video-capture
- Official `projectM` repository:
  https://github.com/projectM-visualizer/projectm
- Official `projectM` SDL frontend repository:
  https://github.com/projectM-visualizer/frontend-sdl-cpp
- Official Syphon framework repository:
  https://github.com/Syphon/Syphon-Framework
- AudioCap sample documenting macOS 14.4+ process tap setup:
  https://github.com/insidegui/AudioCap
