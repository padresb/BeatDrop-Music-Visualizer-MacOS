# BeatDrop macOS port

## Current state

The existing application is Windows-only at the system boundary, but each dependency can be replaced on macOS:

- Rendering depends on Win32, Direct3D 9, and D3DX.
- System audio capture depends on WASAPI loopback APIs.
- Inter-app video output depends on Spout DX9.

The MilkDrop assets remain reusable on macOS:

- Presets: `.milk`
- Shaders: `.fx`
- Textures: `dds`, `tga`, `png`, `jpg`, `bmp`

What already works in this repo revision:

- native macOS app bundle bootstrap
- shared cross-platform core contracts
- live microphone PCM capture on macOS
- live system-output PCM capture on macOS
- known issue: after the new privacy-permission plumbing, system-output capture is the stable validation path while live microphone capture remains temporarily pinned due to an `AVAudioConverter` crash after permission grant
- libprojectM offscreen renderer integrated into the AppKit shell when the dependency is configured locally, with the native telemetry fallback retained for dependency-free builds
- the real preset render path now targets an explicit OpenGL framebuffer/texture pair shared by the AppKit preview and Syphon publisher, replacing the earlier pbuffer-only offscreen path
- shared preset session with rating-aware randomization, preset history, keyboard browsing, and drag/drop loading on macOS
- INI-backed `beatdrop.ini` import plus startup preset/session persistence on macOS
- native window startup restore for geometry, borderless, fullscreen, and always-on-top semantics
- responsive AppKit status layout that reflows shell cards and clips long runtime strings inside their panels
- PNG screenshot export from the live macOS renderer
- Syphon publisher wired to the live libprojectM render surface, with persistent enable/disable state and a keyboard toggle on macOS
- CoreAudio input/output device inventory and permission diagnostics
- local upstream dependency installs for `libprojectM 4.1.6` and `Syphon.framework`
- manual headless renderer smoke executable for local bring-up, with the note that full libprojectM runtime validation still requires a desktop GUI session because headless CLI processes do not get a valid CoreGraphics connection
- current renderer blocker: after loading the bundled preset library and switching presets, the app still stays on `FALLBACK LIVE`; the latest surfaced backend error is `Unable to allocate the offscreen framebuffer for libprojectM`

## Port strategy

The realistic path to feature parity is a subsystem replacement, not a compiler-flag migration.

1. Replace the window shell with Cocoa.
2. Replace the renderer with a macOS-native implementation that preserves MilkDrop preset behavior, using libprojectM first and keeping the shell renderer-agnostic for a future Metal path.
3. Replace WASAPI loopback/microphone capture with a CoreAudio capture pipeline.
4. Replace Spout output with Syphon on macOS.
5. Keep the preset and resource pipeline intact where possible.

## Milestones

1. Native bootstrap app
   Status: done in this repo revision.
   Result: the project now produces a runnable macOS `.app` bundle with a live status dashboard.

2. Renderer boundary extraction
   Status: in progress.
   Goal: isolate `vis_milk2` code that is purely preset/state logic from Direct3D-specific code, route live PCM into a renderer-neutral preset-engine contract, and keep the macOS fallback renderer swappable with libprojectM.
   Note: shared preset selection and session history have already been moved into the new core layer.

3. Audio boundary extraction
   Status: in progress.
   Goal: separate BeatDrop's beat-analysis path from WASAPI device enumeration and capture callbacks while extending the new macOS audio service from microphone capture to system-output capture.
   Note: the first working system-output path is `ScreenCaptureKit`; CoreAudio process taps remain a follow-up optimization, not the first implementation. Microphone permission prompting is wired, but the live microphone stream is currently pinned for follow-up hardening after a post-grant converter crash.

4. macOS renderer/audio implementation
   Status: in progress.
   Goal: feed real audio data into the new renderer path and validate baseline preset compatibility.
   Note: preset/session state and system-output PCM are live, but the real preset render path is still blocked on the first usable libprojectM offscreen frame; the latest in-app error is `Unable to allocate the offscreen framebuffer for libprojectM`.

5. Preset UX and persistence
   Status: in progress.
   Goal: restore high-value BeatDrop preset workflows on macOS, including browsing, drag/drop loading, startup preset behavior, and session persistence.
   Note: `beatdrop.ini` import, startup preset restore, last-session preset restore, and order-mode persistence are now wired through the shared core config layer.

6. Native macOS window semantics
   Status: in progress.
   Goal: restore high-value desktop behavior such as saved geometry, startup window mode, and always-on-top behavior.
   Note: the native shell now restores and persists window frame geometry plus the `bBorderlessOnStartup`, `bFullscreenOnStartup`, and `bAlwaysOnTop` config semantics.

7. Screenshot export
   Status: in progress.
   Goal: restore the BeatDrop screenshot workflow from the live macOS render path.
   Note: `Ctrl+X` and `Cmd+X` now save PNG captures under the user's Pictures folder with BeatDrop-style timestamped names.

8. Output integrations
   Status: in progress.
   Goal: add Syphon sender support and restore high-value BeatDrop workflows used with OBS, Resolume, and similar tools on macOS.
   Note: the macOS app now publishes the live libprojectM texture surface through Syphon when the backend is enabled; the remaining work is receiver-side validation and long-session tuning.
