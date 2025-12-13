#pragma once

#include <string>
#include <string_view>
#include <optional>
#include <unordered_map>
#include <unordered_set>
#include <vector>
#include <filesystem>
#include <stdexcept>
#include <cstdlib>
#include <functional>

#define TOML_EXCEPTIONS 1
#include <toml.hpp>

#include "../types.hpp"

namespace hftshm::policies {

// Error for config operations
struct ConfigError : std::runtime_error {
    using std::runtime_error::runtime_error;
};

// TOML configuration policy
struct TomlConfigPolicy {
private:
    std::unordered_map<std::string, SegmentConfig> configs_;
    std::string loaded_path_;

public:
    // Resolve config path
    // Priority: explicit path > ./conf/test.toml > ~/hft.toml
    static auto resolve_path(std::string_view path = "") -> std::string {
        if (!path.empty()) {
            return std::string(path);
        }

        // Try ./conf/test.toml first (for testing)
        if (std::filesystem::exists("./conf/test.toml")) {
            return "./conf/test.toml";
        }

        // Try ~/hft.toml
        const char* home = std::getenv("HOME");
        if (home) {
            std::string home_path = std::string(home) + "/hft.toml";
            if (std::filesystem::exists(home_path)) {
                return home_path;
            }
        }

        throw ConfigError("No configuration file found. Tried ./conf/test.toml and ~/hft.toml");
    }

    // Load configuration from file
    auto load(std::string_view path) -> bool {
        configs_.clear();

        try {
            auto resolved = resolve_path(path);
            loaded_path_ = resolved;

            auto tbl = toml::parse_file(resolved);

            // Recursively collect all leaf tables (those with 'name' field)
            std::function<void(const std::string&, const toml::table&)> process_table;
            process_table = [&](const std::string& prefix, const toml::table& table) {
                for (auto& [key, value] : table) {
                    std::string full_key = prefix.empty() ?
                        std::string(key.str()) :
                        prefix + "." + std::string(key.str());

                    if (!value.is_table()) {
                        continue;
                    }

                    auto& section = *value.as_table();

                    // Check if this is a segment config (has 'type' field)
                    if (section.contains("type")) {
                        SegmentConfig config;
                        config.key = full_key;
                        config.name = full_key;  // name = key

                        if (auto type = section["type"].value<std::string>()) {
                            config.type = *type;
                        } else {
                            config.type = "ringbuffer";
                        }

                        if (auto capacity = section["capacity"].value<std::string>()) {
                            config.capacity = parse_size(*capacity);
                        } else if (auto capacity_int = section["capacity"].value<int64_t>()) {
                            config.capacity = static_cast<std::size_t>(*capacity_int);
                        } else {
                            throw ConfigError("Missing 'capacity' in section [" + config.key + "]");
                        }

                        if (auto elem_size = section["element_size"].value<int64_t>()) {
                            config.element_size = static_cast<std::size_t>(*elem_size);
                        } else {
                            config.element_size = 1;
                        }

                        if (auto codec = section["codec"].value<std::string>()) {
                            config.codec = *codec;
                        }

                        if (auto hp_size = section["hugepage_size"].value<std::string>()) {
                            config.hugepage_size = parse_hugepage_size(*hp_size);
                        } else {
                            // Default to auto hugepage selection
                            config.hugepage_size = HUGEPAGE_AUTO;
                        }

                        if (auto max_cons = section["max_consumers"].value<int64_t>()) {
                            config.max_consumers = static_cast<std::size_t>(*max_cons);
                        } else {
                            config.max_consumers = 8;  // Default: 8 consumers
                        }

                        // Capture custom key/value pairs (any unknown keys)
                        static const std::unordered_set<std::string> known_keys = {
                            "type", "capacity", "element_size", "codec", "hugepage_size", "max_consumers"
                        };
                        for (auto& [k, v] : section) {
                            std::string key_str(k.str());
                            if (known_keys.find(key_str) == known_keys.end() && !v.is_table()) {
                                if (auto str_val = v.value<std::string>()) {
                                    config.custom[key_str] = *str_val;
                                } else if (auto int_val = v.value<int64_t>()) {
                                    config.custom[key_str] = std::to_string(*int_val);
                                } else if (auto bool_val = v.value<bool>()) {
                                    config.custom[key_str] = *bool_val ? "true" : "false";
                                } else if (auto dbl_val = v.value<double>()) {
                                    config.custom[key_str] = std::to_string(*dbl_val);
                                }
                            }
                        }

                        configs_[config.key] = std::move(config);
                    } else {
                        // Recurse into nested tables
                        process_table(full_key, section);
                    }
                }
            };

            process_table("", tbl);

            return true;
        } catch (const toml::parse_error& err) {
            throw ConfigError("TOML parse error: " + std::string(err.what()));
        }
    }

    // Get configuration for a specific segment by key
    auto get(std::string_view name) const -> std::optional<SegmentConfig> {
        auto it = configs_.find(std::string(name));
        if (it != configs_.end()) {
            return it->second;
        }
        return std::nullopt;
    }

    // Get all configurations
    auto all() const -> const std::unordered_map<std::string, SegmentConfig>& {
        return configs_;
    }

    // Get loaded config path
    auto loaded_path() const -> std::string_view {
        return loaded_path_;
    }

    // Get config count
    auto size() const -> std::size_t {
        return configs_.size();
    }
};

// Default config policy
using DefaultConfigPolicy = TomlConfigPolicy;

} // namespace hftshm::policies
