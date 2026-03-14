# macOS renderer handoff

## Read first

Use this file as the entry point for a new session, then read these two docs for the broader project state:

- [macos-implementation-plan.md](/Users/bretpadres/Documents/projects/BeatDrop-Music-Visualizer/docs/macos-implementation-plan.md)
  Purpose: phase status, replacement strategy, repo-wide progress, and the tracked list of remaining macOS work.
- [macos-port.md](/Users/bretpadres/Documents/projects/BeatDrop-Music-Visualizer/docs/macos-port.md)
  Purpose: concise port status, current capabilities, milestone notes, and the current renderer/audio blockers.

## Current status

The previous renderer bootstrap blocker is cleared. The macOS app reaches `RENDERER LIVE`, presents real `libprojectM` frames in the AppKit preview, and publishes the same render surface through Syphon.

The main compatibility regressions found during this round are now addressed:

- composite-heavy presets that looked frozen because the macOS wrapper was reading back the wrong framebuffer after projectM's final composite step
- shader-driven FFT presets that depended on `get_fft()` / `get_fft_peak()` even though vendored `libprojectM` was not uploading a shader FFT texture on macOS

The renderer is in materially better shape now. Remaining work is no longer “basic motion is broadly broken”; it is targeted preset validation against the Windows app for anything that still looks suspicious.

## Current repro and validation set

Useful presets from the bundled stock corpus under `resources/Milkdrop2/presets/Incubo_'s Presets`:

- visually responsive:
  - `Se7enSlasher - MilkDropLM Generated Preset #5`
  - `Se7enSlasher - MilkDropLM Generated Preset #6`
  - `Se7enSlasher - MilkDropLM Generated Preset #7`
  - `Se7enSlasher - MilkDropLM Generated Preset #8`
- recovered after framebuffer/readback fix:
  - `Se7enSlasher - Moving RGB Splitting Effect`
- recovered after FFT shader support was added:
  - `Se7enSlasher - PolarSpectrumEX`
- still useful for manual comparison because they may combine authoring quirks with renderer edge cases:
  - `Se7enSlasher - Mix to the mix`
  - `Se7enSlasher - Mix to the mix 2`

## What is confirmed working

- native macOS app bundle launches
- AppKit shell is stable and responsive
- system-output capture through `ScreenCaptureKit` is live
- `libprojectM` is detected and linked at build time
- the renderer reaches `RENDERER LIVE`
- active preset changes correctly while browsing
- system-output PCM continues to update while these presets are on screen
- preset/session/history logic works
- the same live render surface is used for AppKit preview and Syphon publishing
- composite/post-processing motion survives through final readback on macOS
- shader presets can consume live FFT data through `sampler_fft`
- preset `FFTAttack` / `FFTDecay` settings are parsed and applied

## Static analysis findings

- `Mix to the mix` and `Mix to the mix 2` are mainly time-driven composite/feedback presets. They depend much more on post-processing, blur sampling, and `GetPixel`/`GetBlur` behavior than on obvious beat-driven custom wave motion.
- Both `Mix to the mix` presets reference `q22` and `q27` in the composite shader, but those vars do not appear to be assigned in the preset source. That likely disables part of the intended effect even before accounting for renderer compatibility.
- `Moving RGB Splitting Effect` was the cleaner time-driven test case. As written, it should animate from `time`, `sin`, and `cos` even with weak audio input, which is why it was useful for isolating the framebuffer/readback bug.
- `PolarSpectrumEX` is a different class of preset. It is primarily a shader-driven FFT visualization and relies on `get_fft()` / `get_fft_peak()` in the warp shader rather than classic per-frame MilkDrop equations.
- The working `MilkDropLM Generated Preset` variants are more resilient because they use stronger beat/state logic, enabled custom waves, and more obvious audio-driven state changes.

## Most relevant files

- [MacPresetEngine.cpp](/Users/bretpadres/Documents/projects/BeatDrop-Music-Visualizer/macos/src/MacPresetEngine.cpp)
- [MacPresetEngine.h](/Users/bretpadres/Documents/projects/BeatDrop-Music-Visualizer/macos/src/MacPresetEngine.h)
- [main.mm](/Users/bretpadres/Documents/projects/BeatDrop-Music-Visualizer/macos/src/main.mm)
- [Se7enSlasher - Mix to the mix.milk](/Users/bretpadres/Documents/projects/BeatDrop-Music-Visualizer/resources/Milkdrop2/presets/Incubo_'s%20Presets/Se7enSlasher%20-%20Mix%20to%20the%20mix.milk)
- [Se7enSlasher - Mix to the mix 2.milk](/Users/bretpadres/Documents/projects/BeatDrop-Music-Visualizer/resources/Milkdrop2/presets/Incubo_'s%20Presets/Se7enSlasher%20-%20Mix%20to%20the%20mix%202.milk)
- [Se7enSlasher - Moving RGB Splitting Effect.milk](/Users/bretpadres/Documents/projects/BeatDrop-Music-Visualizer/resources/Milkdrop2/presets/Incubo_'s%20Presets/Se7enSlasher%20-%20Moving%20RGB%20Splitting%20Effect.milk)
- [Se7enSlasher - MilkDropLM Generated Preset #6.milk](/Users/bretpadres/Documents/projects/BeatDrop-Music-Visualizer/resources/Milkdrop2/presets/Incubo_'s%20Presets/Se7enSlasher%20-%20MilkDropLM%20Generated%20Preset%20%236.milk)

## Working hypothesis

The earlier broad “frozen preset” symptom turned out to be two separate issues:

- framebuffer/readback state mismatch after projectM's internal final composite step
- missing shader FFT texture support in vendored `libprojectM`

What remains worth watching:

- `GetPixel`
- `GetBlur*`
- feedback buffer behavior
- composite shader state transfer
- default handling of unset `q` variables
- any remaining differences between Windows FFT handling and projectM's normalized spectrum data

## Next troubleshooting focus

- Keep testing on bundled presets so the repro corpus stays stable.
- Compare any still-suspicious preset directly against the Windows renderer before assuming the macOS port is wrong.
- Treat `Mix to the mix` and `Mix to the mix 2` as mixed cases:
  - likely partial preset authoring issues
  - plus possible projectM compatibility gaps
- If a preset still looks wrong, classify it first:
  - post-process/composite issue
  - FFT-shader issue
  - preset authoring quirk already present in the source

## Latest update

- `Moving RGB Splitting Effect` was not just a weak-audio illusion. The macOS wrapper was reading back the wrong framebuffer after projectM's internal final composite step. Fixing the caller/readback framebuffer state restored motion for composite-heavy presets.
- `PolarSpectrumEX` exposed a separate compatibility gap. It is a shader-driven FFT preset and depends on `get_fft()` / `get_fft_peak()` in the warp shader, not on classic MilkDrop per-frame equations.
- The Windows renderer already has a dedicated 512x2 FFT shader texture path. Vendored libprojectM did not. The port now:
  - parses preset `FFTAttack` / `FFTDecay`
  - uploads a `sampler_fft` texture every frame
  - exposes `get_fft()` / `get_fft_peak()` in the preset shader header
  - unwraps the `#if HAS_FFT_PEAK` guard used by these BeatDrop-authored presets before feeding the shader to `hlslparser`
- Important nuance: the Windows FFT upload path uses an unnormalized FFT and a tiny scale factor. projectM's `audioData.spectrum*` buffers are already near normalized, so reusing the Windows scale directly collapsed the shader FFT texture to zero on macOS. The macOS/libprojectM fix uploads the projectM spectrum at full scale instead.
- Current automated coverage:
  - `beatdrop_macos_projectm_smoke`
  - `beatdrop_macos_projectm_preset_motion`
  - `beatdrop_macos_projectm_fft_shader_motion`
- All three tests passed after the renderer and FFT-path changes.
- Important repo detail: part of the fix lives in the vendored renderer source under `third_party/projectm`, not only in the top-level macOS app code.
- `third_party/projectm` should now be treated as BeatDrop-carried source, based on upstream `projectM` commit `3158ee615eaafd93a8912b5f6dd84a9c47b2e00a` (`Bump libprojectM version to 4.1.6`).
- Build/install nuance: the app still links against the local install prefix under `third_party/install/projectm`, so after changing `third_party/projectm` the installed libprojectM copy must be rebuilt and reinstalled from that vendored source.
