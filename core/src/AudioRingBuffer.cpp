#include "beatdrop/core/AudioRingBuffer.h"

#include <algorithm>

namespace beatdrop::core {

AudioRingBuffer::AudioRingBuffer(std::size_t capacity_frames)
    : capacity_frames_(std::max<std::size_t>(capacity_frames, 1)),
      storage_(capacity_frames_ * 2, 0.0F) {}

std::size_t AudioRingBuffer::capacity_frames() const {
    return capacity_frames_;
}

std::size_t AudioRingBuffer::available_frames() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return size_frames_;
}

void AudioRingBuffer::clear() {
    std::lock_guard<std::mutex> lock(mutex_);
    read_frame_ = 0;
    write_frame_ = 0;
    size_frames_ = 0;
}

void AudioRingBuffer::push_interleaved_stereo(const float* frames, std::size_t frame_count) {
    if (frames == nullptr || frame_count == 0) {
        return;
    }

    std::lock_guard<std::mutex> lock(mutex_);
    const std::size_t writable_frames = std::min(frame_count, capacity_frames_ - size_frames_);
    if (writable_frames == 0) {
        return;
    }

    const std::size_t first_span = std::min(writable_frames, capacity_frames_ - write_frame_);
    copy_in(write_frame_, frames, first_span);
    if (writable_frames > first_span) {
        copy_in(0, frames + first_span * 2, writable_frames - first_span);
    }

    write_frame_ = (write_frame_ + writable_frames) % capacity_frames_;
    size_frames_ += writable_frames;
}

std::size_t AudioRingBuffer::pop_interleaved_stereo(std::size_t max_frames, std::vector<float>& destination) {
    std::lock_guard<std::mutex> lock(mutex_);
    const std::size_t readable_frames = std::min(max_frames, size_frames_);
    destination.resize(readable_frames * 2);
    if (readable_frames == 0) {
        return 0;
    }

    const std::size_t first_span = std::min(readable_frames, capacity_frames_ - read_frame_);
    copy_out(read_frame_, destination.data(), first_span);
    if (readable_frames > first_span) {
        copy_out(0, destination.data() + first_span * 2, readable_frames - first_span);
    }

    read_frame_ = (read_frame_ + readable_frames) % capacity_frames_;
    size_frames_ -= readable_frames;
    return readable_frames;
}

void AudioRingBuffer::copy_in(std::size_t destination_frame, const float* source, std::size_t frame_count) {
    std::copy_n(source, frame_count * 2, storage_.data() + destination_frame * 2);
}

void AudioRingBuffer::copy_out(std::size_t source_frame, float* destination, std::size_t frame_count) const {
    std::copy_n(storage_.data() + source_frame * 2, frame_count * 2, destination);
}

} // namespace beatdrop::core
