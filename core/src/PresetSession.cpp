#include "beatdrop/core/PresetSession.h"

#include <algorithm>
#include <cctype>
#include <fstream>
#include <sstream>
#include <system_error>

namespace beatdrop::core {
namespace {

std::string LowercaseCopy(std::string value) {
    std::transform(value.begin(), value.end(), value.begin(), [](unsigned char character) {
        return static_cast<char>(std::tolower(character));
    });
    return value;
}

std::string TrimCopy(const std::string& value) {
    const auto first = std::find_if_not(value.begin(), value.end(), [](unsigned char character) {
        return std::isspace(character) != 0;
    });
    const auto last = std::find_if_not(value.rbegin(), value.rend(), [](unsigned char character) {
        return std::isspace(character) != 0;
    }).base();

    if (first >= last) {
        return {};
    }

    return std::string(first, last);
}

bool HasMilkExtension(const std::filesystem::path& path) {
    return LowercaseCopy(path.extension().string()) == ".milk";
}

bool CaseInsensitiveRelativePathLess(const PresetDescriptor& lhs, const PresetDescriptor& rhs) {
    return LowercaseCopy(lhs.relative_path.generic_string()) < LowercaseCopy(rhs.relative_path.generic_string());
}

float ClampRating(float value) {
    return std::clamp(value, 0.0F, 5.0F);
}

float ParsePresetRating(const std::filesystem::path& preset_path) {
    std::ifstream stream(preset_path);
    if (!stream.is_open()) {
        return 3.0F;
    }

    bool in_preset_block = false;
    std::string line;
    while (std::getline(stream, line)) {
        const std::string trimmed = TrimCopy(line);
        const std::string lowered = LowercaseCopy(trimmed);

        if (lowered == "[preset00]") {
            in_preset_block = true;
            continue;
        }

        if (!in_preset_block) {
            continue;
        }

        if (!lowered.empty() && lowered.front() == '[') {
            break;
        }

        if (lowered.rfind("frating=", 0) == 0) {
            try {
                return ClampRating(std::stof(trimmed.substr(8)));
            } catch (...) {
                return 3.0F;
            }
        }
    }

    return 3.0F;
}

std::filesystem::path NormalizePath(const std::filesystem::path& path) {
    std::error_code error;
    const std::filesystem::path canonical = std::filesystem::weakly_canonical(path, error);
    return error ? path.lexically_normal() : canonical;
}

} // namespace

PresetSession::PresetSession(std::uint32_t random_seed)
    : random_engine_(random_seed) {}

bool PresetSession::load_library(const std::filesystem::path& root_or_file) {
    const auto previous_presets = presets_;
    const auto previous_history = history_;
    const auto previous_library_root = library_root_;
    const auto previous_detail = last_detail_;
    const auto previous_selection_mode = selection_mode_;
    const std::size_t previous_current_index = current_index_;
    const std::size_t previous_history_cursor = history_cursor_;
    const bool previous_has_active_preset = has_active_preset_;

    if (root_or_file.empty()) {
        last_detail_ = "Preset load failed because no library path was provided.";
        return false;
    }

    std::error_code error;
    if (!std::filesystem::exists(root_or_file, error)) {
        last_detail_ = "Preset load failed because the path does not exist.";
        return false;
    }

    presets_.clear();
    history_.clear();
    library_root_.clear();
    has_active_preset_ = false;
    current_index_ = 0;
    history_cursor_ = 0;

    auto restore_previous_state = [&]() {
        presets_ = previous_presets;
        history_ = previous_history;
        library_root_ = previous_library_root;
        last_detail_ = previous_detail;
        selection_mode_ = previous_selection_mode;
        current_index_ = previous_current_index;
        history_cursor_ = previous_history_cursor;
        has_active_preset_ = previous_has_active_preset;
    };

    const bool is_regular_file = std::filesystem::is_regular_file(root_or_file, error);
    if (!error && is_regular_file) {
        if (!HasMilkExtension(root_or_file)) {
            restore_previous_state();
            last_detail_ = "Preset load failed because the dropped file is not a .milk preset.";
            return false;
        }
        if (!scan_library(root_or_file.parent_path(), root_or_file)) {
            restore_previous_state();
            return false;
        }
        return true;
    }

    if (std::filesystem::is_directory(root_or_file, error)) {
        if (!scan_library(root_or_file, {})) {
            restore_previous_state();
            return false;
        }
        return true;
    }

    restore_previous_state();
    last_detail_ = "Preset load failed because the path is neither a preset file nor a directory.";
    return false;
}

void PresetSession::set_selection_mode(PresetSelectionMode mode) {
    if (selection_mode_ == mode) {
        return;
    }

    selection_mode_ = mode;
    history_.clear();
    if (has_active_preset_) {
        history_.push_back(current_index_);
    }
    history_cursor_ = 0;
    last_detail_ = std::string("Preset order mode switched to ") + std::string(to_string(mode)) + ".";
}

bool PresetSession::activate_preset_by_index(std::size_t index) {
    if (!activate_index(index, true)) {
        last_detail_ = "Preset selection failed because the requested index is out of range.";
        return false;
    }

    last_detail_ = "Preset selected from the scanned library.";
    return true;
}

bool PresetSession::activate_preset(const std::filesystem::path& preset_path) {
    if (preset_path.empty()) {
        last_detail_ = "Preset selection failed because the preset path is empty.";
        return false;
    }

    const std::filesystem::path normalized_target = NormalizePath(preset_path);
    for (std::size_t index = 0; index < presets_.size(); ++index) {
        if (NormalizePath(presets_[index].absolute_path) == normalized_target) {
            if (!activate_index(index, true)) {
                last_detail_ = "Preset selection failed because the preset could not be activated.";
                return false;
            }

            last_detail_ = "Preset selected explicitly.";
            return true;
        }
    }

    last_detail_ = "Preset selection failed because the preset is not in the active library.";
    return false;
}

bool PresetSession::activate_next() {
    if (presets_.empty()) {
        last_detail_ = "Cannot move to the next preset because the library is empty.";
        return false;
    }

    if (!has_active_preset_) {
        return activate_index(0, true);
    }

    if (selection_mode_ == PresetSelectionMode::sequential) {
        const std::size_t next_index = (current_index_ + 1) % presets_.size();
        const bool activated = activate_index(next_index, false);
        if (activated) {
            last_detail_ = "Advanced to the next preset in sequential order.";
        }
        return activated;
    }

    if (!history_.empty() && history_cursor_ + 1 < history_.size()) {
        ++history_cursor_;
        current_index_ = history_[history_cursor_];
        has_active_preset_ = true;
        last_detail_ = "Advanced forward through preset history.";
        return true;
    }

    return activate_random();
}

bool PresetSession::activate_previous() {
    if (presets_.empty()) {
        last_detail_ = "Cannot move to the previous preset because the library is empty.";
        return false;
    }

    if (!has_active_preset_) {
        return activate_index(0, true);
    }

    if (selection_mode_ == PresetSelectionMode::sequential) {
        const std::size_t previous_index = (current_index_ == 0) ? presets_.size() - 1 : current_index_ - 1;
        const bool activated = activate_index(previous_index, false);
        if (activated) {
            last_detail_ = "Moved to the previous preset in sequential order.";
        }
        return activated;
    }

    if (!history_.empty() && history_cursor_ > 0) {
        --history_cursor_;
        current_index_ = history_[history_cursor_];
        has_active_preset_ = true;
        last_detail_ = "Moved backward through preset history.";
        return true;
    }

    last_detail_ = "Preset history is already at the oldest visited entry.";
    return false;
}

bool PresetSession::activate_random() {
    if (presets_.empty()) {
        last_detail_ = "Cannot choose a random preset because the library is empty.";
        return false;
    }

    std::size_t random_index = choose_weighted_random_index();
    if (presets_.size() > 1 && has_active_preset_) {
        for (int attempt = 0; attempt < 8 && random_index == current_index_; ++attempt) {
            random_index = choose_weighted_random_index();
        }
    }

    const bool activated = activate_index(random_index, true);
    if (activated) {
        last_detail_ = "Random preset selection used the scanned preset ratings.";
    }
    return activated;
}

const std::vector<PresetDescriptor>& PresetSession::presets() const {
    return presets_;
}

PresetSessionState PresetSession::describe_state() const {
    PresetSessionState state;
    state.library_loaded = !presets_.empty();
    state.has_active_preset = has_active_preset_;
    state.preset_count = presets_.size();
    state.history_size = history_.size();
    state.current_index = has_active_preset_ ? current_index_ : 0;
    state.can_step_backward = selection_mode_ == PresetSelectionMode::sequential
        ? state.library_loaded
        : (!history_.empty() && history_cursor_ > 0);
    state.can_step_forward = selection_mode_ == PresetSelectionMode::sequential
        ? state.library_loaded
        : (!history_.empty() && history_cursor_ + 1 < history_.size());
    state.selection_mode = selection_mode_;
    state.library_root = library_root_;
    state.detail = last_detail_;

    if (has_active_preset_ && current_index_ < presets_.size()) {
        const auto& preset = presets_[current_index_];
        state.active_preset_path = preset.absolute_path;
        state.active_preset_name = preset.display_name;
        state.active_rating = preset.rating;
    }

    if (state.detail.empty()) {
        std::ostringstream detail;
        detail << "Preset session contains " << state.preset_count << " scanned presets.";
        state.detail = detail.str();
    }

    return state;
}

bool PresetSession::scan_library(const std::filesystem::path& root, const std::filesystem::path& initial_selection) {
    if (root.empty()) {
        last_detail_ = "Preset scan failed because the library root is empty.";
        return false;
    }

    std::error_code error;
    if (!std::filesystem::exists(root, error) || !std::filesystem::is_directory(root, error)) {
        last_detail_ = "Preset scan failed because the library root is not a directory.";
        return false;
    }

    library_root_ = root;
    const std::filesystem::path normalized_root = NormalizePath(root);
    const auto options = std::filesystem::directory_options::skip_permission_denied;

    for (const auto& entry : std::filesystem::recursive_directory_iterator(root, options)) {
        if (!entry.is_regular_file()) {
            continue;
        }
        if (!HasMilkExtension(entry.path())) {
            continue;
        }

        PresetDescriptor preset;
        preset.absolute_path = NormalizePath(entry.path());
        preset.relative_path = preset.absolute_path.lexically_relative(normalized_root);
        if (preset.relative_path.empty()) {
            preset.relative_path = entry.path().filename();
        }
        preset.display_name = preset.relative_path.stem().generic_string();
        preset.rating = ParsePresetRating(entry.path());
        presets_.push_back(std::move(preset));
    }

    std::sort(presets_.begin(), presets_.end(), CaseInsensitiveRelativePathLess);

    if (presets_.empty()) {
        last_detail_ = "Preset scan completed, but no .milk files were found in the selected library.";
        return false;
    }

    std::size_t initial_index = 0;
    if (!initial_selection.empty()) {
        const std::filesystem::path normalized_selection = NormalizePath(initial_selection);
        for (std::size_t index = 0; index < presets_.size(); ++index) {
            if (presets_[index].absolute_path == normalized_selection) {
                initial_index = index;
                break;
            }
        }
    }

    const bool activated = activate_index(initial_index, true);
    if (activated) {
        std::ostringstream detail;
        detail << "Loaded " << presets_.size() << " presets from " << library_root_.filename().generic_string() << '.';
        last_detail_ = detail.str();
    }
    return activated;
}

bool PresetSession::activate_index(std::size_t index, bool update_history) {
    if (index >= presets_.size()) {
        return false;
    }

    current_index_ = index;
    has_active_preset_ = true;

    if (!update_history) {
        return true;
    }

    if (!history_.empty() && history_cursor_ + 1 < history_.size()) {
        history_.erase(history_.begin() + static_cast<std::ptrdiff_t>(history_cursor_ + 1), history_.end());
    }

    if (history_.empty() || history_.back() != index) {
        history_.push_back(index);
        if (history_.size() > kHistoryLimit) {
            const std::size_t overflow = history_.size() - kHistoryLimit;
            history_.erase(history_.begin(), history_.begin() + static_cast<std::ptrdiff_t>(overflow));
        }
    }

    history_cursor_ = history_.empty() ? 0 : history_.size() - 1;
    return true;
}

std::size_t PresetSession::choose_weighted_random_index() const {
    if (presets_.empty()) {
        return 0;
    }

    float rating_sum = 0.0F;
    for (const auto& preset : presets_) {
        rating_sum += std::max(0.0F, preset.rating);
    }

    if (rating_sum < 0.1F) {
        std::uniform_int_distribution<std::size_t> distribution(0, presets_.size() - 1);
        return distribution(random_engine_);
    }

    std::uniform_real_distribution<float> distribution(0.0F, rating_sum);
    const float selected = distribution(random_engine_);

    float cumulative = 0.0F;
    for (std::size_t index = 0; index < presets_.size(); ++index) {
        cumulative += std::max(0.0F, presets_[index].rating);
        if (selected <= cumulative) {
            return index;
        }
    }

    return presets_.size() - 1;
}
std::string_view to_string(PresetSelectionMode mode) {
    switch (mode) {
    case PresetSelectionMode::random:
        return "random";
    case PresetSelectionMode::sequential:
        return "sequential";
    }

    return "random";
}

} // namespace beatdrop::core
