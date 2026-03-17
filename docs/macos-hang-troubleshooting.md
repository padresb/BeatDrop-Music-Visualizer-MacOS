# macOS Hang Troubleshooting

## Confirmed Cases

### 1. Main-thread preset load stall

Observed on March 15, 2026 while running `build/macos/BeatDrop Mac.app`.

Symptoms:
- UI stops responding.
- Process stays near 100% CPU instead of sleeping.
- Activity Monitor "Open Files and Ports" is not sufficient to identify the cause.

Confirmed stack signature from `sample`:
- `-[BeatDropPortView tick:]`
- `beatdrop::core::RuntimeCoordinator::tick(double)`
- `beatdrop::macos::MacPresetEngine::ensure_projectm_backend(double)`
- `beatdrop::macos::MacPresetEngine::ProjectMRenderer::load_preset(...)`
- `projectm_load_preset_file`
- `libprojectM::MilkdropPreset::MilkdropShader::TranspileHLSLShader`
- `M4::HLSLParser::ApplyPreprocessor`
- `M4::HLSLTokenizer::Next/ScanNumber`

Important conclusion:
- This was not a Syphon hang.
- This was not a `glReadPixels` hang.
- This was not a traditional deadlock.
- The app was monopolizing the main thread while synchronously compiling/loading a preset.

### 2. Pathological startup preset

Also observed on March 15, 2026.

Symptoms:
- App window appears, then hangs almost immediately.
- Process remains near 100% CPU.
- Physical memory can balloon into multi-GB range during the stall.

Important conclusion:
- A saved startup preset can trigger an immediate synchronous `projectm_load_preset_file(...)` stall on launch.

## Mitigations In Repo

Implemented:
- `third_party/projectm/vendor/hlslparser/src/Engine.cpp`
  - replaced slow per-token locale/stringstream float parsing with locale-fixed `strtod_l`/`_strtod_l`
- `macos/src/main.mm`
  - added persistent preset blacklist support via `settings.szPresetBlacklist`
  - startup/manual/auto-advance selection skips blacklisted presets
  - explicit libprojectM preset rejections are recorded into the blacklist

## User Config To Check First

File:
- `~/Library/Application Support/BeatDrop Mac/beatdrop.ini`

Keys:
- `bEnablePresetStartup`
- `szPresetStartup`
- `bPresetAutoAdvance`
- `fTimeBetweenPresets`
- `fTimeBetweenPresetsRand`
- `szPresetBlacklist`

Blacklist format:

```ini
szPresetBlacklist=BeatDrop Resources\presets\Foo.milk | BeatDrop Resources\presets\Bar.milk
```

## First Response Next Time

1. Confirm whether the hung process is still consuming CPU.
2. Run `sample <pid> 5`.
3. Check whether the stack is again inside `projectm_load_preset_file(...)`.
4. Inspect `beatdrop.ini` for startup preset and blacklist state.
5. If the preset path is known, add it to `szPresetBlacklist`.

## Current Status

After the parser patch, startup config reset, and blacklist support, the app ran for about one hour with auto-advance enabled at 15-second intervals without crashing.
