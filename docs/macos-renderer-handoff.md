# macOS renderer handoff

## Read first

Use this file as the entry point for a new session, then read these two docs for the broader project state:

- [macos-implementation-plan.md](/Users/bretpadres/Documents/projects/BeatDrop-Music-Visualizer/docs/macos-implementation-plan.md)
  Purpose: phase status, replacement strategy, repo-wide progress, and the tracked list of remaining macOS work.
- [macos-port.md](/Users/bretpadres/Documents/projects/BeatDrop-Music-Visualizer/docs/macos-port.md)
  Purpose: concise port status, current capabilities, milestone notes, and the current renderer/audio blockers.

## Current blocker

The previous renderer bootstrap blocker is cleared. The macOS app now reaches `RENDERER LIVE`, presents real `libprojectM` frames in the AppKit preview, and publishes the same render surface through Syphon.

The active blocker has moved up a layer: preset responsiveness is inconsistent across the `.milk` corpus. Some presets render and react normally, while others appear visually frozen even though the renderer stays live and the system-output PCM telemetry continues to update.

## Latest user-observed runtime symptom

From the in-app `RENDERER` detail text and sequential screenshots after loading the bundled preset folder and browsing presets:

- active preset changes correctly
- preset count remains correct (`6837`)
- renderer card reports `RENDERER LIVE`
- system-output capture stays live and the light-blue PCM sparkline continues changing
- frame counters continue advancing
- some presets still show a visually static main render over multiple seconds, with no obvious response to audio

This means the current debugging target is no longer first-frame setup. It is now understanding how the active `.milk` file is being loaded and exercised at runtime, and why some presets stay non-responsive despite valid render/audio telemetry.

## What is confirmed working

- native macOS app bundle launches
- AppKit shell is stable and responsive
- system-output capture through `ScreenCaptureKit` is live
- preset folder drag/drop works
- preset next/previous/random navigation updates session state and the active preset label
- shared preset session/history/rating logic is working
- `libprojectM` is detected and linked at build time
- the real `libprojectM` renderer now reaches `latest_frame` and is shown in the AppKit preview
- the renderer card now switches to `RENDERER LIVE`
- Syphon publishing is wired to the live renderer surface
- Syphon framework is installed and linked
- screenshot export and Syphon toggle are wired in the shell

## What is not working

- preset compatibility is not yet trustworthy across the full library
- some `.milk` files render but appear static or non-reactive despite live audio/render telemetry
- the app does not yet expose enough preset-level diagnostics to explain why a given preset is non-responsive
- microphone capture remains pinned separately as a known unstable path after permission grant

## Most relevant files

- [MacPresetEngine.cpp](/Users/bretpadres/Documents/projects/BeatDrop-Music-Visualizer/macos/src/MacPresetEngine.cpp)
- [MacPresetEngine.h](/Users/bretpadres/Documents/projects/BeatDrop-Music-Visualizer/macos/src/MacPresetEngine.h)
- [main.mm](/Users/bretpadres/Documents/projects/BeatDrop-Music-Visualizer/macos/src/main.mm)
- [RuntimeCoordinator.cpp](/Users/bretpadres/Documents/projects/BeatDrop-Music-Visualizer/core/src/RuntimeCoordinator.cpp)
- [macos-port.md](/Users/bretpadres/Documents/projects/BeatDrop-Music-Visualizer/docs/macos-port.md)
- [macos-implementation-plan.md](/Users/bretpadres/Documents/projects/BeatDrop-Music-Visualizer/docs/macos-implementation-plan.md)

## Renderer changes already attempted

- initial offscreen `libprojectM` integration behind `MacPresetEngine`
- framebuffer/texture render target replaced the earlier pbuffer-only path
- `projectm_set_window_size()` stopped being called every frame because the upstream API resets the renderer on that call
- OpenGL profile fallback now keys off actual `projectm_create()` success, not just successful `CGLCreateContext()`
- backend detail text is surfaced in the renderer card so runtime screenshots expose the current stage and counters

## Current testing path

Use system-output capture only. Microphone capture is not the current debugging target.

Repro used in the current session:

1. Launch the app.
2. Drag [presets](/Users/bretpadres/Documents/projects/BeatDrop-Music-Visualizer/resources/Milkdrop2/presets) onto the window.
3. Browse presets with `Left`, `Right`, or `R`.
4. Confirm that the renderer card reports `RENDERER LIVE`.
5. Compare multiple screenshots over several seconds for the same preset.
6. Watch for cases where the PCM sparkline and counters move but the main render appears visually unchanged.
