# HFT Shared Memory Management System - Implementation Plan

## Overview
A C++20 CLI tool (`hft-shm`) that:
- Initializes shared memory segments based on TOML config
- Manages segments (inspect, dump, reset, destroy)
- Provides segment info for other processes to map directly

**No library needed** - other processes call CLI to get segment info (fd path, size) and map it themselves.

## Technical Choices
- **Language**: C++20 with policy-based design (template structs)
- **Shared Memory**:
  - Linux: `/dev/shm/hft/<name>` with configurable hugepage size
  - macOS: `/tmp/hft/<name>` (file-backed mmap, no hugepages)
- **Hugepages**: Configurable per-segment via `hugepage_size` in TOML (e.g., "2MB", "1GB")
- **Memory Format**: Raw memory, no header overhead
- **Build**: Plain Makefile
- **Config**: TOML via header-only library (toml++)
- **CLI Output**: Plain text for easy parsing

---

## How It Works

**Not a daemon** - one-shot CLI. Shared memory persists in `/dev/shm/` until unlinked or reboot.

```
# At system startup (manual invocation)
$ hft-shm init
Created /dev/shm/hft/zwy.mktdata.binance.raw.rx (32MB, 2MB hugepages)
Created /dev/shm/hft/zwy.mktdata.binance.raw.tx (2MB, 2MB hugepages)

# Other processes query info
$ hft-shm info zwy.mktdata.binance.raw.rx
/dev/shm/hft/zwy.mktdata.binance.raw.rx 33554432

# Occasionally inspect or dump
$ hft-shm inspect zwy.mktdata.binance.raw.rx
$ hft-shm dump zwy.mktdata.binance.raw.rx --hex
```

**Memory format**: Raw memory, no header. All bytes available to reader/writer.

---

## Project Structure

All files under `./hft-shm/`:

```
hft-shm/
├── src/
│   ├── include/
│   │   └── hftshm/
│   │       ├── types.hpp             # SegmentConfig, SegmentHandle
│   │       ├── concepts.hpp          # C++20 policy concepts
│   │       └── policies/
│   │           ├── platform.hpp      # LinuxShmPolicy, MacOSShmPolicy
│   │           └── config.hpp        # TomlConfigPolicy
│   ├── cli/
│   │   └── main.cpp                  # CLI entry point
│   └── third_party/
│       └── tomlplusplus/             # Header-only TOML library
├── test/
│   ├── test_types.cpp                # Unit tests for types/capacity parsing
│   ├── test_config.cpp               # Unit tests for config policy
│   ├── test_platform.cpp             # Unit tests for platform policy
│   └── test_main.cpp                 # Test runner entry point
├── conf/
│   └── test.toml                     # Test configuration
└── Makefile
```

---

## CLI Commands

| Command | Description |
|---------|-------------|
| `hft-shm init [--config <path>]` | Create all segments from config (one-shot) |
| `hft-shm info <name>` | Print all config attributes (name, path, capacity, type, codec, etc.) |
| `hft-shm list` | List all configured segments and status |
| `hft-shm inspect <name>` | Show current runtime properties of active shm (actual size, mapped, etc.) |
| `hft-shm dump <name> --filename <filepath>` | Dump raw segment contents to file |
| `hft-shm reset <name>` | Zero out segment memory |
| `hft-shm destroy [--all\|<name>]` | Remove (unlink) segments |

### Command Details

**`info <name>`** - Config attributes from TOML:
```
$ hft-shm info zwy.mktdata.binance.raw.rx
name: zwy/mktdata/binance/raw/rx
path: /dev/shm/hft/zwy.mktdata.binance.raw.rx
pair: BTC/USDT
type: ringbuffer
capacity: 33554432
element_size: 1
codec: string/json
hugepage_size: 2MB
writer: [zwy.mktdata_receiver.binance]
reader: [zwy.mktdata_decoder.binance]
```

**`inspect <name>`** - Runtime properties of active shm:
```
$ hft-shm inspect zwy.mktdata.binance.raw.rx
path: /dev/shm/hft/zwy.mktdata.binance.raw.rx
exists: true
size: 33554432
permissions: rw-rw-r--
hugepage: 2MB
last_modified: 2025-01-15 10:23:45
```

**`dump <name> --filename <filepath>`**:
```
$ hft-shm dump zwy.mktdata.binance.raw.rx --filename /tmp/dump.bin
Dumped 33554432 bytes to /tmp/dump.bin
```

---

## Key Files

All paths relative to `./hft-shm/`:

| File | Purpose |
|------|---------|
| `Makefile` | Build system (targets: all, cli, test, clean) |
| `src/include/hftshm/types.hpp` | Core types |
| `src/include/hftshm/concepts.hpp` | C++20 policy concepts |
| `src/include/hftshm/policies/platform.hpp` | All platform policies |
| `src/include/hftshm/policies/config.hpp` | All config policies |
| `src/cli/main.cpp` | CLI entry point |
| `test/test_main.cpp` | Unit test runner |
| `test/test_types.cpp` | Unit tests for types |
| `test/test_config.cpp` | Unit tests for config |
| `test/test_platform.cpp` | Unit tests for platform |
| `conf/test.toml` | Test configuration |

---

## Dependencies
- **toml++**: Header-only TOML library (https://github.com/marzer/tomlplusplus)
- **C++20** compiler (g++ 10+, clang++ 10+)
- Linux: kernel 3.17+ for `memfd_create`, hugepages configured
