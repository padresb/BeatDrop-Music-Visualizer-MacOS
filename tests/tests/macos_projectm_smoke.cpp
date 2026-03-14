#include "MacPresetEngine.h"

#include <cmath>
#include <cstdint>
#include <filesystem>
#include <iostream>
#include <vector>

namespace {

std::filesystem::path RepoRoot() {
    return std::filesystem::path(BEATDROP_SOURCE_DIR);
}

std::filesystem::path DefaultPresetLibrary() {
    return RepoRoot() / "resources" / "Milkdrop2" / "presets";
}

std::vector<float> BuildSineBlock(std::size_t frame_count, float frequency_hz, std::uint32_t sample_rate_hz) {
    std::vector<float> samples(frame_count * 2U);
    constexpr double kTau = 6.28318530717958647692;

    for (std::size_t frame = 0; frame < frame_count; ++frame) {
        const double phase = kTau * static_cast<double>(frame) * static_cast<double>(frequency_hz) /
            static_cast<double>(sample_rate_hz);
        const float value = static_cast<float>(std::sin(phase) * 0.45);
        samples[frame * 2U] = value;
        samples[frame * 2U + 1U] = value;
    }

    return samples;
}

} // namespace

int main() {
    beatdrop::macos::MacPresetEngine engine;
    engine.set_audio_stream_format({ 44100, 2 });
    engine.set_render_surface({ 640, 360, 1.0 });

    if (!engine.load_preset_library(DefaultPresetLibrary())) {
        std::cerr << "Failed to load preset library from " << DefaultPresetLibrary() << '\n';
        return 1;
    }

    const auto audio_block = BuildSineBlock(2048, 220.0F, 44100);
    for (int frame = 0; frame < 12; ++frame) {
        engine.ingest_audio_frames(audio_block.data(), audio_block.size() / 2U);
        engine.update(1.0 / 60.0);
    }

    const auto state = engine.describe_state();
    if (!state.backend_available) {
        std::cerr << "libprojectM backend did not go live. Detail: " << state.detail << '\n';
        return 1;
    }

    if (!engine.has_latest_frame()) {
        std::cerr << "libprojectM reported backend_available but no frame pixels were retained.\n";
        return 1;
    }

    if (engine.latest_frame_width() != 640 || engine.latest_frame_height() != 360) {
        std::cerr << "Unexpected frame size " << engine.latest_frame_width() << "x"
                  << engine.latest_frame_height() << '\n';
        return 1;
    }

    std::uint64_t pixel_energy = 0;
    for (const auto byte : engine.latest_frame_rgba()) {
        pixel_energy += byte;
    }

    if (pixel_energy == 0) {
        std::cerr << "Rendered frame was completely black/empty.\n";
        return 1;
    }

    return 0;
}
