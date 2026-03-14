#pragma once

#include "beatdrop/core/Contracts.h"

#include <cstdint>
#include <memory>
#include <string>

namespace beatdrop::macos {

class MacSyphonOutputPublisher final : public core::OutputPublisher {
public:
    MacSyphonOutputPublisher();
    ~MacSyphonOutputPublisher() override;

    std::string backend_name() const override;
    void set_surface(core::RenderSurfaceDescriptor surface) override;
    bool set_enabled(bool enabled) override;

    bool publish_texture(
        void* cgl_context_handle,
        std::uint32_t texture_name,
        std::uint32_t width_px,
        std::uint32_t height_px,
        bool flipped);

    bool configured() const;
    bool enabled() const;
    bool available() const;
    bool has_clients() const;
    std::string detail() const;

private:
    struct State;

    void release_server();

    core::RenderSurfaceDescriptor surface_;
    std::unique_ptr<State> state_;
    std::string detail_;
    bool enabled_ = false;
};

} // namespace beatdrop::macos
