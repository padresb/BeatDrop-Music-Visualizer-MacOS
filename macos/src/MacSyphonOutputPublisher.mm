#include "MacSyphonOutputPublisher.h"

#include <sstream>

#ifndef BEATDROP_SYPHON_CONFIGURED
#define BEATDROP_SYPHON_CONFIGURED 0
#endif

#ifndef BEATDROP_SYPHON_PROVIDER
#define BEATDROP_SYPHON_PROVIDER "not configured"
#endif

#if BEATDROP_SYPHON_CONFIGURED
#import <OpenGL/OpenGL.h>
#import <OpenGL/gl3.h>
#import <Syphon/SyphonOpenGLServer.h>
#endif

namespace beatdrop::macos {

#if BEATDROP_SYPHON_CONFIGURED
struct MacSyphonOutputPublisher::State {
    SyphonOpenGLServer* server = nil;
    void* context_handle = nullptr;
};
#else
struct MacSyphonOutputPublisher::State {};
#endif

MacSyphonOutputPublisher::MacSyphonOutputPublisher()
    : state_(std::make_unique<State>()) {
    detail_ = BEATDROP_SYPHON_CONFIGURED
        ? std::string("Syphon is configured via ") + BEATDROP_SYPHON_PROVIDER + "."
        : "Syphon is not configured in this build.";
}

MacSyphonOutputPublisher::~MacSyphonOutputPublisher() {
    release_server();
}

std::string MacSyphonOutputPublisher::backend_name() const {
    return BEATDROP_SYPHON_CONFIGURED ? "Syphon OpenGL" : "Syphon unavailable";
}

void MacSyphonOutputPublisher::set_surface(core::RenderSurfaceDescriptor surface) {
    surface_ = surface;
}

bool MacSyphonOutputPublisher::set_enabled(bool enabled) {
    if (!enabled) {
        enabled_ = false;
        release_server();
        detail_ = BEATDROP_SYPHON_CONFIGURED
            ? "Syphon publishing disabled."
            : "Syphon is not configured in this build.";
        return true;
    }

    if (!BEATDROP_SYPHON_CONFIGURED) {
        enabled_ = false;
        detail_ = "Syphon is not configured in this build.";
        return false;
    }

    enabled_ = true;
    detail_ = BEATDROP_SYPHON_CONFIGURED
        ? std::string("Syphon publishing enabled via ") + BEATDROP_SYPHON_PROVIDER + "."
        : "Syphon is not configured in this build.";
    return BEATDROP_SYPHON_CONFIGURED;
}

bool MacSyphonOutputPublisher::publish_texture(
    void* cgl_context_handle,
    std::uint32_t texture_name,
    std::uint32_t width_px,
    std::uint32_t height_px,
    bool flipped) {
#if BEATDROP_SYPHON_CONFIGURED
    if (!enabled_) {
        detail_ = "Syphon publishing is disabled.";
        return false;
    }

    if (cgl_context_handle == nullptr || texture_name == 0 || width_px == 0 || height_px == 0) {
        detail_ = "Syphon is enabled, but the renderer does not have a publishable OpenGL texture yet.";
        return false;
    }

    auto context = static_cast<CGLContextObj>(cgl_context_handle);
    if (state_->server == nil || state_->context_handle != cgl_context_handle) {
        release_server();

        CGLLockContext(context);
        state_->server = [[SyphonOpenGLServer alloc] initWithName:@"BeatDrop Mac Output"
                                                          context:context
                                                          options:nil];
        CGLUnlockContext(context);

        if (state_->server == nil) {
            state_->context_handle = nullptr;
            detail_ = "Syphon framework is configured, but the Syphon server failed to initialize.";
            return false;
        }

        state_->context_handle = cgl_context_handle;
    }

    if (![state_->server hasClients]) {
        std::ostringstream stream;
        stream << "Syphon server live at " << width_px << "x" << height_px << "; waiting for clients.";
        detail_ = stream.str();
        return true;
    }

    CGLLockContext(context);
    [state_->server publishFrameTexture:static_cast<GLuint>(texture_name)
                          textureTarget:GL_TEXTURE_2D
                            imageRegion:NSMakeRect(0.0, 0.0, width_px, height_px)
                      textureDimensions:NSMakeSize(width_px, height_px)
                                flipped:flipped ? YES : NO];
    CGLUnlockContext(context);

    std::ostringstream stream;
    stream << "Publishing " << width_px << "x" << height_px << " frames via Syphon";
    if ([state_->server hasClients]) {
        stream << " to at least one client.";
    } else {
        stream << '.';
    }
    detail_ = stream.str();
    return true;
#else
    (void)cgl_context_handle;
    (void)texture_name;
    (void)width_px;
    (void)height_px;
    (void)flipped;
    detail_ = "Syphon is not configured in this build.";
    return false;
#endif
}

bool MacSyphonOutputPublisher::configured() const {
    return BEATDROP_SYPHON_CONFIGURED;
}

bool MacSyphonOutputPublisher::enabled() const {
    return enabled_;
}

bool MacSyphonOutputPublisher::available() const {
#if BEATDROP_SYPHON_CONFIGURED
    return state_ != nullptr && state_->server != nil;
#else
    return false;
#endif
}

bool MacSyphonOutputPublisher::has_clients() const {
#if BEATDROP_SYPHON_CONFIGURED
    return state_ != nullptr && state_->server != nil && [state_->server hasClients];
#else
    return false;
#endif
}

std::string MacSyphonOutputPublisher::detail() const {
    return detail_;
}

void MacSyphonOutputPublisher::release_server() {
#if BEATDROP_SYPHON_CONFIGURED
    if (state_ != nullptr && state_->server != nil) {
        [state_->server stop];
        state_->server = nil;
        state_->context_handle = nullptr;
    }
#endif
}

} // namespace beatdrop::macos
