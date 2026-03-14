#include "beatdrop/core/AudioRingBuffer.h"
#include "beatdrop/core/Contracts.h"
#include "beatdrop/core/ProjectStatus.h"
#include "beatdrop/core/RuntimeCoordinator.h"

#include <cassert>

namespace {

class StubAudioCaptureService final : public beatdrop::core::AudioCaptureService {
public:
    std::string backend_name() const override {
        return "stub-audio";
    }

    bool supports_mode(beatdrop::core::AudioInputMode mode) const override {
        return mode == beatdrop::core::AudioInputMode::system_output ||
            mode == beatdrop::core::AudioInputMode::microphone;
    }

    beatdrop::core::AudioStreamFormat stream_format() const override {
        return {};
    }

    std::vector<beatdrop::core::AudioModeInfo> describe_modes() const override {
        return {
            {
                beatdrop::core::AudioInputMode::system_output,
                true,
                capturing_ && active_mode_ == beatdrop::core::AudioInputMode::system_output,
                beatdrop::core::CapturePermissionState::unknown,
                "stub-audio",
                "stub system output mode",
                {},
            },
            {
                beatdrop::core::AudioInputMode::microphone,
                true,
                capturing_ && active_mode_ == beatdrop::core::AudioInputMode::microphone,
                beatdrop::core::CapturePermissionState::granted,
                "stub-audio",
                "stub microphone mode",
                {},
            },
        };
    }

    bool start_capture(beatdrop::core::AudioInputMode mode, const std::string& device_id = {}) override {
        if (mode != beatdrop::core::AudioInputMode::microphone &&
            mode != beatdrop::core::AudioInputMode::system_output) {
            last_error_ = "unsupported mode";
            return false;
        }

        active_mode_ = mode;
        device_id_ = device_id;
        last_error_.clear();
        capturing_ = true;
        ring_buffer_.clear();

        const float frames[] = {
            0.10F, 0.20F,
            0.30F, 0.40F,
            0.50F, 0.60F,
        };
        ring_buffer_.push_interleaved_stereo(frames, 3);
        return true;
    }

    void stop_capture() override {
        capturing_ = false;
        active_mode_ = beatdrop::core::AudioInputMode::system_output;
        ring_buffer_.clear();
    }

    bool is_capturing() const override {
        return capturing_;
    }

    std::size_t buffered_frame_count() const override {
        return ring_buffer_.available_frames();
    }

    std::size_t pop_interleaved_stereo_frames(std::size_t max_frames, std::vector<float>& destination) override {
        return ring_buffer_.pop_interleaved_stereo(max_frames, destination);
    }

    std::string last_error() const override {
        return last_error_;
    }

private:
    beatdrop::core::AudioRingBuffer ring_buffer_;
    bool capturing_ = false;
    beatdrop::core::AudioInputMode active_mode_ = beatdrop::core::AudioInputMode::system_output;
    std::string device_id_;
    std::string last_error_;
};

class StubPresetEngine final : public beatdrop::core::PresetEngine {
public:
    std::string engine_name() const override {
        return "stub-engine";
    }

    void set_audio_stream_format(beatdrop::core::AudioStreamFormat format) override {
        format_ = format;
    }

    bool load_preset_library(const std::filesystem::path& library_root) override {
        library_root_ = library_root;
        return !library_root.empty();
    }

    bool set_active_preset(const std::filesystem::path& preset_path) override {
        active_preset_ = preset_path;
        return !preset_path.empty();
    }

    void set_render_surface(beatdrop::core::RenderSurfaceDescriptor surface) override {
        surface_ = surface;
    }

    void ingest_audio_frames(const float* interleaved_stereo_frames, std::size_t frame_count) override {
        if (interleaved_stereo_frames != nullptr && frame_count > 0) {
            audio_frames_ingested_ += frame_count;
        }
    }

    void update(double delta_seconds) override {
        ++update_count_;
        last_delta_seconds_ = delta_seconds;
    }

    beatdrop::core::PresetEngineState describe_state() const override {
        beatdrop::core::PresetEngineState state;
        state.backend_available = false;
        state.library_loaded = !library_root_.empty();
        state.preset_count = state.library_loaded ? 1 : 0;
        state.audio_frames_ingested = audio_frames_ingested_;
        state.update_count = update_count_;
        state.active_preset_name = !active_preset_.empty() ? active_preset_.stem().string() : (state.library_loaded ? "stub" : "");
        state.detail = "stub state";
        state.surface = surface_;
        return state;
    }

private:
    beatdrop::core::AudioStreamFormat format_;
    std::filesystem::path library_root_;
    std::filesystem::path active_preset_;
    beatdrop::core::RenderSurfaceDescriptor surface_;
    std::size_t audio_frames_ingested_ = 0;
    std::size_t update_count_ = 0;
    double last_delta_seconds_ = 0.0;
};

class StubOutputPublisher final : public beatdrop::core::OutputPublisher {
public:
    std::string backend_name() const override {
        return "stub-output";
    }

    void set_surface(beatdrop::core::RenderSurfaceDescriptor surface) override {
        surface_ = surface;
    }

    bool set_enabled(bool enabled) override {
        enabled_ = enabled;
        return enabled_;
    }

private:
    beatdrop::core::RenderSurfaceDescriptor surface_;
    bool enabled_ = false;
};

class StubConfigStore final : public beatdrop::core::ConfigStore {
public:
    std::string provider_name() const override {
        return "stub-config";
    }

    bool has_key(const std::string& key) const override {
        return key == "settings.audio.mode";
    }

    std::string get_string(const std::string& key, std::string_view default_value = {}) const override {
        return key == "settings.audio.mode" ? "system_output" : std::string(default_value);
    }

    bool get_bool(const std::string& key, bool default_value) const override {
        return key == "settings.bEnablePresetStartup" ? true : default_value;
    }

    std::int64_t get_int(const std::string& key, std::int64_t default_value) const override {
        return key == "settings.nWindowWidth" ? 854 : default_value;
    }

    void set_string(const std::string& key, std::string value) override {
        (void)key;
        (void)value;
    }

    void set_bool(const std::string& key, bool value) override {
        (void)key;
        (void)value;
    }

    void set_int(const std::string& key, std::int64_t value) override {
        (void)key;
        (void)value;
    }

    bool save() override {
        return true;
    }
};

} // namespace

int main() {
    beatdrop::core::AudioRingBuffer ring_buffer(4);
    const float ring_frames[] = {
        0.10F, 0.20F,
        0.30F, 0.40F,
        0.50F, 0.60F,
    };
    ring_buffer.push_interleaved_stereo(ring_frames, 3);
    assert(ring_buffer.available_frames() == 3);

    std::vector<float> ring_output;
    assert(ring_buffer.pop_interleaved_stereo(2, ring_output) == 2);
    assert(ring_output.size() == 4);
    assert(ring_buffer.available_frames() == 1);

    const auto status = beatdrop::core::collect_project_status(BEATDROP_SOURCE_DIR);

    assert(status.resources_root.filename() == "Milkdrop2");
    assert(status.resources.preset_count > 0);
    assert(status.resources.shader_count > 0);
    assert(status.replacement_areas.size() == 4);
    assert(status.delivery_phases.size() >= 7);
    assert(beatdrop::core::to_string(beatdrop::core::WorkStatus::in_progress) == "in progress");
    assert(beatdrop::core::to_string(beatdrop::core::AudioInputMode::microphone) == "microphone");
    assert(beatdrop::core::to_string(beatdrop::core::CapturePermissionState::granted) == "granted");

    StubAudioCaptureService audio_capture;
    StubPresetEngine preset_engine;
    StubOutputPublisher output_publisher;
    StubConfigStore config_store;

    beatdrop::core::RuntimeServices services;
    services.audio_capture = &audio_capture;
    services.preset_engine = &preset_engine;
    services.output_publisher = &output_publisher;
    services.config_store = &config_store;

    beatdrop::core::BeatDropRuntime runtime(services);

    assert(runtime.has_required_services());
    assert(runtime.services().audio_capture->supports_mode(beatdrop::core::AudioInputMode::system_output));
    assert(runtime.services().audio_capture->describe_modes().size() == 2);
    assert(runtime.services().audio_capture->start_capture(beatdrop::core::AudioInputMode::system_output));
    assert(runtime.services().audio_capture->is_capturing());
    runtime.services().audio_capture->stop_capture();
    assert(runtime.services().audio_capture->start_capture(beatdrop::core::AudioInputMode::microphone));
    assert(runtime.services().audio_capture->is_capturing());
    assert(runtime.services().audio_capture->buffered_frame_count() == 3);

    std::vector<float> capture_output;
    assert(runtime.services().audio_capture->pop_interleaved_stereo_frames(2, capture_output) == 2);
    assert(capture_output.size() == 4);
    assert(runtime.services().audio_capture->buffered_frame_count() == 1);

    runtime.services().audio_capture->stop_capture();
    assert(!runtime.services().audio_capture->is_capturing());

    runtime.services().audio_capture->start_capture(beatdrop::core::AudioInputMode::microphone);
    beatdrop::core::RuntimeCoordinator coordinator(audio_capture, preset_engine);
    const auto dispatch = coordinator.tick(1.0 / 60.0);
    assert(dispatch.services_ready);
    assert(dispatch.audio_frames_dispatched == 3);
    assert(dispatch.total_audio_frames_dispatched == 3);
    assert(preset_engine.describe_state().audio_frames_ingested == 3);

    return 0;
}
