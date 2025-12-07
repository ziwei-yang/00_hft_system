#pragma once

#include <concepts>
#include <optional>
#include <ranges>
#include <span>
#include <string_view>

#include "types.hpp"

namespace hftshm {

// Platform policy concept
// Defines the interface for platform-specific shared memory operations
template<typename T>
concept PlatformPolicy = requires(T policy, std::string_view name, std::size_t size,
                                   std::size_t hugepage_size, int fd, void* ptr) {
    // Create shared memory, returns file descriptor (-1 on error)
    { policy.create(name, size, hugepage_size) } -> std::same_as<int>;

    // Map file descriptor to memory
    { policy.map(fd, size, hugepage_size) } -> std::same_as<void*>;

    // Open existing shared memory by name, returns file descriptor
    { policy.open(name) } -> std::same_as<int>;

    // Get size of existing shared memory
    { policy.get_size(fd) } -> std::same_as<std::size_t>;

    // Unlink (remove) shared memory by name
    { policy.unlink(name) } -> std::same_as<bool>;

    // Unmap memory
    { policy.unmap(ptr, size) } -> std::same_as<void>;

    // Close file descriptor
    { policy.close_fd(fd) } -> std::same_as<void>;

    // Get filesystem path for a segment name
    { policy.get_path(name) } -> std::same_as<std::string>;

    // Get segment info (runtime properties)
    { policy.get_info(name) } -> std::same_as<SegmentInfo>;
};

// Config policy concept
// Defines the interface for configuration loading
template<typename T>
concept ConfigPolicy = requires(T policy, std::string_view path, std::string_view name) {
    // Load configuration from file path
    { policy.load(path) } -> std::same_as<bool>;

    // Get configuration for a specific segment by key
    { policy.get(name) } -> std::same_as<std::optional<SegmentConfig>>;

    // Get all configurations
    { policy.all() } -> std::ranges::range;
};

} // namespace hftshm
