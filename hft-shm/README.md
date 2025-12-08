# hft-shm

HFT Shared Memory Management Tool - A C++20 CLI for managing SPMC (Single-Producer, Multiple-Consumer) shared memory segments.

## Overview

`hft-shm` creates and manages shared memory segments for high-frequency trading systems. Key features:

- **SPMC Architecture**: Single producer, multiple consumers per segment
- **Dual-Segment Design**: Separate header (.hdr) and data (.dat) segments for optimal memory usage
- **Hugepage Support**: Data segments can use 2MB/1GB hugepages for reduced TLB misses
- **TOML Configuration**: Define all segments in a single config file
- **Platform Support**: Linux (`/dev/shm/hft/`) and macOS (`/tmp/hft/`)

## Quick Start

```bash
# Build
make

# Initialize all segments from config
./build/hft-shm init

# List segments and their status
./build/hft-shm list

# Get info about a specific segment
./build/hft-shm info zwy.mktdata.binance.raw.rx

# Destroy all segments
./build/hft-shm destroy --all
```

## Memory Layout (v2)

Each ringbuffer segment creates **two files**:

### Header Segment (`.hdr`) - Regular 4KB Pages
```
Offset 0x000: metadata              (64 bytes, cache-line aligned)
Offset 0x040: producer section      (128 bytes)
Offset 0x0C0: consumer sections     (N x 128 bytes)
Total: page-aligned (rounded up to 4KB)
```

### Data Segment (`.dat`) - Hugepages When Enabled
```
Offset 0x000: ring buffer data      (buffer_size bytes, power of 2)
Total: buffer_size (hugepage-aligned if using hugepages)
```

**Why separate segments?**
- Header (~1KB) uses regular pages - better for frequently modified metadata
- Data (MBs-GBs) uses hugepages - one TLB entry covers entire buffer
- No wasted 2MB padding between header and data

### Metadata Structure (64 bytes)

| Offset | Field | Size | Description |
|--------|-------|------|-------------|
| 0x00 | magic | 8 | `0x00024D4853544648` ("HFTSHM\x02\x00") |
| 0x08 | version | 1 | Layout version (2) |
| 0x09 | max_consumers | 1 | Maximum consumer count |
| 0x0A | event_size | 2 | Size of each event in bytes |
| 0x0C | producer_pid | 4 | Producer PID (0 = not attached) |
| 0x10 | buffer_size | 4 | Ring buffer capacity (power of 2) |
| 0x14 | producer_offset | 4 | Offset to producer section |
| 0x18 | consumer_0_offset | 4 | Offset to consumer 0 section |
| 0x1C | header_size | 4 | Total header segment size |
| 0x20 | index_mask | 4 | = buffer_size - 1 (for fast modulo) |
| 0x24 | padding | 28 | Zero padding to cache line |

## CLI Commands

### `init [--config <path>]`
Create all segments defined in config.

```bash
$ hft-shm init
Loading config from: ./conf/test.toml
Creating 4 segment(s)...

Created zwy.mktdata.binance.raw.rx:
  Header: /dev/shm/hft/zwy/mktdata/binance/raw/rx.hdr (4KB)
  Data:   /dev/shm/hft/zwy/mktdata/binance/raw/rx.dat (32MB, 2MB hugepages)

Done. Created: 4, Failed: 0
```

### `list`
Show all configured segments and their status.

```bash
$ hft-shm list
Config: ./conf/test.toml

NAME                                    CAPACITY    STATUS
--------------------------------------------------------------
zwy.mktdata.binance.raw.rx              32MB        active
zwy.mktdata.binance.raw.tx              2MB         active
zwy.mktdata.okx.raw.rx                  32MB        inactive
```

### `info <name>`
Show configuration and runtime info for a segment.

**Exit codes:**
- `0` - Segment is active (both .hdr and .dat exist)
- `1` - Error (segment not in config, invalid args)
- `2` - Segment is inactive (not initialized)

```bash
$ hft-shm info zwy.mktdata.binance.raw.rx
name: zwy/mktdata/binance/raw/rx
status: active
header_path: /dev/shm/hft/zwy/mktdata/binance/raw/rx.hdr
header_size: 4096
data_path: /dev/shm/hft/zwy/mktdata/binance/raw/rx.dat
data_size: 33554432
pair: BTC/USDT
type: ringbuffer
buffer_size: 33554432
element_size: 128
codec: sbe
hugepage_size: auto (2MB)
max_consumers: 4
writer: [zwy.mktdata_receiver.binance]
reader: [zwy.mktdata_decoder.binance, zwy.logger]

# Metadata (from header segment)
magic: 0x00024d4853544648
version: 2
max_consumers: 4
event_size: 128
producer_pid: 0
buffer_size: 33554432
producer_offset: 64
consumer_0_offset: 192
header_size: 4096
index_mask: 33554431

# Computed offsets (for clients)
producer_section_size: 128
consumer_section_size: 128
consumer_0_offset: 192
consumer_1_offset: 320
consumer_2_offset: 448
consumer_3_offset: 576
```

### `inspect <name>`
Show runtime properties of a raw segment file.

```bash
$ hft-shm inspect zwy.mktdata.binance.raw.rx.hdr
path: /dev/shm/hft/zwy/mktdata/binance/raw/rx.hdr
exists: true
size: 4096
permissions: rw-rw-r--
last_modified: 2025-01-15 10:23:45
```

### `dump <name> --filename <path>`
Dump segment contents to a file.

```bash
$ hft-shm dump zwy.mktdata.binance.raw.rx.dat --filename /tmp/data.bin
Dumped 33554432 bytes to /tmp/data.bin
```

### `reset <name>`
Zero out segment memory.

```bash
$ hft-shm reset zwy.mktdata.binance.raw.rx.hdr
Reset 4096 bytes in /dev/shm/hft/zwy/mktdata/binance/raw/rx.hdr
```

### `destroy [--all|<name>]`
Remove segment files.

```bash
$ hft-shm destroy zwy.mktdata.binance.raw.rx
Destroyed zwy.mktdata.binance.raw.rx
  Header: /dev/shm/hft/zwy/mktdata/binance/raw/rx.hdr
  Data:   /dev/shm/hft/zwy/mktdata/binance/raw/rx.dat

$ hft-shm destroy --all
Destroyed 4 segment(s)
```

## Client Integration

### Checking Segment Status

```bash
# Check if segment is ready before connecting
if hft-shm info myapp.data.rx > /dev/null 2>&1; then
    echo "Segment is active"
else
    exit_code=$?
    if [ $exit_code -eq 2 ]; then
        echo "Segment not initialized, run: hft-shm init"
    else
        echo "Segment not found in config"
    fi
fi
```

### Mapping Segments in C++

```cpp
#include <fcntl.h>
#include <sys/mman.h>
#include <hftshm/layout.hpp>

// 1. Open header segment
int hdr_fd = open("/dev/shm/hft/myapp/data/rx.hdr", O_RDWR);
struct stat st;
fstat(hdr_fd, &st);
void* hdr = mmap(nullptr, st.st_size, PROT_READ | PROT_WRITE, MAP_SHARED, hdr_fd, 0);

// 2. Validate and read metadata
auto* meta = static_cast<const hftshm::metadata*>(hdr);
if (!hftshm::metadata_validate(hdr)) {
    // Invalid or uninitialized
}

// 3. Open data segment
int dat_fd = open("/dev/shm/hft/myapp/data/rx.dat", O_RDWR);
void* data = mmap(nullptr, meta->buffer_size, PROT_READ | PROT_WRITE, MAP_SHARED, dat_fd, 0);

// 4. Access producer/consumer sections in header
uint8_t* producer = static_cast<uint8_t*>(hdr) + meta->producer_offset;
uint8_t* consumer0 = static_cast<uint8_t*>(hdr) + meta->consumer_0_offset;

// 5. Access ring buffer data
uint8_t* ring = static_cast<uint8_t*>(data);
```

### File Paths

| Segment Name | Header Path | Data Path |
|--------------|-------------|-----------|
| `foo.bar.baz` | `/dev/shm/hft/foo/bar/baz.hdr` | `/dev/shm/hft/foo/bar/baz.dat` |

The `.` in segment names are converted to `/` in paths.

## Configuration

Default config search order:
1. `--config <path>` argument
2. `./conf/test.toml`
3. `~/hft.toml`

### Example TOML Config

```toml
[segments.zwy.mktdata.binance.raw.rx]
name = "zwy/mktdata/binance/raw/rx"
pair = "BTC/USDT"
type = "ringbuffer"
capacity = "32MB"
element_size = 128
codec = "sbe"
hugepage_size = "auto"    # auto, 2MB, 1GB, or 0 (disabled)
max_consumers = 4
writer = ["zwy.mktdata_receiver.binance"]
reader = ["zwy.mktdata_decoder.binance", "zwy.logger"]
```

### Hugepage Configuration

| Value | Behavior |
|-------|----------|
| `"auto"` | 2MB for capacity >= 2MB, else disabled |
| `"2MB"` | Use 2MB hugepages |
| `"1GB"` | Use 1GB hugepages |
| `0` or `"0"` | Disabled (regular 4KB pages) |

**Linux hugepage setup:**
```bash
# Check available hugepages
cat /proc/meminfo | grep Huge

# Allocate 2MB hugepages (as root)
echo 64 > /proc/sys/vm/nr_hugepages
```

## Project Structure

```
hft-shm/
├── src/
│   ├── include/hftshm/
│   │   ├── types.hpp           # SegmentConfig, SegmentInfo
│   │   ├── concepts.hpp        # C++20 policy concepts
│   │   ├── layout.hpp          # Memory layout, metadata struct
│   │   └── policies/
│   │       ├── platform.hpp    # LinuxShmPolicy, MacOSShmPolicy
│   │       └── config.hpp      # TomlConfigPolicy
│   ├── cli/main.cpp            # CLI entry point
│   └── third_party/tomlplusplus/
├── test/
│   ├── test_main.cpp           # Test runner
│   ├── test_types.cpp          # Type tests
│   ├── test_config.cpp         # Config tests
│   ├── test_platform.cpp       # Platform tests
│   └── test_layout.cpp         # Layout tests
├── conf/test.toml              # Test configuration
├── Makefile
└── README.md
```

## Building

```bash
# Build CLI
make

# Build and run tests
make test

# Clean
make clean
```

## Requirements

- C++20 compiler (g++ 10+, clang++ 10+)
- Linux: kernel 3.17+ (for memfd), hugepages configured (optional)
- macOS: No hugepage support, uses regular file-backed mmap

## Dependencies

- **toml++**: Header-only TOML library (bundled in src/third_party/)
