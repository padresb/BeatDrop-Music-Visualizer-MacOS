#pragma once

#include "beatdrop/core/Contracts.h"

#include <filesystem>
#include <map>
#include <string>

namespace beatdrop::core {

class IniConfigStore final : public ConfigStore {
public:
    explicit IniConfigStore(std::filesystem::path file_path);

    bool load();
    bool import_from_file(const std::filesystem::path& file_path, bool overwrite_existing = false);
    const std::filesystem::path& file_path() const;

    std::string provider_name() const override;
    bool has_key(const std::string& key) const override;
    std::string get_string(const std::string& key, std::string_view default_value = {}) const override;
    bool get_bool(const std::string& key, bool default_value) const override;
    std::int64_t get_int(const std::string& key, std::int64_t default_value) const override;
    void set_string(const std::string& key, std::string value) override;
    void set_bool(const std::string& key, bool value) override;
    void set_int(const std::string& key, std::int64_t value) override;
    bool save() override;

private:
    static bool parse_file(const std::filesystem::path& file_path, std::map<std::string, std::string>& destination);

    std::filesystem::path file_path_;
    std::map<std::string, std::string> values_;
};

} // namespace beatdrop::core
