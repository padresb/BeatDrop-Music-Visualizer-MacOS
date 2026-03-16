#include "beatdrop/core/RuntimeCoordinator.h"

namespace beatdrop::core {

RuntimeCoordinator::RuntimeCoordinator(AudioCaptureService& audio_capture, PresetEngine& preset_engine)
    : audio_capture_(audio_capture),
      preset_engine_(preset_engine) {}

RuntimeDispatchStats RuntimeCoordinator::tick(double delta_seconds) {
    RuntimeDispatchStats stats;
    stats.services_ready = true;

    if (!audio_stream_format_applied_) {
        preset_engine_.set_audio_stream_format(audio_capture_.stream_format());
        audio_stream_format_applied_ = true;
    }

    // Drain all buffered audio each tick to stay as close to real-time as
    // possible.  Feeding it in chunks of 2048 keeps the per-call cost
    // reasonable while still emptying the buffer within a single tick.
    std::size_t total_popped = 0;
    for (;;) {
        const std::size_t popped_frames =
            audio_capture_.pop_interleaved_stereo_frames(2048, audio_scratch_);
        if (popped_frames == 0 || audio_scratch_.empty()) {
            break;
        }
        preset_engine_.ingest_audio_frames(audio_scratch_.data(), popped_frames);
        total_popped += popped_frames;
    }

    if (total_popped > 0) {
        total_audio_frames_dispatched_ += total_popped;
        stats.audio_frames_dispatched = total_popped;
        stats.total_audio_frames_dispatched = total_audio_frames_dispatched_;
        stats.detail = "Audio frames dispatched to preset engine.";
    } else {
        stats.total_audio_frames_dispatched = total_audio_frames_dispatched_;
        stats.detail = audio_capture_.is_capturing()
            ? "Capture is live; waiting for buffered PCM."
            : "Capture is idle.";
    }

    preset_engine_.update(delta_seconds);
    return stats;
}

std::size_t RuntimeCoordinator::total_audio_frames_dispatched() const {
    return total_audio_frames_dispatched_;
}

} // namespace beatdrop::core
