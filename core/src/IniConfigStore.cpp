#include "beatdrop/core/IniConfigStore.h"

#include <algorithm>
#include <cctype>
#include <fstream>
#include <sstream>
#include <system_error>

namespace beatdrop::core {
namespace {

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

std::string LowercaseCopy(std::string value) {
    std::transform(value.begin(), value.end(), value.begin(), [](unsigned char character) {
        return static_cast<char>(std::tolower(character));
    });
    return value;
}

bool ParseBool(std::string value, bool default_value) {
    value = LowercaseCopy(TrimCopy(std::move(value)));
    if (value == "1" || value == "true" || value == "yes" || value == "on") {
        return true;
    }
    if (value == "0" || value == "false" || value == "no" || value == "off") {
        return false;
    }
    return default_value;
}

std::string NormalizeKey(std::string key) {
    return TrimCopy(std::move(key));
}

} // namespace

IniConfigStore::IniConfigStore(std::filesystem::path file_path)
    : file_path_(std::move(file_path)) {}

bool IniConfigStore::load() {
    std::map<std::string, std::string> parsed_values;
    if (!parse_file(file_path_, parsed_values)) {
        return false;
    }

    values_ = std::move(parsed_values);
    return true;
}

bool IniConfigStore::import_from_file(const std::filesystem::path& file_path, bool overwrite_existing) {
    std::map<std::string, std::string> parsed_values;
    if (!parse_file(file_path, parsed_values)) {
        return false;
    }

    for (auto& [key, value] : parsed_values) {
        if (overwrite_existing || values_.find(key) == values_.end()) {
            values_[key] = value;
        }
    }

    return true;
}

const std::filesystem::path& IniConfigStore::file_path() const {
    return file_path_;
}

std::string IniConfigStore::provider_name() const {
    return "ini-config";
}

bool IniConfigStore::has_key(const std::string& key) const {
    return values_.find(NormalizeKey(key)) != values_.end();
}

std::string IniConfigStore::get_string(const std::string& key, std::string_view default_value) const {
    const auto iterator = values_.find(NormalizeKey(key));
    return iterator == values_.end() ? std::string(default_value) : iterator->second;
}

bool IniConfigStore::get_bool(const std::string& key, bool default_value) const {
    const auto iterator = values_.find(NormalizeKey(key));
    return iterator == values_.end() ? default_value : ParseBool(iterator->second, default_value);
}

std::int64_t IniConfigStore::get_int(const std::string& key, std::int64_t default_value) const {
    const auto iterator = values_.find(NormalizeKey(key));
    if (iterator == values_.end()) {
        return default_value;
    }

    try {
        return std::stoll(iterator->second);
    } catch (...) {
        return default_value;
    }
}

void IniConfigStore::set_string(const std::string& key, std::string value) {
    values_[NormalizeKey(key)] = std::move(value);
}

void IniConfigStore::set_bool(const std::string& key, bool value) {
    values_[NormalizeKey(key)] = value ? "1" : "0";
}

void IniConfigStore::set_int(const std::string& key, std::int64_t value) {
    values_[NormalizeKey(key)] = std::to_string(value);
}

bool IniConfigStore::save() {
    std::error_code error;
    if (!file_path_.parent_path().empty()) {
        std::filesystem::create_directories(file_path_.parent_path(), error);
        if (error) {
            return false;
        }
    }

    std::ofstream stream(file_path_);
    if (!stream.is_open()) {
        return false;
    }

    std::string current_section;
    for (const auto& [key, value] : values_) {
        const std::size_t separator = key.find('.');
        const std::string section = separator == std::string::npos ? std::string("settings") : key.substr(0, separator);
        const std::string entry = separator == std::string::npos ? key : key.substr(separator + 1);

        if (section != current_section) {
            if (!current_section.empty()) {
                stream << '\n';
            }
            stream << '[' << section << "]\n";
            current_section = section;
        }

        stream << entry << '=' << value << '\n';
    }

    return stream.good();
}

bool IniConfigStore::parse_file(const std::filesystem::path& file_path, std::map<std::string, std::string>& destination) {
    std::ifstream stream(file_path);
    if (!stream.is_open()) {
        return false;
    }

    std::string current_section = "settings";
    std::string line;
    while (std::getline(stream, line)) {
        const std::string trimmed = TrimCopy(line);
        if (trimmed.empty()) {
            continue;
        }
        if (trimmed.rfind("//", 0) == 0 || trimmed.front() == ';' || trimmed.front() == '#') {
            continue;
        }
        if (trimmed.front() == '[' && trimmed.back() == ']') {
            current_section = TrimCopy(trimmed.substr(1, trimmed.size() - 2));
            continue;
        }

        const std::size_t separator = trimmed.find('=');
        if (separator == std::string::npos) {
            continue;
        }

        const std::string key = NormalizeKey(trimmed.substr(0, separator));
        const std::string value = TrimCopy(trimmed.substr(separator + 1));
        if (!key.empty()) {
            destination[current_section + "." + key] = value;
        }
    }

    return true;
}

} // namespace beatdrop::core
