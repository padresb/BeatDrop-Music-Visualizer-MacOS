#pragma once

#include <array>
#include <cstddef>
#include <cstdint>
#include <filesystem>
#include <string>
#include <string_view>
#include <vector>

namespace beatdrop::core {

enum class AudioInputMode {
    system_output,
    microphone,
};

enum class CapturePermissionState {
    not_required,
    not_determined,
    restricted,
    denied,
    granted,
    unknown,
};

struct AudioStreamFormat {
    std::uint32_t sample_rate_hz = 44100;
    std::uint16_t channel_count = 2;
};

struct AudioDeviceDescriptor {
    std::string id;
    std::string name;
    bool is_default = false;
};

struct AudioModeInfo {
    AudioInputMode mode = AudioInputMode::system_output;
    bool platform_supported = false;
    bool capture_ready = false;
    CapturePermissionState permission_state = CapturePermissionState::unknown;
    std::string backend_name;
    std::string detail;
    std::vector<AudioDeviceDescriptor> devices;
};

struct RenderSurfaceDescriptor {
    std::uint32_t width_px = 0;
    std::uint32_t height_px = 0;
    double scale_factor = 1.0;
};

struct PresetEngineState {
    bool backend_available = false;
    bool library_loaded = false;
    bool supports_live_visualization = false;
    std::size_t preset_count = 0;
    std::size_t audio_frames_ingested = 0;
    std::size_t update_count = 0;
    float audio_peak = 0.0F;
    float audio_rms = 0.0F;
    float bass_energy = 0.0F;
    float mid_energy = 0.0F;
    float treble_energy = 0.0F;
    std::array<float, 48> energy_bars {};
    std::array<float, 96> waveform_preview {};
    std::string active_preset_name;
    std::string detail;
    RenderSurfaceDescriptor surface;
};

class AudioCaptureService {
public:
    virtual ~AudioCaptureService() = default;

    virtual std::string backend_name() const = 0;
    virtual bool supports_mode(AudioInputMode mode) const = 0;
    virtual AudioStreamFormat stream_format() const = 0;
    virtual std::vector<AudioModeInfo> describe_modes() const = 0;
    virtual bool start_capture(AudioInputMode mode, const std::string& device_id = {}) = 0;
    virtual void stop_capture() = 0;
    virtual bool is_capturing() const = 0;
    virtual std::size_t buffered_frame_count() const = 0;
    virtual std::size_t pop_interleaved_stereo_frames(std::size_t max_frames, std::vector<float>& destination) = 0;
    virtual std::string last_error() const = 0;
};

class PresetEngine {
public:
    virtual ~PresetEngine() = default;

    virtual std::string engine_name() const = 0;
    virtual void set_audio_stream_format(AudioStreamFormat format) = 0;
    virtual bool load_preset_library(const std::filesystem::path& library_root) = 0;
    virtual bool set_active_preset(const std::filesystem::path& preset_path) = 0;
    virtual void set_render_surface(RenderSurfaceDescriptor surface) = 0;
    virtual void ingest_audio_frames(const float* interleaved_stereo_frames, std::size_t frame_count) = 0;
    virtual void update(double delta_seconds) = 0;
    virtual PresetEngineState describe_state() const = 0;
};

class OutputPublisher {
public:
    virtual ~OutputPublisher() = default;

    virtual std::string backend_name() const = 0;
    virtual void set_surface(RenderSurfaceDescriptor surface) = 0;
    virtual bool set_enabled(bool enabled) = 0;
};

class ConfigStore {
public:
    virtual ~ConfigStore() = default;

    virtual std::string provider_name() const = 0;
    virtual bool has_key(const std::string& key) const = 0;
    virtual std::string get_string(const std::string& key, std::string_view default_value = {}) const = 0;
    virtual bool get_bool(const std::string& key, bool default_value) const = 0;
    virtual std::int64_t get_int(const std::string& key, std::int64_t default_value) const = 0;
    virtual void set_string(const std::string& key, std::string value) = 0;
    virtual void set_bool(const std::string& key, bool value) = 0;
    virtual void set_int(const std::string& key, std::int64_t value) = 0;
    virtual bool save() = 0;
};

struct RuntimeServices {
    AudioCaptureService* audio_capture = nullptr;
    PresetEngine* preset_engine = nullptr;
    OutputPublisher* output_publisher = nullptr;
    ConfigStore* config_store = nullptr;
};

class BeatDropRuntime {
public:
    explicit BeatDropRuntime(RuntimeServices services) : services_(services) {}

    const RuntimeServices& services() const {
        return services_;
    }

    bool has_required_services() const {
        return services_.audio_capture != nullptr &&
            services_.preset_engine != nullptr &&
            services_.output_publisher != nullptr &&
            services_.config_store != nullptr;
    }

private:
    RuntimeServices services_;
};

std::string_view to_string(AudioInputMode mode);
std::string_view to_string(CapturePermissionState state);

} // namespace beatdrop::core
