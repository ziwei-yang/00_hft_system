#pragma once

#include <string>
#include <string_view>
#include <cstddef>
#include <filesystem>
#include <stdexcept>
#include <chrono>
#include <iomanip>
#include <sstream>

#include <fcntl.h>
#include <unistd.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <errno.h>
#include <cstring>

#include "../types.hpp"

namespace hftshm::policies {

// Error for platform operations
struct PlatformError : std::runtime_error {
    using std::runtime_error::runtime_error;
};

#if defined(__linux__)

// Linux shared memory policy
// Uses /dev/shm/hft/<name> with MAP_HUGETLB support
struct LinuxShmPolicy {
    static constexpr std::string_view BASE_PATH = "/dev/shm/hft";

    // Ensure base directory exists
    static auto ensure_base_dir() -> void {
        std::filesystem::create_directories(BASE_PATH);
    }

    // Get full path for a segment name
    auto get_path(std::string_view name) const -> std::string {
        return std::string(BASE_PATH) + "/" + std::string(name);
    }

    // Get header segment path (for ringbuffer type)
    auto get_header_path(std::string_view name) const -> std::string {
        return get_path(name) + ".hdr";
    }

    // Get data segment path (for ringbuffer type)
    auto get_data_path(std::string_view name) const -> std::string {
        return get_path(name) + ".dat";
    }

    // Create shared memory segment
    // Returns file descriptor or -1 on error
    auto create(std::string_view name, std::size_t size, [[maybe_unused]] std::size_t hugepage_size) const -> int {
        ensure_base_dir();

        auto path = get_path(name);

        // Create and open file
        int fd = ::open(path.c_str(), O_RDWR | O_CREAT | O_EXCL, 0666);
        if (fd < 0) {
            if (errno == EEXIST) {
                // Already exists, try to open it
                fd = ::open(path.c_str(), O_RDWR);
                if (fd < 0) {
                    return -1;
                }
                // Truncate to requested size
                if (::ftruncate(fd, static_cast<off_t>(size)) != 0) {
                    ::close(fd);
                    return -1;
                }
                return fd;
            }
            return -1;
        }

        // Set size
        if (::ftruncate(fd, static_cast<off_t>(size)) != 0) {
            ::close(fd);
            ::unlink(path.c_str());
            return -1;
        }

        return fd;
    }

    // Map file descriptor to memory
    auto map(int fd, std::size_t size, std::size_t hugepage_size) const -> void* {
        int flags = MAP_SHARED;

        // Add hugepage flags if requested
        if (hugepage_size > 0) {
#ifdef MAP_HUGETLB
            flags |= MAP_HUGETLB;

#if defined(MAP_HUGE_2MB) || defined(MAP_HUGE_1GB)
            // Set hugepage size hint
            constexpr std::size_t SIZE_2MB = 2ULL * 1024 * 1024;
            constexpr std::size_t SIZE_1GB = 1024ULL * 1024 * 1024;

#ifdef MAP_HUGE_2MB
            if (hugepage_size == SIZE_2MB) {
                flags |= MAP_HUGE_2MB;
            }
#endif
#ifdef MAP_HUGE_1GB
            if (hugepage_size == SIZE_1GB) {
                flags |= MAP_HUGE_1GB;
            }
#endif
#endif // MAP_HUGE_2MB || MAP_HUGE_1GB
#endif // MAP_HUGETLB
        }

        void* ptr = ::mmap(nullptr, size, PROT_READ | PROT_WRITE, flags, fd, 0);

        if (ptr == MAP_FAILED && hugepage_size > 0) {
            // Hugepage mapping failed, fallback to regular pages
            ptr = ::mmap(nullptr, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
        }

        if (ptr == MAP_FAILED) {
            return nullptr;
        }

        return ptr;
    }

    // Open existing shared memory
    auto open(std::string_view name) const -> int {
        auto path = get_path(name);
        return ::open(path.c_str(), O_RDWR);
    }

    // Get size of shared memory from file descriptor
    auto get_size(int fd) const -> std::size_t {
        struct stat st;
        if (::fstat(fd, &st) != 0) {
            return 0;
        }
        return static_cast<std::size_t>(st.st_size);
    }

    // Unlink (remove) shared memory
    auto unlink(std::string_view name) const -> bool {
        auto path = get_path(name);
        return ::unlink(path.c_str()) == 0;
    }

    // Unmap memory
    auto unmap(void* ptr, std::size_t size) const -> void {
        if (ptr && ptr != MAP_FAILED) {
            ::munmap(ptr, size);
        }
    }

    // Close file descriptor
    auto close_fd(int fd) const -> void {
        if (fd >= 0) {
            ::close(fd);
        }
    }

    // Get segment info (runtime properties)
    auto get_info(std::string_view name) const -> SegmentInfo {
        SegmentInfo info;
        info.path = get_path(name);
        info.exists = std::filesystem::exists(info.path);

        if (!info.exists) {
            info.size = 0;
            info.permissions = "";
            info.hugepage_size = 0;
            info.last_modified = "";
            return info;
        }

        struct stat st;
        if (::stat(info.path.c_str(), &st) == 0) {
            info.size = static_cast<std::size_t>(st.st_size);

            // Format permissions
            std::string perms;
            perms += (st.st_mode & S_IRUSR) ? 'r' : '-';
            perms += (st.st_mode & S_IWUSR) ? 'w' : '-';
            perms += (st.st_mode & S_IXUSR) ? 'x' : '-';
            perms += (st.st_mode & S_IRGRP) ? 'r' : '-';
            perms += (st.st_mode & S_IWGRP) ? 'w' : '-';
            perms += (st.st_mode & S_IXGRP) ? 'x' : '-';
            perms += (st.st_mode & S_IROTH) ? 'r' : '-';
            perms += (st.st_mode & S_IWOTH) ? 'w' : '-';
            perms += (st.st_mode & S_IXOTH) ? 'x' : '-';
            info.permissions = perms;

            // Format last modified time
            auto mtime = std::chrono::system_clock::from_time_t(st.st_mtime);
            auto time_t_val = std::chrono::system_clock::to_time_t(mtime);
            std::tm* tm = std::localtime(&time_t_val);
            std::ostringstream oss;
            oss << std::put_time(tm, "%Y-%m-%d %H:%M:%S");
            info.last_modified = oss.str();
        }

        // TODO: Detect if using hugepages (requires parsing /proc/meminfo or smaps)
        info.hugepage_size = 0;

        return info;
    }
};

#elif defined(__APPLE__)

// macOS shared memory policy
// Uses /tmp/hft/<name> (file-backed mmap, no hugepage support)
struct MacOSShmPolicy {
    static constexpr std::string_view BASE_PATH = "/tmp/hft";

    // Ensure base directory exists
    static auto ensure_base_dir() -> void {
        std::filesystem::create_directories(BASE_PATH);
    }

    // Get full path for a segment name
    auto get_path(std::string_view name) const -> std::string {
        return std::string(BASE_PATH) + "/" + std::string(name);
    }

    // Get header segment path (for ringbuffer type)
    auto get_header_path(std::string_view name) const -> std::string {
        return get_path(name) + ".hdr";
    }

    // Get data segment path (for ringbuffer type)
    auto get_data_path(std::string_view name) const -> std::string {
        return get_path(name) + ".dat";
    }

    // Create shared memory segment
    auto create(std::string_view name, std::size_t size, std::size_t /*hugepage_size*/) const -> int {
        ensure_base_dir();

        auto path = get_path(name);

        int fd = ::open(path.c_str(), O_RDWR | O_CREAT | O_EXCL, 0666);
        if (fd < 0) {
            if (errno == EEXIST) {
                fd = ::open(path.c_str(), O_RDWR);
                if (fd < 0) {
                    return -1;
                }
                if (::ftruncate(fd, static_cast<off_t>(size)) != 0) {
                    ::close(fd);
                    return -1;
                }
                return fd;
            }
            return -1;
        }

        if (::ftruncate(fd, static_cast<off_t>(size)) != 0) {
            ::close(fd);
            ::unlink(path.c_str());
            return -1;
        }

        return fd;
    }

    // Map file descriptor to memory (no hugepage support on macOS)
    auto map(int fd, std::size_t size, std::size_t /*hugepage_size*/) const -> void* {
        void* ptr = ::mmap(nullptr, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
        if (ptr == MAP_FAILED) {
            return nullptr;
        }
        return ptr;
    }

    // Open existing shared memory
    auto open(std::string_view name) const -> int {
        auto path = get_path(name);
        return ::open(path.c_str(), O_RDWR);
    }

    // Get size of shared memory from file descriptor
    auto get_size(int fd) const -> std::size_t {
        struct stat st;
        if (::fstat(fd, &st) != 0) {
            return 0;
        }
        return static_cast<std::size_t>(st.st_size);
    }

    // Unlink (remove) shared memory
    auto unlink(std::string_view name) const -> bool {
        auto path = get_path(name);
        return ::unlink(path.c_str()) == 0;
    }

    // Unmap memory
    auto unmap(void* ptr, std::size_t size) const -> void {
        if (ptr && ptr != MAP_FAILED) {
            ::munmap(ptr, size);
        }
    }

    // Close file descriptor
    auto close_fd(int fd) const -> void {
        if (fd >= 0) {
            ::close(fd);
        }
    }

    // Get segment info (runtime properties)
    auto get_info(std::string_view name) const -> SegmentInfo {
        SegmentInfo info;
        info.path = get_path(name);
        info.exists = std::filesystem::exists(info.path);

        if (!info.exists) {
            info.size = 0;
            info.permissions = "";
            info.hugepage_size = 0;
            info.last_modified = "";
            return info;
        }

        struct stat st;
        if (::stat(info.path.c_str(), &st) == 0) {
            info.size = static_cast<std::size_t>(st.st_size);

            std::string perms;
            perms += (st.st_mode & S_IRUSR) ? 'r' : '-';
            perms += (st.st_mode & S_IWUSR) ? 'w' : '-';
            perms += (st.st_mode & S_IXUSR) ? 'x' : '-';
            perms += (st.st_mode & S_IRGRP) ? 'r' : '-';
            perms += (st.st_mode & S_IWGRP) ? 'w' : '-';
            perms += (st.st_mode & S_IXGRP) ? 'x' : '-';
            perms += (st.st_mode & S_IROTH) ? 'r' : '-';
            perms += (st.st_mode & S_IWOTH) ? 'w' : '-';
            perms += (st.st_mode & S_IXOTH) ? 'x' : '-';
            info.permissions = perms;

            auto mtime = std::chrono::system_clock::from_time_t(st.st_mtime);
            auto time_t_val = std::chrono::system_clock::to_time_t(mtime);
            std::tm* tm = std::localtime(&time_t_val);
            std::ostringstream oss;
            oss << std::put_time(tm, "%Y-%m-%d %H:%M:%S");
            info.last_modified = oss.str();
        }

        // No hugepage support on macOS
        info.hugepage_size = 0;

        return info;
    }
};

#endif

// Default platform policy based on OS
#if defined(__linux__)
using DefaultPlatformPolicy = LinuxShmPolicy;
#elif defined(__APPLE__)
using DefaultPlatformPolicy = MacOSShmPolicy;
#else
#error "Unsupported platform"
#endif

} // namespace hftshm::policies
