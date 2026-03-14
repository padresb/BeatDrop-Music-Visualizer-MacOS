#include "MacPresetEngine.h"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <filesystem>
#include <iostream>
#include <set>
#include <vector>

namespace {

std::filesystem::path RepoRoot() {
    return std::filesystem::path(BEATDROP_SOURCE_DIR);
}

std::filesystem::path DefaultPresetLibrary() {
    return RepoRoot() / "resources" / "Milkdrop2" / "presets";
}

std::filesystem::path PolarSpectrumPreset() {
    return DefaultPresetLibrary() / "Incubo_'s Presets" / "Se7enSlasher - PolarSpectrumEX.milk";
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

std::uint64_t SampleFrameSignature(
    const std::vector<std::uint8_t>& rgba,
    std::uint32_t width,
    std::uint32_t height) {
    if (rgba.empty() || width == 0 || height == 0) {
        return 0;
    }

    constexpr std::uint64_t kOffset = 1469598103934665603ULL;
    constexpr std::uint64_t kPrime = 1099511628211ULL;
    constexpr std::size_t kGridX = 64U;
    constexpr std::size_t kGridY = 48U;

    std::uint64_t signature = kOffset;
    for (std::size_t grid_y = 0; grid_y < kGridY; ++grid_y) {
        const std::uint32_t y = static_cast<std::uint32_t>(
            (grid_y * std::max<std::uint32_t>(1U, height - 1U)) / std::max<std::size_t>(1U, kGridY - 1U));
        for (std::size_t grid_x = 0; grid_x < kGridX; ++grid_x) {
            const std::uint32_t x = static_cast<std::uint32_t>(
                (grid_x * std::max<std::uint32_t>(1U, width - 1U)) / std::max<std::size_t>(1U, kGridX - 1U));
            const std::size_t index =
                (static_cast<std::size_t>(y) * static_cast<std::size_t>(width) + static_cast<std::size_t>(x)) * 4U;
            if (index + 3U >= rgba.size()) {
                continue;
            }

            signature ^= static_cast<std::uint64_t>(rgba[index + 0U]);
            signature *= kPrime;
            signature ^= static_cast<std::uint64_t>(rgba[index + 1U]);
            signature *= kPrime;
            signature ^= static_cast<std::uint64_t>(rgba[index + 2U]);
            signature *= kPrime;
            signature ^= static_cast<std::uint64_t>(rgba[index + 3U]);
            signature *= kPrime;
        }
    }

    return signature;
}

std::uint8_t SamplePeakChannel(
    const std::vector<std::uint8_t>& rgba,
    std::uint32_t width,
    std::uint32_t height) {
    if (rgba.empty() || width == 0 || height == 0) {
        return 0;
    }

    constexpr std::size_t kGridX = 64U;
    constexpr std::size_t kGridY = 48U;

    std::uint8_t peak = 0;
    for (std::size_t grid_y = 0; grid_y < kGridY; ++grid_y) {
        const std::uint32_t y = static_cast<std::uint32_t>(
            (grid_y * std::max<std::uint32_t>(1U, height - 1U)) / std::max<std::size_t>(1U, kGridY - 1U));
        for (std::size_t grid_x = 0; grid_x < kGridX; ++grid_x) {
            const std::uint32_t x = static_cast<std::uint32_t>(
                (grid_x * std::max<std::uint32_t>(1U, width - 1U)) / std::max<std::size_t>(1U, kGridX - 1U));
            const std::size_t index =
                (static_cast<std::size_t>(y) * static_cast<std::size_t>(width) + static_cast<std::size_t>(x)) * 4U;
            if (index + 2U >= rgba.size()) {
                continue;
            }

            peak = std::max(peak, rgba[index + 0U]);
            peak = std::max(peak, rgba[index + 1U]);
            peak = std::max(peak, rgba[index + 2U]);
        }
    }

    return peak;
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

    if (!engine.set_active_preset(PolarSpectrumPreset())) {
        std::cerr << "Failed to activate preset " << PolarSpectrumPreset() << '\n';
        return 1;
    }

    const auto audio_block = BuildSineBlock(2048, 220.0F, 44100);
    std::set<std::uint64_t> signatures;
    std::uint8_t peak_channel = 0;

    for (int frame = 0; frame < 60; ++frame) {
        engine.ingest_audio_frames(audio_block.data(), audio_block.size() / 2U);
        engine.update(1.0 / 60.0);

        if (!engine.has_latest_frame()) {
            std::cerr << "Renderer did not retain a frame on iteration " << frame << '\n';
            return 1;
        }

        if (frame >= 8) {
            signatures.insert(
                SampleFrameSignature(
                    engine.latest_frame_rgba(),
                    engine.latest_frame_width(),
                    engine.latest_frame_height()));
            peak_channel = std::max(
                peak_channel,
                SamplePeakChannel(
                    engine.latest_frame_rgba(),
                    engine.latest_frame_width(),
                    engine.latest_frame_height()));
        }
    }

    if (signatures.size() < 3) {
        std::cerr << "Expected the FFT-driven PolarSpectrumEX preset to animate, but only observed "
                  << signatures.size() << " unique frame signatures (peak channel "
                  << static_cast<unsigned>(peak_channel) << ").\n";
        return 1;
    }

    if (peak_channel < 8U) {
        std::cerr << "Expected the FFT-driven PolarSpectrumEX preset to light up, but the sampled peak channel was "
                  << static_cast<unsigned>(peak_channel) << ".\n";
        return 1;
    }

    return 0;
}
