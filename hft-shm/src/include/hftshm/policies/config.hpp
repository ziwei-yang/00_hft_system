#pragma once

#include <string>
#include <string_view>
#include <optional>
#include <unordered_map>
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

                    // Check if this is a segment config (has 'name' field)
                    if (section.contains("name")) {
                        SegmentConfig config;
                        config.key = full_key;

                        if (auto name = section["name"].value<std::string>()) {
                            config.name = *name;
                        } else {
                            throw ConfigError("Missing 'name' in section [" + config.key + "]");
                        }

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

                        if (auto pair = section["pair"].value<std::string>()) {
                            config.pair = *pair;
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

                        if (auto writer_arr = section["writer"].as_array()) {
                            for (auto& w : *writer_arr) {
                                if (auto ws = w.value<std::string>()) {
                                    config.writer.push_back(*ws);
                                }
                            }
                        }

                        if (auto reader_arr = section["reader"].as_array()) {
                            for (auto& r : *reader_arr) {
                                if (auto rs = r.value<std::string>()) {
                                    config.reader.push_back(*rs);
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
