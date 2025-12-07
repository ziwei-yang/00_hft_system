#include <iostream>
#include <string>
#include <string_view>
#include <vector>
#include <cstring>
#include <fstream>
#include <iomanip>

#include <hftshm/types.hpp>
#include <hftshm/concepts.hpp>
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
        auto path = platform.get_path(key);

        // Resolve auto hugepage size based on capacity
        std::size_t hugepage_size = cfg.hugepage_size;
        if (hugepage_size == hftshm::HUGEPAGE_AUTO) {
            hugepage_size = hftshm::auto_hugepage_size(cfg.capacity);
        }

        // Align capacity to hugepage boundary
        std::size_t aligned_capacity = hftshm::align_to_hugepage(cfg.capacity, hugepage_size);

        int fd = platform.create(key, aligned_capacity, hugepage_size);
        if (fd < 0) {
            std::cerr << "Failed to create " << path << ": " << strerror(errno) << "\n";
            ++failed;
            continue;
        }

        void* ptr = platform.map(fd, aligned_capacity, hugepage_size);
        if (!ptr) {
            std::cerr << "Failed to map " << path << ": " << strerror(errno) << "\n";
            platform.close_fd(fd);
            platform.unlink(key);
            ++failed;
            continue;
        }

        // Zero-initialize the memory
        std::memset(ptr, 0, aligned_capacity);

        platform.unmap(ptr, aligned_capacity);
        platform.close_fd(fd);

        std::cout << "Created " << path << " (";
        if (aligned_capacity != cfg.capacity) {
            std::cout << hftshm::format_size(cfg.capacity) << " -> ";
        }
        std::cout << hftshm::format_size(aligned_capacity);
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

    // Align capacity to hugepage boundary
    std::size_t aligned_capacity = hftshm::align_to_hugepage(cfg->capacity, hugepage_size);

    std::cout << "name: " << cfg->name << "\n";
    std::cout << "path: " << platform.get_path(args.name) << "\n";
    if (!cfg->pair.empty()) {
        std::cout << "pair: " << cfg->pair << "\n";
    }
    std::cout << "type: " << cfg->type << "\n";
    std::cout << "capacity: " << cfg->capacity;
    if (aligned_capacity != cfg->capacity) {
        std::cout << " (aligned: " << aligned_capacity << ")";
    }
    std::cout << "\n";
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

    return 0;
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
        auto info = platform.get_info(key);
        std::string status = info.exists ? "active" : "inactive";

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
            if (platform.unlink(key)) {
                std::cout << "Destroyed " << platform.get_path(key) << "\n";
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

    if (platform.unlink(args.name)) {
        std::cout << "Destroyed " << platform.get_path(args.name) << "\n";
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
