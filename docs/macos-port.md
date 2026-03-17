# BeatDrop macOS port

## Current state

The macOS port is a functional native app with live audio-reactive preset rendering, system audio capture, Syphon output, and most core BeatDrop workflows restored.

### What works

- Native macOS `.app` bundle launches and runs as a standalone desktop app
- `libprojectM 4.1.6` renders MilkDrop presets into an OpenGL framebuffer shared by AppKit preview and Syphon
- System-output PCM capture via `ScreenCaptureKit` (macOS 13+)
- Microphone capture via `AVAudioEngine` (permission-gated)
- Syphon publisher wired to the live render surface, with persistent enable/disable toggle
- Preset session with rating-aware randomization, history, sequential/random order, and auto-advance
- Keyboard preset browsing (left/right/space/R) and drag/drop loading of `.milk` files or folders
- `beatdrop.ini` import plus startup preset/session persistence in `~/Library/Application Support/BeatDrop Mac/`
- Startup window restore for geometry, borderless, fullscreen, and always-on-top
- Responsive AppKit status layout with shell cards and debug info toggle (D key)
- PNG screenshot export to `~/Pictures/BeatDrop/screenshots/` via Ctrl+X / Cmd+X
- Preset blacklist: pathological presets are auto-blacklisted on load failure and skipped during selection
- Playlist support with five assignable playlists (G/H/J/K/L keys) and cycling (P key)
- CoreAudio device inventory and permission diagnostics

### Keyboard shortcuts

| Key | Action |
|-----|--------|
| Esc / F | Toggle fullscreen rendering |
| Left | Previous preset |
| Right | Next preset |
| Space / R | Random preset |
| S | Toggle order mode (sequential / random) |
| T | Toggle preset auto-advance |
| O | Toggle Syphon output |
| M | Toggle mini player |
| D | Toggle debug info |
| P | Cycle active playlist |
| G / H / J / K / L | Toggle current preset in playlists 0–4 |
| Ctrl+X / Cmd+X | Save PNG screenshot |

### Known issues and remaining work

- **Preset compatibility:** The renderer is past the "broadly broken" stage. Remaining work is targeted validation against the Windows app for presets that still look suspicious. Edge cases to watch: `GetPixel`/`GetBlur*` behavior, feedback buffers, composite shader state transfer, unset `q` variable defaults, FFT normalization differences.
- **Microphone capture:** Permission prompting is wired, but the live mic stream is pinned for hardening after a post-grant `AVAudioConverter` crash. System-output capture is the stable path.
- **CoreAudio process taps:** Infrastructure detection is in place (`SupportsCoreAudioProcessTap()` for macOS 14.4+), but not yet implemented. Lower-overhead alternative to ScreenCaptureKit.
- **Audio hot switching:** Not yet implemented. Device changes may require restart.
- **Syphon receiver validation:** Publisher is live; receiver-side testing with OBS/Resolume/VDMX is outstanding.
- **Preferences UI:** No native preferences screen yet. All config goes through `beatdrop.ini`.

### Validation presets

Useful stock presets from `resources/Milkdrop2/presets/Incubo_'s Presets` for regression testing:

- **Visually responsive (good baseline):** Se7enSlasher - MilkDropLM Generated Preset #5 / #6 / #7 / #8
- **Recovered after framebuffer readback fix:** Se7enSlasher - Moving RGB Splitting Effect
- **Recovered after FFT shader support:** Se7enSlasher - PolarSpectrumEX
- **Mixed cases (preset authoring quirks + possible renderer gaps):** Se7enSlasher - Mix to the mix / Mix to the mix 2

## Milestones

1. **Native bootstrap app** — Done
2. **Audio capture** — Done (system-output via ScreenCaptureKit, mic via AVAudioEngine)
3. **Renderer integration** — Done (libprojectM offscreen → AppKit + Syphon)
4. **Preset UX and persistence** — Done (session, history, browsing, drag/drop, INI import, startup restore)
5. **Window semantics** — Done (geometry, borderless, fullscreen, always-on-top)
6. **Screenshot export** — Done
7. **Syphon output** — Done (publisher live; receiver validation outstanding)
8. **Compatibility and performance hardening** — In progress
9. **Packaging and release** — Not started

## Troubleshooting

### Hang on startup or preset load

The app can stall if a preset triggers pathological shader transpilation in `hlslparser`. Symptoms: UI freezes, ~100% CPU, no crash.

Diagnostic steps:
1. Run `sample <pid> 5` to confirm the stack is inside `projectm_load_preset_file` → `HLSLParser::ApplyPreprocessor`
2. Check `~/Library/Application Support/BeatDrop Mac/beatdrop.ini` for `szPresetStartup` and `szPresetBlacklist`
3. Add the offending preset path to `szPresetBlacklist` (pipe-delimited)

Mitigations in the codebase:
- `third_party/projectm/vendor/hlslparser/src/Engine.cpp` — replaced slow per-token locale/stringstream float parsing with `strtod_l`
- `macos/src/main.mm` — preset blacklist support; rejected presets are auto-blacklisted and skipped

### Preset looks frozen or non-reactive

Two root causes were found and fixed:
1. **Framebuffer readback mismatch:** The macOS wrapper was reading back the wrong framebuffer after projectM's final composite step. Fixed in `MacPresetEngine.cpp`.
2. **Missing shader FFT texture:** Shader-driven FFT presets (`get_fft()` / `get_fft_peak()`) had no texture upload path. Fixed by adding `sampler_fft` upload, `FFTAttack`/`FFTDecay` parsing, and `#if HAS_FFT_PEAK` guard unwrapping.

If a preset still looks wrong, classify it: post-process/composite issue, FFT shader issue, or preset authoring quirk already present in the source `.milk`.

## Vendored dependencies

- `third_party/projectm` — BeatDrop-carried source based on upstream projectM commit `3158ee615eaafd93a8912b5f6dd84a9c47b2e00a` (libprojectM 4.1.6). Contains BeatDrop-specific patches (hlslparser perf, FFT shader texture). After changing this source, the installed copy under `third_party/install/projectm` must be rebuilt.
- `third_party/install/syphon/Frameworks` — Syphon.framework from upstream Syphon project.
