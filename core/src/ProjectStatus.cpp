#include "beatdrop/core/ProjectStatus.h"

#include <algorithm>
#include <array>
#include <cctype>
#include <filesystem>
#include <string_view>

namespace beatdrop::core {
namespace {

bool has_extension(const std::filesystem::path& path, std::string_view extension) {
    auto actual = path.extension().string();
    std::transform(actual.begin(), actual.end(), actual.begin(), [](unsigned char c) {
        return static_cast<char>(std::tolower(c));
    });
    return actual == extension;
}

template <std::size_t N>
std::size_t count_files(const std::filesystem::path& root, const std::array<std::string_view, N>& extensions) {
    if (!std::filesystem::exists(root)) {
        return 0;
    }

    std::size_t count = 0;
    const auto options = std::filesystem::directory_options::skip_permission_denied;

    for (const auto& entry : std::filesystem::recursive_directory_iterator(root, options)) {
        if (!entry.is_regular_file()) {
            continue;
        }

        for (const auto extension : extensions) {
            if (has_extension(entry.path(), extension)) {
                ++count;
                break;
            }
        }
    }

    return count;
}

} // namespace

std::string_view to_string(WorkStatus status) {
    switch (status) {
    case WorkStatus::planned:
        return "planned";
    case WorkStatus::in_progress:
        return "in progress";
    case WorkStatus::replacement_required:
        return "replacement required";
    case WorkStatus::ready:
        return "ready";
    }

    return "planned";
}

ProjectStatus collect_project_status(const std::filesystem::path& repo_root) {
    ProjectStatus status;
    status.repo_root = repo_root;
    status.resources_root = repo_root / "resources" / "Milkdrop2";
    status.current_focus = "Phase 3 is active again: preset/session state and system-output PCM are live on macOS, but the real libprojectM renderer still falls back because the first offscreen OpenGL framebuffer for the AppKit preview/Syphon texture is not becoming usable.";
    status.resources.preset_count = count_files(
        status.resources_root / "presets",
        std::array<std::string_view, 1>{".milk"});
    status.resources.texture_count = count_files(
        status.resources_root / "textures",
        std::array<std::string_view, 6>{".dds", ".png", ".jpg", ".jpeg", ".bmp", ".tga"});
    status.resources.shader_count = count_files(
        status.resources_root / "data",
        std::array<std::string_view, 1>{".fx"});

    status.replacement_areas = {
        {
            "Renderer",
            "Direct3D 9 + D3DX",
            "libprojectM-backed macOS renderer behind BeatDropCore",
            WorkStatus::in_progress,
        },
        {
            "Audio capture",
            "WASAPI loopback + microphone",
            "CoreAudio system audio + microphone services",
            WorkStatus::in_progress,
        },
        {
            "Video output",
            "Spout DX9 sender",
            "Syphon publisher",
            WorkStatus::in_progress,
        },
        {
            "Windowing/input",
            "Win32 shell",
            "AppKit shell",
            WorkStatus::in_progress,
        },
    };

    status.delivery_phases = {
        {
            "Phase 0: Architecture freeze",
            "Lock the supported macOS version, parity target, and acceptance criteria.",
            WorkStatus::ready,
        },
        {
            "Phase 1: Shared core scaffold",
            "Create platform-neutral contracts for audio, rendering, output, and config.",
            WorkStatus::ready,
        },
        {
            "Phase 2: Audio subsystem",
            "Implement system-output and microphone capture on macOS.",
            WorkStatus::ready,
        },
        {
            "Phase 3: Render integration",
            "Drive a MilkDrop-compatible renderer from the new core.",
            WorkStatus::in_progress,
        },
        {
            "Phase 4: BeatDrop features",
            "Port BeatDrop-specific behaviors and persistence semantics, with startup/session restore now underway ahead of the full renderer swap.",
            WorkStatus::planned,
        },
        {
            "Phase 5: Native macOS UX",
            "Finish borderless/fullscreen, drag-drop, overlays, and permissions UX.",
            WorkStatus::planned,
        },
        {
            "Phase 6: Syphon output",
            "Publish the render surface to macOS VJ/OBS workflows.",
            WorkStatus::planned,
        },
        {
            "Phase 7: Hardening",
            "Run compatibility, performance, and long-session stability passes.",
            WorkStatus::planned,
        },
    };

    return status;
}

} // namespace beatdrop::core
