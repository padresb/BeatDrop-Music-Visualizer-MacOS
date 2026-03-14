#pragma once

#include <cstddef>
#include <mutex>
#include <vector>

namespace beatdrop::core {

class AudioRingBuffer {
public:
    explicit AudioRingBuffer(std::size_t capacity_frames = 44100 * 10);

    std::size_t capacity_frames() const;
    std::size_t available_frames() const;
    void clear();
    void push_interleaved_stereo(const float* frames, std::size_t frame_count);
    std::size_t pop_interleaved_stereo(std::size_t max_frames, std::vector<float>& destination);

private:
    void copy_in(std::size_t destination_frame, const float* source, std::size_t frame_count);
    void copy_out(std::size_t source_frame, float* destination, std::size_t frame_count) const;

    std::size_t capacity_frames_ = 0;
    std::vector<float> storage_;
    std::size_t read_frame_ = 0;
    std::size_t write_frame_ = 0;
    std::size_t size_frames_ = 0;
    mutable std::mutex mutex_;
};

} // namespace beatdrop::core
