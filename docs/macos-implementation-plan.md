# BeatDrop macOS implementation plan

> Architecture decisions and replacement strategy for the macOS port.
> For current status, see [macos-port.md](macos-port.md).

## Objective

Ship a fully functional macOS version of BeatDrop that preserves the product value of the current Windows build:

- MilkDrop preset compatibility
- strong beat reaction
- speaker and microphone capture modes
- preset browsing, drag/drop, randomization, ratings, and startup behavior
- borderless / fullscreen window modes
- screenshot export
- external video output for live workflows

## Recommendation

Do not line-by-line port the Win32 + Direct3D 9 code.

The current Windows implementation is deeply coupled to obsolete or Windows-only APIs. `plugin.cpp` alone is ~12k lines mixing renderer logic, preset state, window/input behavior, shader compilation, file IO, and feature toggles. Direct translation to Cocoa + Metal is the slowest and highest-risk route.

Instead:

1. Freeze the Windows code as the behavior reference.
2. Build a new native macOS app shell.
3. Reuse portable logic where it is genuinely portable.
4. Replace Windows-only subsystems with macOS-native ones.
5. Use a maintained MilkDrop-compatible rendering core as the shortest path to parity.

## Target architecture

### 1. App shell

- AppKit for the main application shell, menus, hotkeys, window modes, drag/drop, and preference panels
- Objective-C++ for the shell-to-core boundary
- C++17 for shared engine logic

Why: Objective-C++ is the lowest-friction bridge to the existing C++ code. AppKit is the most predictable route for real-time desktop apps with custom windows and keyboard handling.

### 2. Rendering core

Build the macOS app around `libprojectM` and extend it with BeatDrop-specific behavior.

Why:
- projectM is current, official, and MilkDrop-compatible
- It already handles MilkDrop parsing, audio analysis, and rendering
- It already runs on macOS
- It avoids rewriting the full D3D9 + D3DX shader pipeline

First shipping version uses OpenGL via libprojectM. The app shell stays renderer-agnostic so a future Metal path remains possible. OpenGL on macOS is deprecated but functional for a desktop visualizer.

### 3. Audio capture

Dual-backend audio capture:

- **System output:** ScreenCaptureKit (macOS 13+) as the primary backend; CoreAudio process taps (macOS 14.4+) as a future lower-overhead option
- **Microphone:** AVAudioEngine

All capture modes normalize into a common PCM ring buffer: float stereo frames, fixed internal sample rate, consistent channel mapping.

### 4. External video output

Syphon replaces Spout. The live render surface is published as a Syphon server. A small abstraction keeps NDI addable later.

### 5. Config and persistence

INI-backed config store in `~/Library/Application Support/BeatDrop Mac/` using a portable C++ model. Imports `beatdrop.ini` from the Windows resource layout. Native preferences UI deferred until after core parity.

### 6. Resources

Preserved and reused from Windows:

- `resources/Milkdrop2/presets`
- `resources/Milkdrop2/textures`
- `resources/Milkdrop2/data`

Bundled for macOS app distribution with user-overridable preset folders outside the bundle.

## Major replacement areas

### 1. Direct3D 9 → libprojectM (OpenGL)

The current renderer assumes `IDirect3DDevice9Ex`, D3DX helpers, HLSL compile paths, and Win32 presentation modes. Replaced with a `MacPresetEngine` wrapping libprojectM's offscreen OpenGL rendering into an explicit framebuffer/texture pair shared by AppKit and Syphon.

### 2. WASAPI loopback → ScreenCaptureKit / AVAudioEngine

WASAPI loopback and `IMMDevice` do not exist on macOS. Replaced with `MacAudioCaptureService` providing ScreenCaptureKit system-output capture and AVAudioEngine microphone capture, both feeding through a shared resampler/downmixer into the engine's PCM ring buffer.

### 3. Spout → Syphon

Spout DX9 output replaced with `MacSyphonOutputPublisher`. Publishes the renderer-owned OpenGL texture directly.

### 4. Win32 windowing → AppKit

Window styles, borderless behavior, key handling, and fullscreen logic moved from the render entry point to a native AppKit layer in `main.mm`.

## Repository layout

```text
core/                  # Cross-platform contracts and shared logic
  include/beatdrop/core/
  src/
macos/                 # macOS-specific app and subsystem implementations
  src/
third_party/
  projectm/            # BeatDrop-carried libprojectM source (vendored)
  Syphon-Framework/    # Syphon framework source
  install/             # Local dependency installs
vis_milk2/             # Windows reference implementation (frozen)
resources/             # Shared presets, textures, data
docs/                  # This file, port status
```

## Risks

### libprojectM does not match BeatDrop closely enough
Mitigation: Keep the render layer abstract. Maintain a BeatDrop fork. Track incompatibilities as test cases.

### System audio capture permissions are brittle across macOS versions
Mitigation: Target macOS 13+ minimum. Keep ScreenCaptureKit backend isolated. Build permission diagnostics into the app.

### OpenGL backend performance or compatibility is insufficient
Mitigation: Structure renderer ownership so a future Metal backend can replace libprojectM rendering without replacing the whole app.

### Licensing constraints from third-party dependencies
Mitigation: Review libprojectM license obligations before distribution. Link as a library rather than inheriting a frontend.

## Success definition

The macOS port is done when:

- It launches as a normal macOS app
- It reacts to both system audio and microphone input
- It renders bundled MilkDrop presets reliably
- It supports the core BeatDrop operator workflow and hotkeys
- It can publish live output to other macOS visual tools
- It survives long-running sessions without audio stalls or renderer resets

## External references

- [Apple ScreenCaptureKit WWDC session](https://developer.apple.com/videos/play/wwdc2022/10155/)
- [Apple CoreAudio AudioHardwareSystem docs](https://developer.apple.com/documentation/coreaudio/audiohardwaresystem)
- [projectM repository](https://github.com/projectM-visualizer/projectm)
- [projectM SDL frontend](https://github.com/projectM-visualizer/frontend-sdl-cpp)
- [Syphon framework](https://github.com/Syphon/Syphon-Framework)
- [AudioCap — macOS 14.4+ process tap example](https://github.com/insidegui/AudioCap)
