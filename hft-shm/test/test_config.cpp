#include <cassert>
#include <iostream>
#include <fstream>
#include <filesystem>

#include <hftshm/policies/config.hpp>

namespace {

// Create a temporary test config file
std::string create_temp_config() {
    std::string path = "/tmp/hftshm_test_config.toml";
    std::ofstream f(path);
    f << R"(
[test.segment1]
type = "ringbuffer"
capacity = "1MB"
element_size = 64
codec = "binary"
hugepage_size = "2MB"
custom_field = "custom_value"
custom_int = 42

[test.segment2]
type = "snapshot"
capacity = 2097152
element_size = 128
)";
    f.close();
    return path;
}

void cleanup_temp_config(const std::string& path) {
    std::filesystem::remove(path);
}

void test_load_config() {
    auto path = create_temp_config();

    hftshm::policies::TomlConfigPolicy config;
    bool loaded = config.load(path);
    assert(loaded);
    assert(config.size() == 2);

    cleanup_temp_config(path);
    std::cout << "  [PASS] load config\n";
}

void test_get_config() {
    auto path = create_temp_config();

    hftshm::policies::TomlConfigPolicy config;
    config.load(path);

    auto cfg1 = config.get("test.segment1");
    assert(cfg1.has_value());
    assert(cfg1->key == "test.segment1");
    assert(cfg1->name == "test.segment1");  // name = key
    assert(cfg1->type == "ringbuffer");
    assert(cfg1->capacity == 1024 * 1024);
    assert(cfg1->element_size == 64);
    assert(cfg1->codec == "binary");
    assert(cfg1->hugepage_size == 2ULL * 1024 * 1024);
    // Check custom attributes
    assert(cfg1->custom.size() == 2);
    assert(cfg1->custom.at("custom_field") == "custom_value");
    assert(cfg1->custom.at("custom_int") == "42");

    cleanup_temp_config(path);
    std::cout << "  [PASS] get config segment1\n";
}

void test_get_config_defaults() {
    auto path = create_temp_config();

    hftshm::policies::TomlConfigPolicy config;
    config.load(path);

    auto cfg2 = config.get("test.segment2");
    assert(cfg2.has_value());
    assert(cfg2->key == "test.segment2");
    assert(cfg2->name == "test.segment2");  // name = key
    assert(cfg2->type == "snapshot");
    assert(cfg2->capacity == 2097152);
    assert(cfg2->element_size == 128);
    // Defaults
    assert(cfg2->hugepage_size == hftshm::HUGEPAGE_AUTO);  // Default: auto hugepages
    assert(cfg2->custom.empty());  // No custom attributes

    cleanup_temp_config(path);
    std::cout << "  [PASS] get config with defaults\n";
}

void test_get_nonexistent() {
    auto path = create_temp_config();

    hftshm::policies::TomlConfigPolicy config;
    config.load(path);

    auto cfg = config.get("nonexistent");
    assert(!cfg.has_value());

    cleanup_temp_config(path);
    std::cout << "  [PASS] get nonexistent\n";
}

void test_all_configs() {
    auto path = create_temp_config();

    hftshm::policies::TomlConfigPolicy config;
    config.load(path);

    const auto& all = config.all();
    assert(all.size() == 2);
    assert(all.count("test.segment1") == 1);
    assert(all.count("test.segment2") == 1);

    cleanup_temp_config(path);
    std::cout << "  [PASS] all configs\n";
}

void test_load_invalid_file() {
    hftshm::policies::TomlConfigPolicy config;

    bool caught = false;
    try {
        config.load("/nonexistent/path/config.toml");
    } catch (const hftshm::policies::ConfigError&) {
        caught = true;
    }
    assert(caught);
    std::cout << "  [PASS] load invalid file\n";
}

} // anonymous namespace

void run_config_tests() {
    std::cout << "Running config tests...\n";
    test_load_config();
    test_get_config();
    test_get_config_defaults();
    test_get_nonexistent();
    test_all_configs();
    test_load_invalid_file();
    std::cout << "All config tests passed!\n\n";
}
