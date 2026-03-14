#pragma once

#include <cstddef>
#include <filesystem>
#include <string>
#include <string_view>
#include <vector>

namespace beatdrop::core {

enum class WorkStatus {
    planned,
    in_progress,
    replacement_required,
    ready,
};

struct ResourceStats {
    std::size_t preset_count = 0;
    std::size_t texture_count = 0;
    std::size_t shader_count = 0;
};

struct ReplacementArea {
    std::string subsystem;
    std::string current_backend;
    std::string target_backend;
    WorkStatus status = WorkStatus::planned;
};

struct DeliveryPhase {
    std::string name;
    std::string outcome;
    WorkStatus status = WorkStatus::planned;
};

struct ProjectStatus {
    std::filesystem::path repo_root;
    std::filesystem::path resources_root;
    std::string current_focus;
    ResourceStats resources;
    std::vector<ReplacementArea> replacement_areas;
    std::vector<DeliveryPhase> delivery_phases;
};

std::string_view to_string(WorkStatus status);
ProjectStatus collect_project_status(const std::filesystem::path& repo_root);

} // namespace beatdrop::core
