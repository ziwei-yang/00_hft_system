#pragma once

#include <cstddef>
#include <cstdint>
#include <optional>
#include <string>
#include <string_view>
#include <vector>
#include <stdexcept>
#include <charconv>

namespace hftshm {

// Size parsing error
struct SizeParseError : std::runtime_error {
    using std::runtime_error::runtime_error;
};

// Parse size string like "32MB", "2GB", "1KB" to bytes
// Supports: B, KB, MB, GB (case-insensitive)
inline auto parse_size(std::string_view s) -> std::size_t {
    if (s.empty()) {
        throw SizeParseError("Empty size string");
    }

    // Find where the number ends
    std::size_t num_end = 0;
    while (num_end < s.size() && (std::isdigit(s[num_end]) || s[num_end] == '.')) {
        ++num_end;
    }

    if (num_end == 0) {
        throw SizeParseError("No numeric value found: " + std::string(s));
    }

    // Parse the numeric part
    double value = 0;
    auto num_str = std::string(s.substr(0, num_end));

    // Handle integer vs float
    if (num_str.find('.') != std::string::npos) {
        value = std::stod(num_str);
    } else {
        value = static_cast<double>(std::stoull(num_str));
    }

    // Get the unit suffix
    auto unit = s.substr(num_end);

    // Trim whitespace from unit
    while (!unit.empty() && std::isspace(unit.front())) {
        unit.remove_prefix(1);
    }
    while (!unit.empty() && std::isspace(unit.back())) {
        unit.remove_suffix(1);
    }

    // Convert to uppercase for comparison
    std::string unit_upper;
    for (char c : unit) {
        unit_upper += static_cast<char>(std::toupper(static_cast<unsigned char>(c)));
    }

    std::size_t multiplier = 1;
    if (unit_upper.empty() || unit_upper == "B") {
        multiplier = 1;
    } else if (unit_upper == "KB" || unit_upper == "K") {
        multiplier = 1024ULL;
    } else if (unit_upper == "MB" || unit_upper == "M") {
        multiplier = 1024ULL * 1024;
    } else if (unit_upper == "GB" || unit_upper == "G") {
        multiplier = 1024ULL * 1024 * 1024;
    } else {
        throw SizeParseError("Unknown size unit: " + std::string(unit));
    }

    return static_cast<std::size_t>(value * static_cast<double>(multiplier));
}

// Hugepage size constants
constexpr std::size_t HUGEPAGE_2MB = 2ULL * 1024 * 1024;
constexpr std::size_t HUGEPAGE_1GB = 1024ULL * 1024 * 1024;
constexpr std::size_t HUGEPAGE_THRESHOLD = 512ULL * 1024 * 1024;  // 512MB

// Auto-select hugepage size based on capacity
// < 512MB -> 2MB hugepages
// >= 512MB -> 1GB hugepages
inline auto auto_hugepage_size(std::size_t capacity) -> std::size_t {
    if (capacity >= HUGEPAGE_THRESHOLD) {
        return HUGEPAGE_1GB;
    }
    return HUGEPAGE_2MB;
}

// Align capacity up to hugepage boundary
inline auto align_to_hugepage(std::size_t capacity, std::size_t hugepage_size) -> std::size_t {
    if (hugepage_size == 0) {
        return capacity;
    }
    return ((capacity + hugepage_size - 1) / hugepage_size) * hugepage_size;
}

// Parse hugepage size
// Valid values: "auto", "2MB", "1GB", "none"/"0" for regular pages
// Returns SIZE_MAX for "auto" (to be resolved later with capacity)
constexpr std::size_t HUGEPAGE_AUTO = SIZE_MAX;

inline auto parse_hugepage_size(std::string_view s) -> std::size_t {
    if (s.empty() || s == "auto") {
        return HUGEPAGE_AUTO;
    }

    if (s == "none" || s == "0") {
        return 0;
    }

    auto size = parse_size(s);

    // Validate hugepage size (must be 2MB or 1GB on Linux)
    if (size != HUGEPAGE_2MB && size != HUGEPAGE_1GB) {
        throw SizeParseError("Invalid hugepage size: " + std::string(s) +
                            ". Must be auto, 2MB, 1GB, or none");
    }

    return size;
}

// Format size to human-readable string
inline auto format_size(std::size_t bytes) -> std::string {
    constexpr std::size_t KB = 1024ULL;
    constexpr std::size_t MB = KB * 1024;
    constexpr std::size_t GB = MB * 1024;

    if (bytes >= GB && bytes % GB == 0) {
        return std::to_string(bytes / GB) + "GB";
    } else if (bytes >= MB && bytes % MB == 0) {
        return std::to_string(bytes / MB) + "MB";
    } else if (bytes >= KB && bytes % KB == 0) {
        return std::to_string(bytes / KB) + "KB";
    } else {
        return std::to_string(bytes) + "B";
    }
}

// Shared memory segment configuration (from TOML)
struct SegmentConfig {
    std::string key;            // TOML section key (e.g., "zwy.mktdata.binance.raw.rx")
    std::string name;           // Display name (e.g., "zwy/mktdata/binance/raw/rx")
    std::string pair;           // Trading pair (e.g., "BTC/USDT")
    std::string type;           // Type (e.g., "ringbuffer")
    std::size_t capacity;       // Size in bytes
    std::size_t element_size;   // Element size in bytes
    std::string codec;          // Codec (e.g., "string/json")
    std::size_t hugepage_size;  // Hugepage size (0 for regular pages, 2MB or 1GB)
    std::vector<std::string> writer;  // Writer process names
    std::vector<std::string> reader;  // Reader process names
};

// Active shared memory segment handle
struct SegmentHandle {
    int fd;                     // File descriptor
    void* ptr;                  // Mapped memory pointer
    std::size_t size;           // Mapped size
    std::string path;           // Filesystem path

    SegmentHandle() : fd(-1), ptr(nullptr), size(0) {}

    auto is_valid() const -> bool {
        return fd >= 0 && ptr != nullptr && size > 0;
    }
};

// Runtime segment info (from filesystem inspection)
struct SegmentInfo {
    std::string path;
    bool exists;
    std::size_t size;
    std::string permissions;
    std::size_t hugepage_size;
    std::string last_modified;
};

} // namespace hftshm
