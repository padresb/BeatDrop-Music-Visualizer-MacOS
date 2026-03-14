# macOS renderer handoff

## Read first

Use this file as the entry point for a new session, then read these two docs for the broader project state:

- [macos-implementation-plan.md](/Users/bretpadres/Documents/projects/BeatDrop-Music-Visualizer/docs/macos-implementation-plan.md)
  Purpose: phase status, replacement strategy, repo-wide progress, and the tracked list of remaining macOS work.
- [macos-port.md](/Users/bretpadres/Documents/projects/BeatDrop-Music-Visualizer/docs/macos-port.md)
  Purpose: concise port status, current capabilities, milestone notes, and the current renderer/audio blockers.

## Current blocker

The macOS app launches, loads the full preset library, changes active presets, and receives live system-output PCM, but the real `libprojectM` renderer still does not present a first valid frame to the AppKit preview.

The app therefore stays on the native telemetry fallback visualization and the renderer card continues to report `FALLBACK LIVE`.

## Latest user-observed runtime error

From the in-app `RENDERER` detail text after loading the bundled preset folder and browsing presets:

- active preset changes correctly
- preset count remains correct (`6837`)
- system-output capture stays live
- renderer fallback remains active
- latest surfaced backend error: `Unable to allocate the offscreen framebuffer for libprojectM.`

That error comes from the current `MacPresetEngine::ProjectMRenderer::ensure_render_target()` path in [MacPresetEngine.cpp](/Users/bretpadres/Documents/projects/BeatDrop-Music-Visualizer/macos/src/MacPresetEngine.cpp).

## What is confirmed working

- native macOS app bundle launches
- AppKit shell is stable and responsive
- system-output capture through `ScreenCaptureKit` is live and drives the fallback visualizer
- preset folder drag/drop works
- preset next/previous/random navigation updates session state and the active preset label
- shared preset session/history/rating logic is working
- `libprojectM` is detected and linked at build time
- Syphon framework is installed and linked
- screenshot export and Syphon toggle are wired in the shell

## What is not working

- the real preset render path never promotes to a valid `latest_frame`
- the renderer card never switches from `FALLBACK LIVE` to a real live renderer state
- the main canvas does not visually change with preset changes because only the fallback telemetry renderer is visible
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
- backend detail text is surfaced earlier in the renderer card so fallback screenshots expose the real failing stage

## Current testing path

Use system-output capture only. Microphone capture is not the current debugging target.

Repro used in the current session:

1. Launch the app.
2. Drag [presets](/Users/bretpadres/Documents/projects/BeatDrop-Music-Visualizer/resources/Milkdrop2/presets) onto the window.
3. Browse presets with `Left`, `Right`, or `R`.
4. Observe that the active preset label changes but the main canvas remains the fallback visualizer.
5. Read the in-app renderer detail text for the current backend error.
