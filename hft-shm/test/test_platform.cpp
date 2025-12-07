#include <cassert>
#include <iostream>
#include <cstring>
#include <filesystem>

#include <hftshm/policies/platform.hpp>

namespace {

using Platform = hftshm::policies::DefaultPlatformPolicy;

void test_get_path() {
    Platform platform;
    auto path = platform.get_path("test.segment");

#if defined(__linux__)
    assert(path == "/dev/shm/hft/test.segment");
#elif defined(__APPLE__)
    assert(path == "/tmp/hft/test.segment");
#endif

    std::cout << "  [PASS] get_path\n";
}

void test_create_and_map() {
    Platform platform;
    const char* name = "test.create_map";
    const std::size_t size = 4096;

    // Clean up first
    platform.unlink(name);

    // Create
    int fd = platform.create(name, size, 0);
    assert(fd >= 0);

    // Map
    void* ptr = platform.map(fd, size, 0);
    assert(ptr != nullptr);

    // Write and verify
    std::memset(ptr, 0xAB, size);
    assert(static_cast<unsigned char*>(ptr)[0] == 0xAB);
    assert(static_cast<unsigned char*>(ptr)[size - 1] == 0xAB);

    // Cleanup
    platform.unmap(ptr, size);
    platform.close_fd(fd);
    platform.unlink(name);

    std::cout << "  [PASS] create and map\n";
}

void test_open_existing() {
    Platform platform;
    const char* name = "test.open_existing";
    const std::size_t size = 4096;

    // Clean up first
    platform.unlink(name);

    // Create and write
    int fd1 = platform.create(name, size, 0);
    assert(fd1 >= 0);
    void* ptr1 = platform.map(fd1, size, 0);
    std::memset(ptr1, 0x42, size);
    platform.unmap(ptr1, size);
    platform.close_fd(fd1);

    // Open existing
    int fd2 = platform.open(name);
    assert(fd2 >= 0);

    std::size_t actual_size = platform.get_size(fd2);
    assert(actual_size == size);

    void* ptr2 = platform.map(fd2, size, 0);
    assert(ptr2 != nullptr);

    // Verify data persisted
    assert(static_cast<unsigned char*>(ptr2)[0] == 0x42);
    assert(static_cast<unsigned char*>(ptr2)[size - 1] == 0x42);

    // Cleanup
    platform.unmap(ptr2, size);
    platform.close_fd(fd2);
    platform.unlink(name);

    std::cout << "  [PASS] open existing\n";
}

void test_unlink() {
    Platform platform;
    const char* name = "test.unlink";

    // Clean up first
    platform.unlink(name);

    // Create
    int fd = platform.create(name, 4096, 0);
    assert(fd >= 0);
    platform.close_fd(fd);

    // Verify exists
    auto path = platform.get_path(name);
    assert(std::filesystem::exists(path));

    // Unlink
    bool success = platform.unlink(name);
    assert(success);

    // Verify gone
    assert(!std::filesystem::exists(path));

    std::cout << "  [PASS] unlink\n";
}

void test_get_info() {
    Platform platform;
    const char* name = "test.get_info";
    const std::size_t size = 8192;

    // Clean up first
    platform.unlink(name);

    // Before create
    auto info1 = platform.get_info(name);
    assert(!info1.exists);

    // Create
    int fd = platform.create(name, size, 0);
    assert(fd >= 0);
    platform.close_fd(fd);

    // After create
    auto info2 = platform.get_info(name);
    assert(info2.exists);
    assert(info2.size == size);
    assert(!info2.permissions.empty());
    assert(!info2.last_modified.empty());

    // Cleanup
    platform.unlink(name);

    std::cout << "  [PASS] get_info\n";
}

void test_open_nonexistent() {
    Platform platform;

    int fd = platform.open("nonexistent.segment.12345");
    assert(fd < 0);

    std::cout << "  [PASS] open nonexistent\n";
}

} // anonymous namespace

void run_platform_tests() {
    std::cout << "Running platform tests...\n";
    test_get_path();
    test_create_and_map();
    test_open_existing();
    test_unlink();
    test_get_info();
    test_open_nonexistent();
    std::cout << "All platform tests passed!\n\n";
}
