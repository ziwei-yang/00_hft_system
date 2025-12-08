#include <iostream>
#include <string>
#include <string_view>
#include <vector>
#include <cstring>
#include <fstream>
#include <iomanip>

#include <hftshm/types.hpp>
#include <hftshm/concepts.hpp>
#include <hftshm/layout.hpp>
#include <hftshm/policies/platform.hpp>
#include <hftshm/policies/config.hpp>

namespace {

using Platform = hftshm::policies::DefaultPlatformPolicy;
using Config = hftshm::policies::TomlConfigPolicy;

void print_usage() {
    std::cout << "HFT Shared Memory Management Tool\n"
              << "\n"
              << "Usage: hft-shm <command> [options]\n"
              << "\n"
              << "Commands:\n"
              << "  init [--config <path>]           Create all segments from config\n"
              << "  info <name>                      Print config attributes for segment\n"
              << "  list                             List all configured segments\n"
              << "  inspect <name>                   Show runtime properties of active shm\n"
              << "  dump <name> --filename <path>    Dump segment contents to file\n"
              << "  reset <name>                     Zero out segment memory\n"
              << "  destroy [--all|<name>]           Remove segment(s)\n"
              << "\n"
              << "Options:\n"
              << "  --config <path>    Path to TOML config file\n"
              << "                     Default: ./conf/test.toml or ~/hft.toml\n"
              << "  --help             Show this help message\n";
}

// Parse command line arguments
struct Args {
    std::string command;
    std::string config_path;
    std::string name;
    std::string filename;
    bool all = false;
    bool help = false;
};

Args parse_args(int argc, char* argv[]) {
    Args args;

    for (int i = 1; i < argc; ++i) {
        std::string_view arg = argv[i];

        if (arg == "--help" || arg == "-h") {
            args.help = true;
        } else if (arg == "--config" || arg == "-c") {
            if (i + 1 < argc) {
                args.config_path = argv[++i];
            }
        } else if (arg == "--filename" || arg == "-f") {
            if (i + 1 < argc) {
                args.filename = argv[++i];
            }
        } else if (arg == "--all") {
            args.all = true;
        } else if (args.command.empty()) {
            args.command = std::string(arg);
        } else if (args.name.empty()) {
            args.name = std::string(arg);
        }
    }

    return args;
}

// Command: init
int cmd_init(const Args& args) {
    Config config;
    Platform platform;

    try {
        config.load(args.config_path);
    } catch (const hftshm::policies::ConfigError& e) {
        std::cerr << "Error: " << e.what() << "\n";
        return 1;
    }

    std::cout << "Loading config from: " << config.loaded_path() << "\n";
    std::cout << "Creating " << config.size() << " segment(s)...\n\n";

    int created = 0;
    int failed = 0;

    for (const auto& [key, cfg] : config.all()) {
        // Resolve auto hugepage size based on capacity
        std::size_t hugepage_size = cfg.hugepage_size;
        if (hugepage_size == hftshm::HUGEPAGE_AUTO) {
            hugepage_size = hftshm::auto_hugepage_size(cfg.capacity);
        }

        uint8_t max_cons = static_cast<uint8_t>(cfg.max_consumers);

        // Calculate segment sizes
        uint32_t hdr_size = hftshm::header_segment_size(max_cons);
        uint32_t dat_size = hftshm::data_segment_size(
            static_cast<uint32_t>(cfg.capacity), static_cast<uint32_t>(hugepage_size));

        // 1. Create header segment (regular pages, no hugepages)
        auto hdr_path = platform.get_header_path(key);
        int hdr_fd = platform.create(key + ".hdr", hdr_size, 0);
        if (hdr_fd < 0) {
            std::cerr << "Failed to create " << hdr_path << ": " << strerror(errno) << "\n";
            ++failed;
            continue;
        }

        void* hdr_ptr = platform.map(hdr_fd, hdr_size, 0);
        if (!hdr_ptr) {
            std::cerr << "Failed to map " << hdr_path << ": " << strerror(errno) << "\n";
            platform.close_fd(hdr_fd);
            platform.unlink(key + ".hdr");
            ++failed;
            continue;
        }

        // Zero-initialize and set up metadata
        std::memset(hdr_ptr, 0, hdr_size);

        uint32_t prod_off = hftshm::default_producer_offset();
        uint32_t cons_off = hftshm::default_consumer_0_offset();

        hftshm::metadata_init(
            hdr_ptr,
            max_cons,
            static_cast<uint16_t>(cfg.element_size),
            static_cast<uint32_t>(cfg.capacity),
            prod_off,
            cons_off,
            hdr_size
        );

        platform.unmap(hdr_ptr, hdr_size);
        platform.close_fd(hdr_fd);

        // 2. Create data segment (with hugepages if enabled)
        auto dat_path = platform.get_data_path(key);
        int dat_fd = platform.create(key + ".dat", dat_size, hugepage_size);
        if (dat_fd < 0) {
            std::cerr << "Failed to create " << dat_path << ": " << strerror(errno) << "\n";
            platform.unlink(key + ".hdr");  // Cleanup header
            ++failed;
            continue;
        }

        void* dat_ptr = platform.map(dat_fd, dat_size, hugepage_size);
        if (!dat_ptr) {
            std::cerr << "Failed to map " << dat_path << ": " << strerror(errno) << "\n";
            platform.close_fd(dat_fd);
            platform.unlink(key + ".dat");
            platform.unlink(key + ".hdr");  // Cleanup header
            ++failed;
            continue;
        }

        // Zero-initialize data segment
        std::memset(dat_ptr, 0, dat_size);

        platform.unmap(dat_ptr, dat_size);
        platform.close_fd(dat_fd);

        // Print success message
        std::cout << "Created " << key << ":\n";
        std::cout << "  Header: " << hdr_path << " (" << hftshm::format_size(hdr_size) << ")\n";
        std::cout << "  Data:   " << dat_path << " (" << hftshm::format_size(dat_size);
        if (hugepage_size > 0) {
            std::cout << ", " << hftshm::format_size(hugepage_size) << " hugepages";
        }
        std::cout << ")\n";
        ++created;
    }

    std::cout << "\nDone. Created: " << created << ", Failed: " << failed << "\n";
    return failed > 0 ? 1 : 0;
}

// Command: info
int cmd_info(const Args& args) {
    if (args.name.empty()) {
        std::cerr << "Error: segment name required\n";
        return 1;
    }

    Config config;
    Platform platform;

    try {
        config.load(args.config_path);
    } catch (const hftshm::policies::ConfigError& e) {
        std::cerr << "Error: " << e.what() << "\n";
        return 1;
    }

    auto cfg = config.get(args.name);
    if (!cfg) {
        std::cerr << "Error: segment '" << args.name << "' not found in config\n";
        return 1;
    }

    // Resolve auto hugepage size based on capacity
    std::size_t hugepage_size = cfg->hugepage_size;
    if (hugepage_size == hftshm::HUGEPAGE_AUTO) {
        hugepage_size = hftshm::auto_hugepage_size(cfg->capacity);
    }

    // Calculate segment sizes
    uint8_t max_cons = static_cast<uint8_t>(cfg->max_consumers);
    uint32_t hdr_size = hftshm::header_segment_size(max_cons);
    uint32_t dat_size = hftshm::data_segment_size(
        static_cast<uint32_t>(cfg->capacity), static_cast<uint32_t>(hugepage_size));

    // Check if segment is active
    auto hdr_info = platform.get_info(args.name + ".hdr");
    auto dat_info = platform.get_info(args.name + ".dat");
    bool is_active = hdr_info.exists && dat_info.exists;

    std::cout << "name: " << cfg->name << "\n";
    std::cout << "status: " << (is_active ? "active" : "inactive") << "\n";
    std::cout << "header_path: " << platform.get_header_path(args.name) << "\n";
    std::cout << "header_size: " << hdr_size << "\n";
    std::cout << "data_path: " << platform.get_data_path(args.name) << "\n";
    std::cout << "data_size: " << dat_size << "\n";
    if (!cfg->pair.empty()) {
        std::cout << "pair: " << cfg->pair << "\n";
    }
    std::cout << "type: " << cfg->type << "\n";
    std::cout << "buffer_size: " << cfg->capacity << "\n";
    std::cout << "element_size: " << cfg->element_size << "\n";
    if (!cfg->codec.empty()) {
        std::cout << "codec: " << cfg->codec << "\n";
    }
    std::cout << "hugepage_size: ";
    if (cfg->hugepage_size == hftshm::HUGEPAGE_AUTO) {
        std::cout << "auto (" << hftshm::format_size(hugepage_size) << ")";
    } else {
        std::cout << hftshm::format_size(hugepage_size);
    }
    std::cout << "\n";
    std::cout << "max_consumers: " << cfg->max_consumers << "\n";

    if (!cfg->writer.empty()) {
        std::cout << "writer: [";
        for (std::size_t i = 0; i < cfg->writer.size(); ++i) {
            if (i > 0) std::cout << ", ";
            std::cout << cfg->writer[i];
        }
        std::cout << "]\n";
    }

    if (!cfg->reader.empty()) {
        std::cout << "reader: [";
        for (std::size_t i = 0; i < cfg->reader.size(); ++i) {
            if (i > 0) std::cout << ", ";
            std::cout << cfg->reader[i];
        }
        std::cout << "]\n";
    }

    // Try to read metadata from header segment
    int fd = platform.open(args.name + ".hdr");
    if (fd >= 0) {
        std::size_t size = platform.get_size(fd);
        if (size >= hftshm::CACHE_LINE) {
            void* ptr = platform.map(fd, size, 0);
            if (ptr) {
                const auto* meta = hftshm::metadata_get(ptr);

                std::cout << "\n# Metadata (from header segment)\n";
                if (hftshm::metadata_validate(ptr)) {
                    std::cout << "magic: 0x" << std::hex << std::setfill('0') << std::setw(16) << meta->magic << std::dec << "\n";
                    std::cout << "version: " << static_cast<int>(meta->version) << "\n";
                    std::cout << "max_consumers: " << static_cast<int>(meta->max_consumers) << "\n";
                    std::cout << "event_size: " << meta->event_size << "\n";
                    std::cout << "producer_pid: " << meta->producer_pid << "\n";
                    std::cout << "buffer_size: " << meta->buffer_size << "\n";
                    std::cout << "producer_offset: " << meta->producer_offset << "\n";
                    std::cout << "consumer_0_offset: " << meta->consumer_0_offset << "\n";
                    std::cout << "header_size: " << meta->header_size << "\n";
                    std::cout << "index_mask: " << meta->index_mask << "\n";

                    std::cout << "\n# Computed offsets (for clients)\n";
                    std::cout << "producer_section_size: " << hftshm::producer_section_size(meta) << "\n";
                    std::cout << "consumer_section_size: " << hftshm::consumer_section_size(meta) << "\n";
                    for (uint8_t i = 0; i < meta->max_consumers; ++i) {
                        std::cout << "consumer_" << static_cast<int>(i) << "_offset: " << hftshm::consumer_offset(meta, i) << "\n";
                    }
                } else {
                    std::cout << "(invalid or uninitialized metadata)\n";
                }

                platform.unmap(ptr, size);
            }
        }
        platform.close_fd(fd);
    }

    // Return non-zero if segment is not active (for programmatic detection)
    return is_active ? 0 : 2;
}

// Command: list
int cmd_list(const Args& args) {
    Config config;
    Platform platform;

    try {
        config.load(args.config_path);
    } catch (const hftshm::policies::ConfigError& e) {
        std::cerr << "Error: " << e.what() << "\n";
        return 1;
    }

    std::cout << "Config: " << config.loaded_path() << "\n\n";

    std::cout << std::left
              << std::setw(40) << "NAME"
              << std::setw(12) << "CAPACITY"
              << std::setw(10) << "STATUS"
              << "\n";
    std::cout << std::string(62, '-') << "\n";

    for (const auto& [key, cfg] : config.all()) {
        // Check if header segment exists (indicates segment is active)
        auto hdr_info = platform.get_info(key + ".hdr");
        auto dat_info = platform.get_info(key + ".dat");
        std::string status = (hdr_info.exists && dat_info.exists) ? "active" : "inactive";

        std::cout << std::left
                  << std::setw(40) << key
                  << std::setw(12) << hftshm::format_size(cfg.capacity)
                  << std::setw(10) << status
                  << "\n";
    }

    return 0;
}

// Command: inspect
int cmd_inspect(const Args& args) {
    if (args.name.empty()) {
        std::cerr << "Error: segment name required\n";
        return 1;
    }

    Platform platform;
    auto info = platform.get_info(args.name);

    std::cout << "path: " << info.path << "\n";
    std::cout << "exists: " << (info.exists ? "true" : "false") << "\n";

    if (info.exists) {
        std::cout << "size: " << info.size << "\n";
        std::cout << "permissions: " << info.permissions << "\n";
        if (info.hugepage_size > 0) {
            std::cout << "hugepage: " << hftshm::format_size(info.hugepage_size) << "\n";
        }
        std::cout << "last_modified: " << info.last_modified << "\n";
    }

    return 0;
}

// Command: dump
int cmd_dump(const Args& args) {
    if (args.name.empty()) {
        std::cerr << "Error: segment name required\n";
        return 1;
    }

    if (args.filename.empty()) {
        std::cerr << "Error: --filename required\n";
        return 1;
    }

    Platform platform;

    int fd = platform.open(args.name);
    if (fd < 0) {
        std::cerr << "Error: segment '" << args.name << "' not found or cannot be opened\n";
        return 1;
    }

    std::size_t size = platform.get_size(fd);
    if (size == 0) {
        platform.close_fd(fd);
        std::cerr << "Error: segment has size 0\n";
        return 1;
    }

    void* ptr = platform.map(fd, size, 0);
    if (!ptr) {
        platform.close_fd(fd);
        std::cerr << "Error: failed to map segment\n";
        return 1;
    }

    std::ofstream out(args.filename, std::ios::binary);
    if (!out) {
        platform.unmap(ptr, size);
        platform.close_fd(fd);
        std::cerr << "Error: cannot open output file '" << args.filename << "'\n";
        return 1;
    }

    out.write(static_cast<const char*>(ptr), static_cast<std::streamsize>(size));
    out.close();

    platform.unmap(ptr, size);
    platform.close_fd(fd);

    std::cout << "Dumped " << size << " bytes to " << args.filename << "\n";
    return 0;
}

// Command: reset
int cmd_reset(const Args& args) {
    if (args.name.empty()) {
        std::cerr << "Error: segment name required\n";
        return 1;
    }

    Platform platform;

    int fd = platform.open(args.name);
    if (fd < 0) {
        std::cerr << "Error: segment '" << args.name << "' not found\n";
        return 1;
    }

    std::size_t size = platform.get_size(fd);
    if (size == 0) {
        platform.close_fd(fd);
        std::cerr << "Error: segment has size 0\n";
        return 1;
    }

    void* ptr = platform.map(fd, size, 0);
    if (!ptr) {
        platform.close_fd(fd);
        std::cerr << "Error: failed to map segment\n";
        return 1;
    }

    std::memset(ptr, 0, size);

    platform.unmap(ptr, size);
    platform.close_fd(fd);

    std::cout << "Reset " << size << " bytes in " << platform.get_path(args.name) << "\n";
    return 0;
}

// Command: destroy
int cmd_destroy(const Args& args) {
    Platform platform;

    if (args.all) {
        Config config;
        try {
            config.load(args.config_path);
        } catch (const hftshm::policies::ConfigError& e) {
            std::cerr << "Error: " << e.what() << "\n";
            return 1;
        }

        int destroyed = 0;
        for (const auto& [key, cfg] : config.all()) {
            bool hdr_ok = platform.unlink(key + ".hdr");
            bool dat_ok = platform.unlink(key + ".dat");
            if (hdr_ok || dat_ok) {
                std::cout << "Destroyed " << key << "\n";
                ++destroyed;
            }
        }
        std::cout << "Destroyed " << destroyed << " segment(s)\n";
        return 0;
    }

    if (args.name.empty()) {
        std::cerr << "Error: segment name or --all required\n";
        return 1;
    }

    bool hdr_ok = platform.unlink(args.name + ".hdr");
    bool dat_ok = platform.unlink(args.name + ".dat");

    if (hdr_ok || dat_ok) {
        std::cout << "Destroyed " << args.name << "\n";
        if (hdr_ok) std::cout << "  Header: " << platform.get_header_path(args.name) << "\n";
        if (dat_ok) std::cout << "  Data:   " << platform.get_data_path(args.name) << "\n";
        return 0;
    } else {
        std::cerr << "Error: failed to destroy segment (may not exist)\n";
        return 1;
    }
}

} // anonymous namespace

int main(int argc, char* argv[]) {
    auto args = parse_args(argc, argv);

    if (args.help || args.command.empty()) {
        print_usage();
        return args.help ? 0 : 1;
    }

    try {
        if (args.command == "init") {
            return cmd_init(args);
        } else if (args.command == "info") {
            return cmd_info(args);
        } else if (args.command == "list") {
            return cmd_list(args);
        } else if (args.command == "inspect") {
            return cmd_inspect(args);
        } else if (args.command == "dump") {
            return cmd_dump(args);
        } else if (args.command == "reset") {
            return cmd_reset(args);
        } else if (args.command == "destroy") {
            return cmd_destroy(args);
        } else {
            std::cerr << "Unknown command: " << args.command << "\n";
            print_usage();
            return 1;
        }
    } catch (const std::exception& e) {
        std::cerr << "Error: " << e.what() << "\n";
        return 1;
    }
}
