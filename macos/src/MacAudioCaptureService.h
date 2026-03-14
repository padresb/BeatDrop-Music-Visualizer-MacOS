#pragma once

#include "beatdrop/core/Contracts.h"

#include <memory>
#include <vector>

namespace beatdrop::macos {

class MacAudioCaptureService final : public core::AudioCaptureService {
public:
    MacAudioCaptureService();
    ~MacAudioCaptureService() override;

    MacAudioCaptureService(const MacAudioCaptureService&) = delete;
    MacAudioCaptureService& operator=(const MacAudioCaptureService&) = delete;

    std::string backend_name() const override;
    bool supports_mode(core::AudioInputMode mode) const override;
    core::AudioStreamFormat stream_format() const override;
    std::vector<core::AudioModeInfo> describe_modes() const override;
    bool start_capture(core::AudioInputMode mode, const std::string& device_id = {}) override;
    void stop_capture() override;
    bool is_capturing() const override;
    std::size_t buffered_frame_count() const override;
    std::size_t pop_interleaved_stereo_frames(std::size_t max_frames, std::vector<float>& destination) override;
    std::string last_error() const override;

private:
    class Impl;
    std::unique_ptr<Impl> impl_;
};

} // namespace beatdrop::macos
