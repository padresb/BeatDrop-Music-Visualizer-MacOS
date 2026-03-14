#include "MacPresetEngine.h"

#include <algorithm>
#include <cctype>
#include <cmath>
#include <filesystem>
#include <fstream>
#include <iomanip>
#include <sstream>
#include <string_view>
#include <system_error>
#include <unordered_set>
#include <utility>

#if BEATDROP_PROJECTM_CONFIGURED
#include <OpenGL/OpenGL.h>
#include <OpenGL/gl3.h>
#include <projectM-4/projectM.h>
#endif

#ifndef BEATDROP_PROJECTM_CONFIGURED
#define BEATDROP_PROJECTM_CONFIGURED 0
#endif

#ifndef BEATDROP_PROJECTM_PROVIDER
#define BEATDROP_PROJECTM_PROVIDER "not configured"
#endif

namespace beatdrop::macos {
namespace {

constexpr float kLowPassAlpha = 0.065F;
constexpr float kMidPassAlpha = 0.22F;

float ClampUnit(float value) {
    return std::clamp(value, 0.0F, 1.0F);
}

float NormalizeEnergy(float value, float gain = 2.8F) {
    return ClampUnit(value * gain);
}

bool StartsWith(std::string_view value, std::string_view prefix) {
    return value.substr(0, prefix.size()) == prefix;
}

std::string LowercaseCopy(std::string_view value) {
    std::string copy(value);
    std::transform(copy.begin(), copy.end(), copy.begin(), [](unsigned char ch) {
        return static_cast<char>(std::tolower(ch));
    });
    return copy;
}

std::string_view TrimLeft(std::string_view value) {
    while (!value.empty() && std::isspace(static_cast<unsigned char>(value.front())) != 0) {
        value.remove_prefix(1);
    }
    return value;
}

bool ContainsImageReference(std::string_view line) {
    const std::string lowered = LowercaseCopy(line);
    return lowered.find(".png") != std::string::npos ||
        lowered.find(".jpg") != std::string::npos ||
        lowered.find(".jpeg") != std::string::npos ||
        lowered.find(".bmp") != std::string::npos ||
        lowered.find(".dds") != std::string::npos ||
        lowered.find(".tga") != std::string::npos;
}

bool ContainsSamplerReference(std::string_view line) {
    const std::string lowered = LowercaseCopy(line);
    return lowered.find("sampler_") != std::string::npos ||
        lowered.find("tex_") != std::string::npos ||
        lowered.find("gettex") != std::string::npos ||
        lowered.find("getblur") != std::string::npos;
}

std::pair<std::uint64_t, float> SampleFrameSignatureAndMotion(
    const std::vector<std::uint8_t>& current,
    const std::vector<std::uint8_t>& previous,
    std::uint32_t width,
    std::uint32_t height) {
    if (current.empty()) {
        return { 0U, 0.0F };
    }

    constexpr std::uint64_t kOffset = 1469598103934665603ULL;
    constexpr std::uint64_t kPrime = 1099511628211ULL;
    constexpr std::size_t kGridX = 48U;
    constexpr std::size_t kGridY = 48U;

    std::uint64_t signature = kOffset;
    std::size_t compared_samples = 0;
    float accumulated_delta = 0.0F;

    for (std::size_t grid_y = 0; grid_y < kGridY; ++grid_y) {
        const std::uint32_t y = height == 0
            ? 0U
            : static_cast<std::uint32_t>((grid_y * std::max<std::uint32_t>(1U, height - 1U)) / std::max<std::size_t>(1U, kGridY - 1U));
        for (std::size_t grid_x = 0; grid_x < kGridX; ++grid_x) {
            const std::uint32_t x = width == 0
                ? 0U
                : static_cast<std::uint32_t>((grid_x * std::max<std::uint32_t>(1U, width - 1U)) / std::max<std::size_t>(1U, kGridX - 1U));
            const std::size_t index =
                (static_cast<std::size_t>(y) * static_cast<std::size_t>(width) + static_cast<std::size_t>(x)) * 4U;
            if (index + 3U >= current.size()) {
                continue;
            }

            const float luminance =
                (0.2126F * static_cast<float>(current[index + 0U]) +
                 0.7152F * static_cast<float>(current[index + 1U]) +
                 0.0722F * static_cast<float>(current[index + 2U])) / 255.0F;

            signature ^= static_cast<std::uint64_t>(current[index + 0U]);
            signature *= kPrime;
            signature ^= static_cast<std::uint64_t>(current[index + 1U]);
            signature *= kPrime;
            signature ^= static_cast<std::uint64_t>(current[index + 2U]);
            signature *= kPrime;
            signature ^= static_cast<std::uint64_t>(current[index + 3U]);
            signature *= kPrime;

            if (previous.size() == current.size() && index + 3U < previous.size()) {
                const float previous_luminance =
                    (0.2126F * static_cast<float>(previous[index + 0U]) +
                     0.7152F * static_cast<float>(previous[index + 1U]) +
                     0.0722F * static_cast<float>(previous[index + 2U])) / 255.0F;
                accumulated_delta += std::fabs(luminance - previous_luminance);
                compared_samples += 1U;
            }
        }
    }

    const float motion_ratio = compared_samples == 0
        ? 1.0F
        : accumulated_delta / static_cast<float>(compared_samples);
    return { signature, motion_ratio };
}

bool HasMilkExtension(const std::filesystem::path& path) {
    std::string extension = path.extension().string();
    std::transform(extension.begin(), extension.end(), extension.begin(), [](unsigned char value) {
        return static_cast<char>(std::tolower(value));
    });
    return extension == ".milk";
}

std::filesystem::path NormalizePath(const std::filesystem::path& path) {
    std::error_code error;
    const std::filesystem::path canonical = std::filesystem::weakly_canonical(path, error);
    return error ? path.lexically_normal() : canonical;
}

void AppendSearchPath(
    std::vector<std::filesystem::path>& paths,
    std::unordered_set<std::string>& seen,
    const std::filesystem::path& candidate) {
    if (candidate.empty()) {
        return;
    }

    std::error_code error;
    if (!std::filesystem::is_directory(candidate, error)) {
        return;
    }

    const auto normalized = NormalizePath(candidate);
    const std::string key = normalized.generic_string();
    if (seen.insert(key).second) {
        paths.push_back(normalized);
    }
}

std::vector<std::filesystem::path> BuildTextureSearchPaths(
    const std::filesystem::path& library_root,
    const std::filesystem::path& active_preset_path) {
    std::vector<std::filesystem::path> paths;
    std::unordered_set<std::string> seen;

    const std::filesystem::path repo_root = std::filesystem::path(BEATDROP_SOURCE_DIR);
    const std::filesystem::path bundled_root = repo_root / "resources" / "Milkdrop2";
    const std::filesystem::path bundled_textures = bundled_root / "textures";

    AppendSearchPath(paths, seen, active_preset_path.parent_path());
    AppendSearchPath(paths, seen, library_root);
    AppendSearchPath(paths, seen, library_root / "textures");
    AppendSearchPath(paths, seen, library_root.parent_path());
    AppendSearchPath(paths, seen, library_root.parent_path() / "textures");
    AppendSearchPath(paths, seen, bundled_root);
    AppendSearchPath(paths, seen, bundled_textures);

    return paths;
}

#if BEATDROP_PROJECTM_CONFIGURED

std::string CopyProjectMString(char* value) {
    if (value == nullptr) {
        return {};
    }

    const std::string copy(value);
    projectm_free_string(value);
    return copy;
}

std::string FormatCGLError(CGLError error) {
    const char* description = CGLErrorString(error);
    std::ostringstream stream;
    stream << "CGL error " << static_cast<int>(error);
    if (description != nullptr) {
        stream << ": " << description;
    }
    return stream.str();
}

std::string FormatFramebufferStatus(GLenum status) {
    switch (status) {
    case GL_FRAMEBUFFER_COMPLETE:
        return "GL_FRAMEBUFFER_COMPLETE";
    case GL_FRAMEBUFFER_UNDEFINED:
        return "GL_FRAMEBUFFER_UNDEFINED";
    case GL_FRAMEBUFFER_INCOMPLETE_ATTACHMENT:
        return "GL_FRAMEBUFFER_INCOMPLETE_ATTACHMENT";
    case GL_FRAMEBUFFER_INCOMPLETE_MISSING_ATTACHMENT:
        return "GL_FRAMEBUFFER_INCOMPLETE_MISSING_ATTACHMENT";
    case GL_FRAMEBUFFER_INCOMPLETE_DRAW_BUFFER:
        return "GL_FRAMEBUFFER_INCOMPLETE_DRAW_BUFFER";
    case GL_FRAMEBUFFER_INCOMPLETE_READ_BUFFER:
        return "GL_FRAMEBUFFER_INCOMPLETE_READ_BUFFER";
    case GL_FRAMEBUFFER_UNSUPPORTED:
        return "GL_FRAMEBUFFER_UNSUPPORTED";
    case GL_FRAMEBUFFER_INCOMPLETE_MULTISAMPLE:
        return "GL_FRAMEBUFFER_INCOMPLETE_MULTISAMPLE";
    case GL_FRAMEBUFFER_INCOMPLETE_LAYER_TARGETS:
        return "GL_FRAMEBUFFER_INCOMPLETE_LAYER_TARGETS";
    default: {
        std::ostringstream stream;
        stream << "OpenGL framebuffer status 0x" << std::hex << status;
        return stream.str();
    }
    }
}

void FlipRows(std::vector<std::uint8_t>& pixels, std::uint32_t width, std::uint32_t height) {
    if (pixels.empty() || width == 0 || height < 2) {
        return;
    }

    const std::size_t row_bytes = static_cast<std::size_t>(width) * 4;
    std::vector<std::uint8_t> scratch(row_bytes);

    for (std::uint32_t row = 0; row < height / 2; ++row) {
        std::uint8_t* top = pixels.data() + static_cast<std::size_t>(row) * row_bytes;
        std::uint8_t* bottom = pixels.data() + static_cast<std::size_t>(height - row - 1) * row_bytes;
        std::copy(top, top + row_bytes, scratch.begin());
        std::copy(bottom, bottom + row_bytes, top);
        std::copy(scratch.begin(), scratch.end(), bottom);
    }
}

struct ScopedCurrentContext {
    explicit ScopedCurrentContext(CGLContextObj context)
        : previous_(CGLGetCurrentContext()) {
        if (context != nullptr) {
            CGLSetCurrentContext(context);
        }
    }

    ~ScopedCurrentContext() {
        CGLSetCurrentContext(previous_);
    }

private:
    CGLContextObj previous_ = nullptr;
};

#endif

} // namespace

#if BEATDROP_PROJECTM_CONFIGURED

struct MacPresetEngine::ProjectMRenderer {
    ~ProjectMRenderer() {
        destroy();
    }

    bool ensure_ready(
        const core::RenderSurfaceDescriptor& surface,
        const std::vector<std::filesystem::path>& texture_paths) {
        if (surface.width_px == 0 || surface.height_px == 0) {
            last_error = "Render surface is zero-sized.";
            return false;
        }

        const bool renderer_needs_reconfigure =
            instance == nullptr ||
            configured_surface_width != surface.width_px ||
            configured_surface_height != surface.height_px;

        if (!create_context_and_instance()) {
            return false;
        }

        ScopedCurrentContext current(context);

        if (!apply_texture_search_paths(texture_paths)) {
            return false;
        }

        if (!ensure_render_target(surface.width_px, surface.height_px)) {
            return false;
        }

        if (renderer_needs_reconfigure) {
            projectm_set_window_size(instance, surface.width_px, surface.height_px);
            projectm_set_mesh_size(
                instance,
                std::clamp<std::size_t>(surface.width_px / 24U, 32U, 160U),
                std::clamp<std::size_t>(surface.height_px / 24U, 24U, 120U));
            configured_surface_width = surface.width_px;
            configured_surface_height = surface.height_px;
        }

        width_px = surface.width_px;
        height_px = surface.height_px;
        last_error.clear();
        return true;
    }

    bool load_preset(const std::filesystem::path& preset_path) {
        if (instance == nullptr) {
            last_error = "projectM is not initialized yet.";
            return false;
        }

        ScopedCurrentContext current(context);
        last_error.clear();
        projectm_load_preset_file(instance, preset_path.string().c_str(), false);
        if (!last_error.empty()) {
            return false;
        }

        loaded_preset_path = NormalizePath(preset_path);
        return true;
    }

    void add_audio(const float* interleaved_stereo_frames, std::size_t frame_count) {
        if (instance == nullptr || context == nullptr || interleaved_stereo_frames == nullptr || frame_count == 0) {
            return;
        }

        max_samples = projectm_pcm_get_max_samples();
        const unsigned int clamped = static_cast<unsigned int>(std::min<std::size_t>(frame_count, max_samples));

        ScopedCurrentContext current(context);
        projectm_pcm_add_float(
            instance,
            interleaved_stereo_frames,
            clamped,
            PROJECTM_STEREO);
        audio_frames_sent += clamped;
        audio_calls += 1;
    }

    bool render_frame(double delta_seconds, std::vector<std::uint8_t>& pixels) {
        if (instance == nullptr || context == nullptr || framebuffer == 0 || width_px == 0 || height_px == 0) {
            last_error = "projectM render target is not initialized.";
            return false;
        }

        ScopedCurrentContext current(context);
        glBindFramebuffer(GL_FRAMEBUFFER, framebuffer);
        glDrawBuffer(GL_COLOR_ATTACHMENT0);
        glReadBuffer(GL_COLOR_ATTACHMENT0);
        projectm_set_fps(
            instance,
            std::max<int>(1, static_cast<int>(std::llround(1.0 / std::max(0.001, delta_seconds)))));

        glViewport(0, 0, static_cast<GLsizei>(width_px), static_cast<GLsizei>(height_px));

        projectm_opengl_render_frame(instance);

        // projectM mutates framebuffer bindings internally; rebind the host
        // target explicitly before readback so preview pixels and the published
        // texture come from the same final composited frame.
        glBindFramebuffer(GL_FRAMEBUFFER, framebuffer);
        glDrawBuffer(GL_COLOR_ATTACHMENT0);
        glReadBuffer(GL_COLOR_ATTACHMENT0);

        pixels.resize(static_cast<std::size_t>(width_px) * static_cast<std::size_t>(height_px) * 4U);
        glPixelStorei(GL_PACK_ALIGNMENT, 1);
        glReadPixels(
            0,
            0,
            static_cast<GLsizei>(width_px),
            static_cast<GLsizei>(height_px),
            GL_RGBA,
            GL_UNSIGNED_BYTE,
            pixels.data());
        glFlush();
        glBindFramebuffer(GL_FRAMEBUFFER, 0);

        FlipRows(pixels, width_px, height_px);
        last_error.clear();
        return true;
    }

    bool ready() const {
        return instance != nullptr && context != nullptr && framebuffer != 0 && width_px > 0 && height_px > 0;
    }

    void destroy() {
        if (context != nullptr) {
            ScopedCurrentContext current(context);
            if (instance != nullptr) {
                projectm_destroy(instance);
            }
            destroy_render_target();
        }
        instance = nullptr;

        if (context != nullptr) {
            CGLDestroyContext(context);
            context = nullptr;
        }

        if (pixel_format != nullptr) {
            CGLDestroyPixelFormat(pixel_format);
            pixel_format = nullptr;
        }

        loaded_preset_path.clear();
        texture_search_paths.clear();
        width_px = 0;
        height_px = 0;
        publish_texture_width = 0;
        publish_texture_height = 0;
        configured_surface_width = 0;
        configured_surface_height = 0;
    }

    static void OnPresetSwitchFailed(const char* preset_filename, const char* message, void* user_data) {
        auto* renderer = static_cast<ProjectMRenderer*>(user_data);
        if (renderer == nullptr) {
            return;
        }

        std::ostringstream stream;
        stream << "libprojectM rejected preset";
        if (preset_filename != nullptr && preset_filename[0] != '\0') {
            stream << " '" << preset_filename << "'";
        }
        if (message != nullptr && message[0] != '\0') {
            stream << ": " << message;
        } else {
            stream << '.';
        }
        renderer->last_error = stream.str();
    }

    bool create_context_and_instance() {
        if (context != nullptr && instance != nullptr) {
            return true;
        }

        if (instance != nullptr || context != nullptr || pixel_format != nullptr) {
            destroy();
        }

        struct ProfileAttempt {
            GLint profile_value;
            const char* name;
        };

        constexpr ProfileAttempt attempts[] = {
            { static_cast<GLint>(kCGLOGLPVersion_3_2_Core), "OpenGL 3.2 core" },
            { static_cast<GLint>(kCGLOGLPVersion_Legacy), "OpenGL legacy" },
        };

        for (const auto& attempt : attempts) {
            CGLPixelFormatObj candidate_pixel_format = nullptr;
            CGLContextObj candidate_context = nullptr;
            CGLPixelFormatAttribute attributes[] = {
                kCGLPFAAccelerated,
                kCGLPFAColorSize, static_cast<CGLPixelFormatAttribute>(24),
                kCGLPFAAlphaSize, static_cast<CGLPixelFormatAttribute>(8),
                kCGLPFADepthSize, static_cast<CGLPixelFormatAttribute>(24),
                kCGLPFAOpenGLProfile, static_cast<CGLPixelFormatAttribute>(attempt.profile_value),
                static_cast<CGLPixelFormatAttribute>(0),
            };

            GLint virtual_screens = 0;
            CGLError error = CGLChoosePixelFormat(attributes, &candidate_pixel_format, &virtual_screens);
            if (error != kCGLNoError || candidate_pixel_format == nullptr) {
                candidate_pixel_format = nullptr;
                last_error = std::string("Unable to choose the ") + attempt.name +
                    " pixel format for projectM: " + FormatCGLError(error);
                continue;
            }

            error = CGLCreateContext(candidate_pixel_format, nullptr, &candidate_context);
            if (error != kCGLNoError || candidate_context == nullptr) {
                last_error = std::string("Unable to create the ") + attempt.name +
                    " projectM OpenGL context: " + FormatCGLError(error);
                if (candidate_context != nullptr) {
                    CGLDestroyContext(candidate_context);
                }
                CGLDestroyPixelFormat(candidate_pixel_format);
                continue;
            }

            {
                ScopedCurrentContext current(candidate_context);
                projectm_handle candidate_instance = projectm_create();
                if (candidate_instance != nullptr) {
                    pixel_format = candidate_pixel_format;
                    context = candidate_context;
                    instance = candidate_instance;
                    profile_name = attempt.name;
                    runtime_version = CopyProjectMString(projectm_get_version_string());
                    projectm_set_preset_switch_failed_event_callback(instance, &OnPresetSwitchFailed, this);
                    projectm_set_aspect_correction(instance, true);
                    projectm_set_preset_locked(instance, true);
                    projectm_set_hard_cut_enabled(instance, false);
                    projectm_set_soft_cut_duration(instance, 0.0);
                    projectm_set_preset_duration(instance, 60.0);
                    projectm_set_beat_sensitivity(instance, 1.05F);
                    last_error.clear();
                    return true;
                }
            }

            last_error = std::string("projectm_create() returned null while using the ") + attempt.name +
                " context. The OpenGL context was current but projectM did not initialize.";
            CGLDestroyContext(candidate_context);
            CGLDestroyPixelFormat(candidate_pixel_format);
        }

        return false;
    }

    bool ensure_render_target(std::uint32_t width, std::uint32_t height) {
        if (framebuffer != 0 && publish_texture != 0 && width_px == width && height_px == height) {
            return true;
        }

        destroy_render_target();

        glGenFramebuffers(1, &framebuffer);
        if (framebuffer == 0) {
            last_error = "Unable to allocate the offscreen framebuffer for libprojectM.";
            return false;
        }

        glGenTextures(1, &publish_texture);
        if (publish_texture == 0) {
            last_error = "Unable to allocate the offscreen color texture for libprojectM.";
            destroy_render_target();
            return false;
        }

        glBindTexture(GL_TEXTURE_2D, publish_texture);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
        glTexImage2D(
            GL_TEXTURE_2D,
            0,
            GL_RGBA8,
            static_cast<GLsizei>(width),
            static_cast<GLsizei>(height),
            0,
            GL_RGBA,
            GL_UNSIGNED_BYTE,
            nullptr);

        glGenRenderbuffers(1, &depth_renderbuffer);
        if (depth_renderbuffer == 0) {
            last_error = "Unable to allocate the offscreen depth buffer for libprojectM.";
            destroy_render_target();
            return false;
        }

        glBindRenderbuffer(GL_RENDERBUFFER, depth_renderbuffer);
        glRenderbufferStorage(
            GL_RENDERBUFFER,
            GL_DEPTH_COMPONENT24,
            static_cast<GLsizei>(width),
            static_cast<GLsizei>(height));

        glBindFramebuffer(GL_FRAMEBUFFER, framebuffer);
        glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, publish_texture, 0);
        glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_DEPTH_ATTACHMENT, GL_RENDERBUFFER, depth_renderbuffer);

        const GLenum status = glCheckFramebufferStatus(GL_FRAMEBUFFER);
        glBindFramebuffer(GL_FRAMEBUFFER, 0);
        glBindRenderbuffer(GL_RENDERBUFFER, 0);
        glBindTexture(GL_TEXTURE_2D, 0);
        if (status != GL_FRAMEBUFFER_COMPLETE) {
            last_error = "libprojectM framebuffer setup failed: " + FormatFramebufferStatus(status);
            destroy_render_target();
            return false;
        }

        width_px = width;
        height_px = height;
        publish_texture_width = width;
        publish_texture_height = height;
        return true;
    }

    bool apply_texture_search_paths(const std::vector<std::filesystem::path>& texture_paths) {
        if (instance == nullptr) {
            return false;
        }

        if (texture_paths == texture_search_paths) {
            return true;
        }

        std::vector<std::string> encoded_paths;
        encoded_paths.reserve(texture_paths.size());
        std::vector<const char*> raw_paths;
        raw_paths.reserve(texture_paths.size());

        for (const auto& path : texture_paths) {
            encoded_paths.push_back(path.string());
        }
        for (const auto& path : encoded_paths) {
            raw_paths.push_back(path.c_str());
        }

        projectm_set_texture_search_paths(instance, raw_paths.data(), raw_paths.size());
        texture_search_paths = texture_paths;
        return true;
    }

    void destroy_render_target() {
        if (depth_renderbuffer != 0) {
            glDeleteRenderbuffers(1, &depth_renderbuffer);
            depth_renderbuffer = 0;
        }
        if (framebuffer != 0) {
            glDeleteFramebuffers(1, &framebuffer);
            framebuffer = 0;
        }
        if (publish_texture != 0) {
            glDeleteTextures(1, &publish_texture);
            publish_texture = 0;
        }
        publish_texture_width = 0;
        publish_texture_height = 0;
    }

    CGLPixelFormatObj pixel_format = nullptr;
    CGLContextObj context = nullptr;
    projectm_handle instance = nullptr;
    std::filesystem::path loaded_preset_path;
    std::vector<std::filesystem::path> texture_search_paths;
    std::string runtime_version;
    std::string profile_name;
    std::string last_error;
    std::uint32_t width_px = 0;
    std::uint32_t height_px = 0;
    GLuint framebuffer = 0;
    GLuint depth_renderbuffer = 0;
    GLuint publish_texture = 0;
    std::uint32_t publish_texture_width = 0;
    std::uint32_t publish_texture_height = 0;
    std::uint32_t configured_surface_width = 0;
    std::uint32_t configured_surface_height = 0;
    std::size_t audio_frames_sent = 0;
    std::size_t audio_calls = 0;
    unsigned int max_samples = 0;
};

#endif

MacPresetEngine::MacPresetEngine() = default;

MacPresetEngine::~MacPresetEngine() = default;

std::string MacPresetEngine::engine_name() const {
#if BEATDROP_PROJECTM_CONFIGURED
    if (projectm_renderer_ && projectm_renderer_->ready()) {
        std::ostringstream stream;
        stream << "libprojectM";
        if (!projectm_renderer_->runtime_version.empty()) {
            stream << ' ' << projectm_renderer_->runtime_version;
        }
        stream << " offscreen OpenGL renderer";
        return stream.str();
    }
    return "libprojectM configured + telemetry fallback";
#else
    return "native fallback renderer";
#endif
}

void MacPresetEngine::set_audio_stream_format(core::AudioStreamFormat format) {
    audio_stream_format_ = format;
}

bool MacPresetEngine::load_preset_library(const std::filesystem::path& library_root) {
    library_root_ = library_root;
    presets_.clear();
    active_preset_path_.clear();
    diagnosed_preset_path_.clear();
    active_preset_diagnostics_ = {};
    previous_frame_rgba_.clear();
    latest_frame_signature_ = 0;
    latest_frame_motion_ratio_ = 0.0F;
    unchanged_frame_streak_ = 0;
    projectm_retry_allowed_ = true;

    if (!std::filesystem::exists(library_root_)) {
        return false;
    }

    const auto options = std::filesystem::directory_options::skip_permission_denied;
    for (const auto& entry : std::filesystem::recursive_directory_iterator(library_root_, options)) {
        if (entry.is_regular_file() && HasMilkExtension(entry.path())) {
            presets_.push_back(entry.path());
        }
    }

    std::sort(presets_.begin(), presets_.end());
    if (!presets_.empty()) {
        active_preset_path_ = presets_.front();
    }

    return !presets_.empty();
}

bool MacPresetEngine::set_active_preset(const std::filesystem::path& preset_path) {
    if (preset_path.empty() || !HasMilkExtension(preset_path) || !std::filesystem::exists(preset_path)) {
        return false;
    }

    auto mark_preset_switch = [&]() {
        diagnosed_preset_path_.clear();
        active_preset_diagnostics_ = {};
        previous_frame_rgba_.clear();
        latest_frame_signature_ = 0;
        latest_frame_motion_ratio_ = 0.0F;
        unchanged_frame_streak_ = 0;
    };

    const std::filesystem::path normalized_target = NormalizePath(preset_path);
    for (const auto& preset : presets_) {
        if (NormalizePath(preset) == normalized_target) {
            active_preset_path_ = preset;
            mark_preset_switch();
            return true;
        }
    }

    if (NormalizePath(preset_path.parent_path()) == NormalizePath(library_root_)) {
        active_preset_path_ = preset_path;
        mark_preset_switch();
        return true;
    }

    return false;
}

void MacPresetEngine::set_render_surface(core::RenderSurfaceDescriptor surface) {
    if (surface_.width_px != surface.width_px || surface_.height_px != surface.height_px) {
        projectm_retry_allowed_ = true;
    }
    surface_ = surface;
}

void MacPresetEngine::ingest_audio_frames(const float* interleaved_stereo_frames, std::size_t frame_count) {
    if (interleaved_stereo_frames == nullptr || frame_count == 0) {
        return;
    }

    audio_frames_ingested_ += frame_count;

    float frame_peak = 0.0F;
    float squared_sum = 0.0F;
    float bass_sum = 0.0F;
    float mid_sum = 0.0F;
    float treble_sum = 0.0F;

    for (std::size_t index = 0; index < frame_count; ++index) {
        const float left = interleaved_stereo_frames[index * 2];
        const float right = interleaved_stereo_frames[index * 2 + 1];
        const float mono = (left + right) * 0.5F;

        mono_history_[mono_history_cursor_] = mono;
        mono_history_cursor_ = (mono_history_cursor_ + 1) % mono_history_.size();
        mono_history_count_ = std::min(mono_history_count_ + 1, mono_history_.size());

        const float absolute = std::fabs(mono);
        frame_peak = std::max(frame_peak, absolute);
        squared_sum += mono * mono;

        low_pass_state_ += kLowPassAlpha * (mono - low_pass_state_);
        const float high_residual = mono - low_pass_state_;
        mid_pass_state_ += kMidPassAlpha * (high_residual - mid_pass_state_);

        bass_sum += std::fabs(low_pass_state_);
        mid_sum += std::fabs(mid_pass_state_);
        treble_sum += std::fabs(high_residual - mid_pass_state_);
    }

    const float frame_rms = std::sqrt(squared_sum / static_cast<float>(frame_count));
    smoothed_peak_ = smoothed_peak_ * 0.78F + frame_peak * 0.22F;
    smoothed_rms_ = smoothed_rms_ * 0.82F + frame_rms * 0.18F;
    smoothed_bass_ = smoothed_bass_ * 0.74F + NormalizeEnergy(bass_sum / static_cast<float>(frame_count)) * 0.26F;
    smoothed_mid_ = smoothed_mid_ * 0.74F + NormalizeEnergy(mid_sum / static_cast<float>(frame_count)) * 0.26F;
    smoothed_treble_ = smoothed_treble_ * 0.74F + NormalizeEnergy(treble_sum / static_cast<float>(frame_count)) * 0.26F;

#if BEATDROP_PROJECTM_CONFIGURED
    if (projectm_renderer_ && projectm_renderer_->ready()) {
        projectm_renderer_->add_audio(interleaved_stereo_frames, frame_count);
    }
#endif
}

void MacPresetEngine::update(double delta_seconds) {
    ++update_count_;
    last_delta_seconds_ = delta_seconds;
    ensure_projectm_backend(delta_seconds);
}

bool MacPresetEngine::has_latest_frame() const {
    return latest_frame_width_ > 0 &&
        latest_frame_height_ > 0 &&
        latest_frame_rgba_.size() ==
            static_cast<std::size_t>(latest_frame_width_) * static_cast<std::size_t>(latest_frame_height_) * 4U;
}

std::uint32_t MacPresetEngine::latest_frame_width() const {
    return latest_frame_width_;
}

std::uint32_t MacPresetEngine::latest_frame_height() const {
    return latest_frame_height_;
}

const std::vector<std::uint8_t>& MacPresetEngine::latest_frame_rgba() const {
    return latest_frame_rgba_;
}

bool MacPresetEngine::has_publishable_texture() const {
#if BEATDROP_PROJECTM_CONFIGURED
    return projectm_renderer_ != nullptr &&
        projectm_renderer_->ready() &&
        projectm_renderer_->publish_texture != 0;
#else
    return false;
#endif
}

void* MacPresetEngine::publisher_context_handle() const {
#if BEATDROP_PROJECTM_CONFIGURED
    return has_publishable_texture() ? static_cast<void*>(projectm_renderer_->context) : nullptr;
#else
    return nullptr;
#endif
}

std::uint32_t MacPresetEngine::publisher_texture_name() const {
#if BEATDROP_PROJECTM_CONFIGURED
    return has_publishable_texture() ? static_cast<std::uint32_t>(projectm_renderer_->publish_texture) : 0U;
#else
    return 0U;
#endif
}

bool MacPresetEngine::publisher_texture_flipped() const {
    return false;
}

float MacPresetEngine::sample_history_at_offset(std::size_t offset_from_oldest) const {
    if (mono_history_count_ == 0) {
        return 0.0F;
    }

    const std::size_t clamped_offset = std::min(offset_from_oldest, mono_history_count_ - 1);
    const std::size_t oldest_index =
        (mono_history_cursor_ + mono_history_.size() - mono_history_count_) % mono_history_.size();
    const std::size_t index = (oldest_index + clamped_offset) % mono_history_.size();
    return mono_history_[index];
}

void MacPresetEngine::refresh_active_preset_diagnostics() {
    if (active_preset_path_.empty() || diagnosed_preset_path_ == NormalizePath(active_preset_path_)) {
        return;
    }

    active_preset_diagnostics_ = {};
    diagnosed_preset_path_ = NormalizePath(active_preset_path_);

    std::ifstream stream(diagnosed_preset_path_);
    if (!stream.is_open()) {
        return;
    }

    active_preset_diagnostics_.load_ok = true;

    std::string line;
    while (std::getline(stream, line)) {
        const std::string_view trimmed = TrimLeft(line);
        if (StartsWith(trimmed, "per_frame_") || StartsWith(trimmed, "per_frame_init_")) {
            active_preset_diagnostics_.per_frame_lines += 1;
        }
        if (StartsWith(trimmed, "warp_")) {
            active_preset_diagnostics_.warp_lines += 1;
        }
        if (StartsWith(trimmed, "comp_")) {
            active_preset_diagnostics_.comp_lines += 1;
        }
        if (StartsWith(trimmed, "per_pixel_")) {
            active_preset_diagnostics_.pixel_lines += 1;
        }
        if (StartsWith(trimmed, "wavecode_") || StartsWith(trimmed, "wave_")) {
            active_preset_diagnostics_.wavecode_lines += 1;
        }
        if (StartsWith(trimmed, "shapecode_")) {
            active_preset_diagnostics_.shapecode_lines += 1;
        }
        active_preset_diagnostics_.image_references += ContainsImageReference(trimmed) ? 1U : 0U;
        active_preset_diagnostics_.uses_sampler =
            active_preset_diagnostics_.uses_sampler || ContainsSamplerReference(trimmed);
    }
}

void MacPresetEngine::ensure_projectm_backend(double delta_seconds) {
#if BEATDROP_PROJECTM_CONFIGURED
    if (surface_.width_px == 0 || surface_.height_px == 0) {
        latest_frame_rgba_.clear();
        latest_frame_width_ = 0;
        latest_frame_height_ = 0;
        backend_detail_ = "Waiting for a non-zero render surface before starting libprojectM.";
        return;
    }

    if (!projectm_retry_allowed_ && (!projectm_renderer_ || !projectm_renderer_->ready())) {
        return;
    }

    if (!projectm_renderer_) {
        projectm_renderer_ = std::make_unique<ProjectMRenderer>();
    }

    const auto texture_search_paths = BuildTextureSearchPaths(library_root_, active_preset_path_);
    if (!projectm_renderer_->ensure_ready(surface_, texture_search_paths)) {
        latest_frame_rgba_.clear();
        latest_frame_width_ = 0;
        latest_frame_height_ = 0;
        backend_detail_ = projectm_renderer_->last_error;
        projectm_retry_allowed_ = false;
        return;
    }

    projectm_retry_allowed_ = true;
    refresh_active_preset_diagnostics();

    if (!active_preset_path_.empty()) {
        const auto normalized_active_preset = NormalizePath(active_preset_path_);
        if (projectm_renderer_->loaded_preset_path != normalized_active_preset &&
            !projectm_renderer_->load_preset(normalized_active_preset)) {
            latest_frame_rgba_.clear();
            latest_frame_width_ = 0;
            latest_frame_height_ = 0;
            backend_detail_ = projectm_renderer_->last_error;
            return;
        }
    }

    if (!projectm_renderer_->render_frame(delta_seconds, latest_frame_rgba_)) {
        latest_frame_rgba_.clear();
        latest_frame_width_ = 0;
        latest_frame_height_ = 0;
        backend_detail_ = projectm_renderer_->last_error;
        return;
    }

    const auto [signature, motion_ratio] =
        SampleFrameSignatureAndMotion(
            latest_frame_rgba_,
            previous_frame_rgba_,
            projectm_renderer_->width_px,
            projectm_renderer_->height_px);
    latest_frame_signature_ = signature;
    latest_frame_motion_ratio_ = motion_ratio;
    if (!previous_frame_rgba_.empty() && motion_ratio <= 0.0005F) {
        unchanged_frame_streak_ += 1U;
    } else {
        unchanged_frame_streak_ = 0;
    }
    previous_frame_rgba_ = latest_frame_rgba_;

    latest_frame_width_ = projectm_renderer_->width_px;
    latest_frame_height_ = projectm_renderer_->height_px;
    backend_detail_.clear();
#else
    (void)delta_seconds;
#endif
}

core::PresetEngineState MacPresetEngine::describe_state() const {
    core::PresetEngineState state;
    state.backend_available = has_latest_frame();
    state.library_loaded = !presets_.empty();
    state.supports_live_visualization = true;
    state.preset_count = presets_.size();
    state.audio_frames_ingested = audio_frames_ingested_;
    state.update_count = update_count_;
    state.audio_peak = ClampUnit(smoothed_peak_);
    state.audio_rms = ClampUnit(smoothed_rms_ * 2.0F);
    state.bass_energy = ClampUnit(smoothed_bass_);
    state.mid_energy = ClampUnit(smoothed_mid_);
    state.treble_energy = ClampUnit(smoothed_treble_);
    state.surface = surface_;
    state.active_preset_name = active_preset_path_.empty() ? std::string() : active_preset_path_.stem().string();

    if (mono_history_count_ > 0) {
        for (std::size_t index = 0; index < state.waveform_preview.size(); ++index) {
            const std::size_t offset = (mono_history_count_ == 1 || state.waveform_preview.size() == 1)
                ? 0
                : (index * (mono_history_count_ - 1)) / (state.waveform_preview.size() - 1);
            state.waveform_preview[index] = sample_history_at_offset(offset);
        }

        for (std::size_t index = 0; index < state.energy_bars.size(); ++index) {
            const std::size_t start = (index * mono_history_count_) / state.energy_bars.size();
            const std::size_t end = std::max(
                start + 1,
                ((index + 1) * mono_history_count_) / state.energy_bars.size());

            float amplitude_sum = 0.0F;
            for (std::size_t sample = start; sample < end; ++sample) {
                amplitude_sum += std::fabs(sample_history_at_offset(sample));
            }

            const float average_amplitude =
                amplitude_sum / static_cast<float>(std::max<std::size_t>(1, end - start));
            state.energy_bars[index] = ClampUnit(std::pow(average_amplitude * 3.2F, 0.85F));
        }
    }

    std::ostringstream detail;
#if BEATDROP_PROJECTM_CONFIGURED
    if (state.backend_available && projectm_renderer_) {
        detail << "libprojectM is rendering live via " << projectm_renderer_->profile_name;
        if (!projectm_renderer_->runtime_version.empty()) {
            detail << " (" << projectm_renderer_->runtime_version << ")";
        }
        detail << " with a " << latest_frame_width_ << "x" << latest_frame_height_ << " offscreen surface."
               << " pM-audio: " << projectm_renderer_->audio_frames_sent
               << " frames in " << projectm_renderer_->audio_calls
               << " calls (max_samples=" << projectm_renderer_->max_samples << ").";
    } else {
        if (!backend_detail_.empty()) {
            detail << backend_detail_ << ' ';
        }
        detail << "libprojectM is configured via " << BEATDROP_PROJECTM_PROVIDER
               << ", but the native telemetry fallback is active while the render backend warms up.";
    }
#else
    detail << "Native fallback renderer is live and driven by the shared PCM pipeline.";
#endif

    if (state.library_loaded) {
        detail << " Loaded " << state.preset_count << " preset files from "
               << library_root_.filename().string() << '.';
    } else {
        detail << " Preset inventory is not loaded.";
    }

    if (!active_preset_path_.empty()) {
        detail << " Active preset: " << active_preset_path_.filename().string() << '.';
    }

    if (active_preset_diagnostics_.load_ok) {
        detail << " Preset source: per_frame=" << active_preset_diagnostics_.per_frame_lines
               << ", warp=" << active_preset_diagnostics_.warp_lines
               << ", comp=" << active_preset_diagnostics_.comp_lines
               << ", per_pixel=" << active_preset_diagnostics_.pixel_lines
               << ", wavecode=" << active_preset_diagnostics_.wavecode_lines
               << ", shapecode=" << active_preset_diagnostics_.shapecode_lines
               << ", image_refs=" << active_preset_diagnostics_.image_references
               << ", sampler_refs=" << (active_preset_diagnostics_.uses_sampler ? "yes" : "no") << '.';
    } else if (!active_preset_path_.empty()) {
        detail << " Preset source diagnostics could not be loaded from disk.";
    }

    if (state.backend_available && !backend_detail_.empty()) {
        detail << ' ' << backend_detail_;
    }

    if (state.backend_available) {
        std::ostringstream frame_debug;
        frame_debug << std::hex << latest_frame_signature_;
        detail << " Frame motion(luma-grid) " << latest_frame_motion_ratio_
               << ", static-streak " << unchanged_frame_streak_
               << ", signature 0x" << frame_debug.str() << '.';
    }

    detail << " Peak " << state.audio_peak << ", RMS " << state.audio_rms
           << ", frame dt " << last_delta_seconds_ << "s.";
    state.detail = detail.str();

    return state;
}

} // namespace beatdrop::macos
