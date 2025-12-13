#include <cassert>
#include <iostream>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <fstream>

#include <hftshm/types.hpp>
#include <hftshm/policies/platform.hpp>
#include <hftshm/policies/config.hpp>

namespace {

using Platform = hftshm::policies::DefaultPlatformPolicy;
using Config = hftshm::policies::TomlConfigPolicy;

const char* TEST_SEGMENT = "test.mktdata.binance.raw.rx";
const char* HOME_CONFIG = nullptr;  // Will be set in main

void test_init_segment() {
    Config config;
    Platform platform;

    // Load from ~/hft.toml
    config.load(HOME_CONFIG);

    auto cfg = config.get(TEST_SEGMENT);
    assert(cfg.has_value());
    assert(cfg->name == TEST_SEGMENT);  // name = key
    assert(cfg->type == "ringbuffer");
    assert(cfg->capacity == 4ULL * 1024 * 1024);  // 4MB
    assert(cfg->element_size == 1);
    assert(cfg->codec == "string");

    // Create segment
    int fd = platform.create(TEST_SEGMENT, cfg->capacity, cfg->hugepage_size);
    assert(fd >= 0);

    void* ptr = platform.map(fd, cfg->capacity, cfg->hugepage_size);
    assert(ptr != nullptr);

    // Zero-initialize
    std::memset(ptr, 0, cfg->capacity);

    platform.unmap(ptr, cfg->capacity);
    platform.close_fd(fd);

    // Verify exists
    auto info = platform.get_info(TEST_SEGMENT);
    assert(info.exists);
    assert(info.size == cfg->capacity);

    std::cout << "  [PASS] init segment\n";
}

void test_write_and_verify() {
    Platform platform;

    int fd = platform.open(TEST_SEGMENT);
    assert(fd >= 0);

    std::size_t size = platform.get_size(fd);
    assert(size == 4ULL * 1024 * 1024);  // 4MB

    void* ptr = platform.map(fd, size, 0);
    assert(ptr != nullptr);

    // Write test pattern
    const char* test_data = "Hello HFT Shared Memory!";
    std::size_t data_len = std::strlen(test_data);
    std::memcpy(ptr, test_data, data_len);

    // Verify
    assert(std::memcmp(ptr, test_data, data_len) == 0);

    platform.unmap(ptr, size);
    platform.close_fd(fd);

    std::cout << "  [PASS] write and verify\n";
}

void test_reset_segment() {
    Platform platform;

    int fd = platform.open(TEST_SEGMENT);
    assert(fd >= 0);

    std::size_t size = platform.get_size(fd);
    void* ptr = platform.map(fd, size, 0);
    assert(ptr != nullptr);

    // Reset (zero out)
    std::memset(ptr, 0, size);

    // Verify first bytes are zero
    unsigned char* bytes = static_cast<unsigned char*>(ptr);
    for (std::size_t i = 0; i < 100; ++i) {
        assert(bytes[i] == 0);
    }

    platform.unmap(ptr, size);
    platform.close_fd(fd);

    std::cout << "  [PASS] reset segment\n";
}

void test_dump_segment() {
    Platform platform;
    const char* dump_file = "/tmp/hftshm_integration_dump.bin";

    int fd = platform.open(TEST_SEGMENT);
    assert(fd >= 0);

    std::size_t size = platform.get_size(fd);
    void* ptr = platform.map(fd, size, 0);
    assert(ptr != nullptr);

    // Write some data first
    const char* test_data = "Integration test data for dump";
    std::memcpy(ptr, test_data, std::strlen(test_data));

    // Dump to file
    std::ofstream out(dump_file, std::ios::binary);
    assert(out.is_open());
    out.write(static_cast<const char*>(ptr), static_cast<std::streamsize>(size));
    out.close();

    platform.unmap(ptr, size);
    platform.close_fd(fd);

    // Verify dump file
    assert(std::filesystem::exists(dump_file));
    assert(std::filesystem::file_size(dump_file) == size);

    // Read back and verify
    std::ifstream in(dump_file, std::ios::binary);
    char buffer[100];
    in.read(buffer, std::strlen(test_data));
    assert(std::memcmp(buffer, test_data, std::strlen(test_data)) == 0);
    in.close();

    // Cleanup dump file
    std::filesystem::remove(dump_file);

    std::cout << "  [PASS] dump segment\n";
}

void test_destroy_segment() {
    Platform platform;

    // Verify exists before destroy
    auto info_before = platform.get_info(TEST_SEGMENT);
    assert(info_before.exists);

    // Destroy
    bool success = platform.unlink(TEST_SEGMENT);
    assert(success);

    // Verify gone
    auto info_after = platform.get_info(TEST_SEGMENT);
    assert(!info_after.exists);

    std::cout << "  [PASS] destroy segment\n";
}

} // anonymous namespace

void run_integration_tests() {
    // Get home directory
    const char* home = std::getenv("HOME");
    assert(home != nullptr);

    std::string config_path = std::string(home) + "/hft.toml";
    HOME_CONFIG = config_path.c_str();

    // Verify config exists
    assert(std::filesystem::exists(HOME_CONFIG));

    std::cout << "Running integration tests with ~/hft.toml...\n";
    std::cout << "Target segment: " << TEST_SEGMENT << "\n\n";

    // Clean up any existing segment first
    hftshm::policies::DefaultPlatformPolicy platform;
    platform.unlink(TEST_SEGMENT);

    // Run tests in order
    test_init_segment();
    test_write_and_verify();
    test_reset_segment();
    test_dump_segment();
    test_destroy_segment();

    std::cout << "\nAll integration tests passed!\n\n";
}
