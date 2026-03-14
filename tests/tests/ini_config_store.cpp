#include "beatdrop/core/IniConfigStore.h"

#include <cassert>
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

void WriteTextFile(const std::filesystem::path& path, const char* body) {
    std::ofstream stream(path);
    stream << body;
}

} // namespace

int main() {
    ScopedDirectory scoped_directory {
        std::filesystem::temp_directory_path() / "beatdrop-ini-config-store-test"
    };

    std::error_code error;
    std::filesystem::remove_all(scoped_directory.path, error);
    std::filesystem::create_directories(scoped_directory.path);

    const std::filesystem::path defaults_path = scoped_directory.path / "defaults.ini";
    const std::filesystem::path config_path = scoped_directory.path / "beatdrop.ini";

    WriteTextFile(
        defaults_path,
        "[settings]\n"
        "bEnablePresetStartup=1\n"
        "szPresetStartup=BeatDrop Resources\\startuppreset\\Startup.milk\n"
        "// comment\n"
        "[window]\n"
        "width=854\n");

    WriteTextFile(
        config_path,
        "[settings]\n"
        "bEnablePresetStartup=0\n"
        "szPresetDir=/tmp/custom-presets\n");

    beatdrop::core::IniConfigStore store(config_path);
    assert(store.load());
    assert(store.import_from_file(defaults_path, false));
    assert(store.get_bool("settings.bEnablePresetStartup", true) == false);
    assert(store.get_string("settings.szPresetStartup").find("BeatDrop Resources") == 0);
    assert(store.get_int("window.width", 0) == 854);

    store.set_bool("settings.bSequentialPresetOrder", true);
    store.set_int("window.height", 480);
    store.set_string("settings.szPresetDir", "/Users/test/presets");
    assert(store.save());

    beatdrop::core::IniConfigStore reloaded(config_path);
    assert(reloaded.load());
    assert(reloaded.get_bool("settings.bSequentialPresetOrder", false));
    assert(reloaded.get_int("window.height", 0) == 480);
    assert(reloaded.get_string("settings.szPresetDir") == "/Users/test/presets");

    return 0;
}
