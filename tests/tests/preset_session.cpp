#include "beatdrop/core/PresetSession.h"

#include <cassert>
#include <chrono>
#include <filesystem>
#include <fstream>
#include <system_error>

namespace {

struct ScopedDirectory {
    std::filesystem::path path;

    ~ScopedDirectory() {
        if (!path.empty()) {
            std::error_code error;
            std::filesystem::remove_all(path, error);
        }
    }
};

void WritePresetFile(const std::filesystem::path& path, const char* body) {
    std::ofstream stream(path);
    stream << body;
}

} // namespace

int main() {
    const auto unique_suffix = std::to_string(
        std::chrono::steady_clock::now().time_since_epoch().count());
    ScopedDirectory scoped_directory {
        std::filesystem::temp_directory_path() / ("beatdrop-preset-session-" + unique_suffix)
    };

    std::filesystem::create_directories(scoped_directory.path / "nested");

    const std::filesystem::path preset_a = scoped_directory.path / "a.milk";
    const std::filesystem::path preset_b = scoped_directory.path / "b.milk";
    const std::filesystem::path preset_c = scoped_directory.path / "nested" / "c.milk";

    WritePresetFile(
        preset_a,
        "MILKDROP_PRESET_VERSION=201\n"
        "[preset00]\n"
        "fRating=1.5\n");
    WritePresetFile(
        preset_b,
        "MILKDROP_PRESET_VERSION=201\n"
        "[preset00]\n"
        "fRating=4.5\n");
    WritePresetFile(
        preset_c,
        "MILKDROP_PRESET_VERSION=201\n"
        "[preset00]\n");

    beatdrop::core::PresetSession session(42U);
    assert(session.load_library(scoped_directory.path));

    auto state = session.describe_state();
    assert(state.library_loaded);
    assert(state.preset_count == 3);
    assert(state.has_active_preset);
    assert(state.active_preset_name == "a");
    assert(state.history_size == 1);
    assert(beatdrop::core::to_string(state.selection_mode) == "random");

    assert(session.activate_preset(preset_b));
    state = session.describe_state();
    assert(state.active_preset_name == "b");
    assert(state.active_rating == 4.5F);
    assert(state.history_size == 2);

    assert(session.activate_preset(preset_c));
    state = session.describe_state();
    assert(state.active_preset_name == "c");
    assert(state.history_size == 3);

    assert(session.activate_previous());
    state = session.describe_state();
    assert(state.active_preset_name == "b");
    assert(state.can_step_forward);

    assert(session.activate_next());
    state = session.describe_state();
    assert(state.active_preset_name == "c");

    session.set_selection_mode(beatdrop::core::PresetSelectionMode::sequential);
    state = session.describe_state();
    assert(beatdrop::core::to_string(state.selection_mode) == "sequential");
    assert(state.history_size == 1);
    assert(state.active_preset_name == "c");

    assert(session.activate_next());
    state = session.describe_state();
    assert(state.active_preset_name == "a");

    assert(session.activate_previous());
    state = session.describe_state();
    assert(state.active_preset_name == "c");

    assert(session.load_library(preset_b));
    state = session.describe_state();
    assert(state.library_loaded);
    assert(state.has_active_preset);
    assert(state.active_preset_name == "b");
    assert(state.history_size == 1);

    return 0;
}
