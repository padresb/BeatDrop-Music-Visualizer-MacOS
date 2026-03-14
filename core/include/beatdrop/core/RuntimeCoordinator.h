#pragma once

#include "beatdrop/core/Contracts.h"

#include <cstddef>
#include <vector>

namespace beatdrop::core {

struct RuntimeDispatchStats {
    bool services_ready = false;
    std::size_t audio_frames_dispatched = 0;
    std::size_t total_audio_frames_dispatched = 0;
    std::string detail;
};

class RuntimeCoordinator {
public:
    RuntimeCoordinator(AudioCaptureService& audio_capture, PresetEngine& preset_engine);

    RuntimeDispatchStats tick(double delta_seconds);
    std::size_t total_audio_frames_dispatched() const;

private:
    AudioCaptureService& audio_capture_;
    PresetEngine& preset_engine_;
    std::vector<float> audio_scratch_;
    std::size_t total_audio_frames_dispatched_ = 0;
    bool audio_stream_format_applied_ = false;
};

} // namespace beatdrop::core
