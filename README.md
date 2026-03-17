# BeatDrop Music Visualizer — macOS Port

A native macOS port of [BeatDrop Music Visualizer](https://github.com/OfficialIncubo/BeatDrop-Music-Visualizer), a standalone music visualizer based on [MilkDrop2](https://www.geisswerks.com/milkdrop/).

> **Looking for the Windows version?** See the [original BeatDrop project](https://github.com/OfficialIncubo/BeatDrop-Music-Visualizer).

## What This Is

This fork brings BeatDrop to macOS as a native app. It replaces the Windows-only subsystems (Direct3D, WASAPI, Spout) with macOS equivalents (OpenGL via libprojectM, CoreAudio/ScreenCaptureKit, Syphon) while preserving MilkDrop preset compatibility and core BeatDrop workflows.

For architecture details and design decisions, see [docs/macos-implementation-plan.md](docs/macos-implementation-plan.md).
For detailed port status and troubleshooting, see [docs/macos-port.md](docs/macos-port.md).

## Features

- Renders MilkDrop presets (`.milk`) via [libprojectM](https://github.com/projectM-visualizer/projectm)
- System audio capture — reacts to all audio playing on your Mac (macOS 13+)
- Microphone capture with permission prompting
- [Syphon](https://github.com/Syphon/Syphon-Framework) output for routing visuals to OBS, Resolume, VDMX, and other tools
- Preset browsing with rating-aware randomization, history, and auto-advance
- Drag and drop `.milk` files or preset folders
- Five assignable playlists
- Fullscreen, borderless, and always-on-top window modes
- Window geometry and session state restored on launch
- `beatdrop.ini` import from the Windows version
- PNG screenshot export
- Preset blacklist for problematic presets (auto-populated on load failure)

## Keyboard Shortcuts

| Key | Action |
|-----|--------|
| Esc / F | Toggle fullscreen |
| Left / Right | Previous / next preset |
| Space / R | Random preset |
| S | Toggle order mode (sequential / random) |
| T | Toggle preset auto-advance |
| O | Toggle Syphon output |
| M | Toggle mini player |
| D | Toggle debug info |
| P | Cycle active playlist |
| G / H / J / K / L | Toggle current preset in playlists 0–4 |
| Ctrl+X / Cmd+X | Save PNG screenshot |

## System Requirements

- macOS 13+ (ScreenCaptureKit required for system audio capture)
- Apple Silicon or Intel Mac
- Screen Recording permission (for system audio capture)

## Building

### Prerequisites

- Xcode Command Line Tools (or Xcode)
- CMake 3.25+

### Build libprojectM from vendored source

```bash
cd third_party/projectm
mkdir -p build && cd build
cmake .. -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=../../install/projectm
cmake --build . --config Release --parallel
cmake --install . --prefix ../../install/projectm
```

### Build the app

```bash
mkdir -p build && cd build
cmake .. -DCMAKE_BUILD_TYPE=Release
cmake --build . --config Release --parallel
```

The app bundle is output to `build/macos/BeatDrop Mac.app`.

### Syphon

Syphon.framework is included under `third_party/install/syphon/Frameworks/` and is detected automatically at build time.

## How to Use

1. Run `BeatDrop Mac.app`
2. Grant Screen Recording permission when prompted (required for system audio capture)
3. Play music from any source — Spotify, YouTube, Apple Music, etc.
4. Browse presets with arrow keys, or drag and drop `.milk` files onto the window

## Features Not Yet Ported from Windows

### High Impact

1. **Additional waveforms (9 extra modes)** — Windows BeatDrop has 18 waveform modes. The vendored projectM has 16 (including 7 MilkDrop2077 extras). Two BeatDrop-specific waveforms are missing.

2. **16 custom shapes and waves slots** — Windows supports `MAX_CUSTOM_WAVES = 16` and `MAX_CUSTOM_SHAPES = 16`. projectM supports 4 of each. Presets using slots 5–16 silently lose those elements on macOS.

3. **Mouse-controlled preset interaction** — Windows passes mouse coordinates to preset variables and supports Ctrl+Arrow key interaction. macOS does not pass mouse coordinates to projectM. Presets authored for mouse interactivity will be static.

4. **Hard cut modes** — Windows supports beat-triggered instant preset switches with configurable sensitivity. macOS explicitly disables hard cuts. This is a core part of the MilkDrop experience for high-energy music.

5. **Real-time song information display** — Windows uses SMTC to show the current song title/artist. macOS has no NowPlaying/MediaRemote integration.

6. **Screen-dependent render mode** — Windows has a mode that fixes aspect-ratio-dependent preset rendering for MilkDrop 1 compatibility. macOS has no equivalent — old 4:3 presets may render differently.

### Medium Impact

7. **Shader precaching/caching** — Windows caches compiled shaders to disk for instant reload. macOS relies on whatever projectM does internally.

8. **In-app configuration dialog** — Windows has a full GUI settings panel. macOS requires manually editing `beatdrop.ini`.

9. **In-app preset editing** — Windows has a live menu system for editing preset parameters (wave type, motion, custom wave/shape code, post-processing). macOS has no preset editing UI.

10. **Audio device change resilience** — Windows handles device switching and sample rate changes without interruption. macOS audio capture stops and restarts on device changes.

11. **Shader randomization (mini mash-up)** — Windows supports hotkeys for randomizing warp/comp shaders and random mini mash-ups. Not ported.

### Lower Impact

12. **Hi-res audio (>48kHz) optimization** — Windows has specific handling for 96kHz/192kHz+ sources. macOS uses basic resampling to 44.1kHz.

13. **Mersenne Twister PRNG** — Windows uses MT for extended randomization. macOS uses standard library random.

14. **Extended hotkey system (F1–F9)** — Windows has F1=help overlay, F2=borderless toggle, F8=song info toggle, etc. macOS has a smaller set of shortcuts.

15. **Playback controls** — Windows can control media playback from within BeatDrop. Not ported.

## Acknowledgements

This project is a fork of [BeatDrop Music Visualizer](https://github.com/OfficialIncubo/BeatDrop-Music-Visualizer) by [Incubo](https://github.com/OfficialIncubo).

Special thanks to:

* [Incubo](https://github.com/OfficialIncubo) — BeatDrop creator and maintainer
* Ryan Geiss & Rovastar (John Baker) — Original [MilkDrop](https://www.geisswerks.com/milkdrop/) visualization plug-in
* projectM Team ([Kai Blaschke](https://github.com/kblaschke)) — [libprojectM](https://github.com/projectM-visualizer/projectm) and [projectM-eval](https://github.com/projectM-visualizer/projectm-eval)
* [Syphon](https://github.com/Syphon) — Syphon framework for inter-app video
* Lynn Jarvis ([@leadedge](https://github.com/leadedge)) — [Spout](https://spout.zeal.co) and [BeatDrop for Spout](https://github.com/leadedge/BeatDrop)
* All the original BeatDrop contributors, testers, and preset authors

## License

[license]: #license

This repository is licensed under the 3-Clause BSD License ([LICENSE](LICENSE) or [https://opensource.org/licenses/BSD-3-Clause](https://opensource.org/licenses/BSD-3-Clause)) with the exception of where otherwise noted.

## Contributions

Unless you explicitly state otherwise, any contribution intentionally submitted for inclusion in the work by you, shall be licensed as above.
