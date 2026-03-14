#pragma once

#include "beatdrop/core/Contracts.h"

#include <array>
#include <cstdint>
#include <filesystem>
#include <memory>
#include <string>
#include <string_view>
#include <vector>

namespace beatdrop::macos {

class MacPresetEngine final : public core::PresetEngine {
public:
    MacPresetEngine();
    ~MacPresetEngine() override;

    std::string engine_name() const override;
    void set_audio_stream_format(core::AudioStreamFormat format) override;
    bool load_preset_library(const std::filesystem::path& library_root) override;
    bool set_active_preset(const std::filesystem::path& preset_path) override;
    void set_render_surface(core::RenderSurfaceDescriptor surface) override;
    void ingest_audio_frames(const float* interleaved_stereo_frames, std::size_t frame_count) override;
    void update(double delta_seconds) override;
    core::PresetEngineState describe_state() const override;

    bool has_latest_frame() const;
    std::uint32_t latest_frame_width() const;
    std::uint32_t latest_frame_height() const;
    const std::vector<std::uint8_t>& latest_frame_rgba() const;
    bool has_publishable_texture() const;
    void* publisher_context_handle() const;
    std::uint32_t publisher_texture_name() const;
    bool publisher_texture_flipped() const;

private:
    struct ProjectMRenderer;

    static constexpr std::size_t kHistoryFrameCount = 4096;

    struct PresetDiagnostics {
        std::size_t per_frame_lines = 0;
        std::size_t warp_lines = 0;
        std::size_t comp_lines = 0;
        std::size_t pixel_lines = 0;
        std::size_t wavecode_lines = 0;
        std::size_t shapecode_lines = 0;
        std::size_t image_references = 0;
        bool uses_sampler = false;
        bool load_ok = false;
    };

    float sample_history_at_offset(std::size_t offset_from_oldest) const;
    void refresh_active_preset_diagnostics();
    void ensure_projectm_backend(double delta_seconds);

    std::vector<std::filesystem::path> presets_;
    std::filesystem::path library_root_;
    std::filesystem::path active_preset_path_;
    core::AudioStreamFormat audio_stream_format_;
    core::RenderSurfaceDescriptor surface_;
    std::size_t audio_frames_ingested_ = 0;
    std::size_t update_count_ = 0;
    std::array<float, kHistoryFrameCount> mono_history_ {};
    std::size_t mono_history_cursor_ = 0;
    std::size_t mono_history_count_ = 0;
    float smoothed_peak_ = 0.0F;
    float smoothed_rms_ = 0.0F;
    float smoothed_bass_ = 0.0F;
    float smoothed_mid_ = 0.0F;
    float smoothed_treble_ = 0.0F;
    float low_pass_state_ = 0.0F;
    float mid_pass_state_ = 0.0F;
    double last_delta_seconds_ = 0.0;
    std::unique_ptr<ProjectMRenderer> projectm_renderer_;
    std::vector<std::uint8_t> latest_frame_rgba_;
    std::vector<std::uint8_t> previous_frame_rgba_;
    std::string backend_detail_;
    PresetDiagnostics active_preset_diagnostics_;
    std::filesystem::path diagnosed_preset_path_;
    std::uint32_t latest_frame_width_ = 0;
    std::uint32_t latest_frame_height_ = 0;
    std::uint64_t latest_frame_signature_ = 0;
    float latest_frame_motion_ratio_ = 0.0F;
    std::size_t unchanged_frame_streak_ = 0;
    bool projectm_retry_allowed_ = true;
};

} // namespace beatdrop::macos
