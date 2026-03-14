#pragma once

#include <cstddef>
#include <cstdint>
#include <filesystem>
#include <random>
#include <string>
#include <string_view>
#include <vector>

namespace beatdrop::core {

enum class PresetSelectionMode {
    random,
    sequential,
};

struct PresetDescriptor {
    std::filesystem::path absolute_path;
    std::filesystem::path relative_path;
    std::string display_name;
    float rating = 3.0F;
};

struct PresetSessionState {
    bool library_loaded = false;
    bool has_active_preset = false;
    std::size_t preset_count = 0;
    std::size_t history_size = 0;
    std::size_t current_index = 0;
    bool can_step_backward = false;
    bool can_step_forward = false;
    float active_rating = 0.0F;
    PresetSelectionMode selection_mode = PresetSelectionMode::random;
    std::filesystem::path library_root;
    std::filesystem::path active_preset_path;
    std::string active_preset_name;
    std::string detail;
};

class PresetSession {
public:
    explicit PresetSession(std::uint32_t random_seed = 0xBEA7D0F0U);

    bool load_library(const std::filesystem::path& root_or_file);
    void set_selection_mode(PresetSelectionMode mode);
    bool activate_preset_by_index(std::size_t index);
    bool activate_preset(const std::filesystem::path& preset_path);
    bool activate_next();
    bool activate_previous();
    bool activate_random();

    const std::vector<PresetDescriptor>& presets() const;
    PresetSessionState describe_state() const;

private:
    static constexpr std::size_t kHistoryLimit = 64;

    bool scan_library(const std::filesystem::path& root, const std::filesystem::path& initial_selection);
    bool activate_index(std::size_t index, bool update_history);
    std::size_t choose_weighted_random_index() const;

    std::vector<PresetDescriptor> presets_;
    std::vector<std::size_t> history_;
    std::filesystem::path library_root_;
    std::string last_detail_;
    mutable std::mt19937 random_engine_;
    PresetSelectionMode selection_mode_ = PresetSelectionMode::random;
    std::size_t current_index_ = 0;
    std::size_t history_cursor_ = 0;
    bool has_active_preset_ = false;
};

std::string_view to_string(PresetSelectionMode mode);

} // namespace beatdrop::core
