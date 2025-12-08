# HFT Shared Memory Layout (Version 2)

## Overview

Enhanced SPMC (Single-Producer, Multiple-Consumer) shared memory layout for `hft-shm`, designed based on patterns from `disruptor_zwy`.

**Key Design Decision (v2)**: Header and data are stored in **separate segments** for optimal memory performance.

---

## Segment Architecture

For each ringbuffer definition, two shared memory segments are created:

```
Header Segment (.hdr) - Regular 4KB pages
┌─────────────────────────────────────────────────────────────┐
│ SECTION 0: Metadata (64 bytes = 1 cache line)               │
├─────────────────────────────────────────────────────────────┤
│ SECTION 1: Producer State (128 bytes = 2 cache lines)       │
├─────────────────────────────────────────────────────────────┤
│ SECTION 2: Consumer 0 State (128 bytes)                     │
├─────────────────────────────────────────────────────────────┤
│ ...                                                         │
├─────────────────────────────────────────────────────────────┤
│ SECTION N+1: Consumer N-1 State (128 bytes)                 │
├─────────────────────────────────────────────────────────────┤
│ Padding (to 4KB page boundary)                              │
└─────────────────────────────────────────────────────────────┘

Data Segment (.dat) - Hugepages when enabled
┌─────────────────────────────────────────────────────────────┐
│ Ring Buffer Data (buffer_size bytes, power of 2)            │
└─────────────────────────────────────────────────────────────┘
```

### Why Separate Segments?

| Aspect | Single Segment | Separate Segments |
|--------|----------------|-------------------|
| Memory waste | ~2MB padding with hugepages | None |
| TLB for header | Uses hugepage TLB (wasteful) | Uses regular TLB |
| TLB for data | Optimal | Optimal |
| Cache behavior | Hugepages may cause larger invalidations | Better - header in regular pages |

**Result**: Header (~1-2KB, frequently modified) uses regular 4KB pages. Data (32MB-1GB, sequential access) gets full hugepage benefit.

---

## Naming Convention

For a segment key `foo.bar.baz`:
- Header segment: `/dev/shm/hft/foo.bar.baz.hdr`
- Data segment: `/dev/shm/hft/foo.bar.baz.dat`

---

## Section 0: Metadata (64 bytes)

```cpp
// layout.hpp - Version 2
inline constexpr std::size_t CACHE_LINE = std::hardware_destructive_interference_size;
inline constexpr uint32_t PAGE_SIZE = 4096;
inline constexpr uint64_t METADATA_MAGIC = 0x00024D4853544648ULL;  // "HFTSHM\x02\x00"
inline constexpr uint8_t METADATA_VERSION = 2;

struct alignas(CACHE_LINE) metadata {
    uint64_t magic;               // 0x00: Magic number for validation
    uint8_t  version;             // 0x08: Layout version (2)
    uint8_t  max_consumers;       // 0x09: Max supported consumers (fixed at creation)
    uint16_t event_size;          // 0x0A: Size of each event/element
    uint32_t producer_pid;        // 0x0C: Producer PID (0 = not attached)
    uint32_t buffer_size;         // 0x10: Ring buffer capacity (power of 2)
    uint32_t producer_offset;     // 0x14: Offset to producer section
    uint32_t consumer_0_offset;   // 0x18: Offset to consumer 0 section
    uint32_t header_size;         // 0x1C: Total header segment size (page-aligned)
    uint32_t index_mask;          // 0x20: = buffer_size - 1 (precomputed)
    uint8_t  padding[CACHE_LINE - 36];  // 0x24-0x3F (dynamic based on CACHE_LINE)
};
static_assert(sizeof(metadata) == CACHE_LINE);
static_assert(alignof(metadata) == CACHE_LINE);
```

### Memory Layout Offsets

```
Offset 0x00: magic               (8 bytes)
Offset 0x08: version             (1 byte)
Offset 0x09: max_consumers       (1 byte)
Offset 0x0A: event_size          (2 bytes)
Offset 0x0C: producer_pid        (4 bytes)
Offset 0x10: buffer_size         (4 bytes)
Offset 0x14: producer_offset     (4 bytes)
Offset 0x18: consumer_0_offset   (4 bytes)
Offset 0x1C: header_size         (4 bytes)
Offset 0x20: index_mask          (4 bytes)
Offset 0x24: padding             (28 bytes for 64-byte cache line)
```

---

## Section 1: Producer State (128 bytes = 2 cache lines)

### Cache Line 1: Hot Path (sequences)

```cpp
struct alignas(CACHE_LINE) producer_sequences {
    std::atomic<int64_t> cursor;           // 0x00: Claimed sequence (write head)
    std::atomic<int64_t> published;        // 0x08: Visible to consumers
    int64_t cached_min_consumer;           // 0x10: Cached slowest consumer (relaxed)
    uint32_t flags;                        // 0x18: ACTIVE=1, DRAINING=2
    uint32_t producer_id;                  // 0x1C: Identity
    uint8_t  padding[32];                  // 0x20-0x3F
};
```

### Cache Line 2: Cold Path (metrics)

```cpp
struct alignas(CACHE_LINE) producer_metrics {
    std::atomic<uint64_t> publish_count;   // 0x00: Total published events
    std::atomic<uint64_t> claim_spins;     // 0x08: Spins waiting for capacity
    std::atomic<uint64_t> batch_count;     // 0x10: Batch publish operations
    uint64_t last_publish_ts;              // 0x18: Last publish timestamp ns
    uint8_t  padding[32];                  // 0x20-0x3F
};
```

### Combined

```cpp
struct producer_state {
    producer_sequences seq;    // Hot: every publish
    producer_metrics metrics;  // Cold: monitoring only
};
static_assert(sizeof(producer_state) == 128);
```

---

## Section 2-N: Consumer State (128 bytes each)

### Cache Line 1: Hot Path (sequences)

```cpp
struct alignas(CACHE_LINE) consumer_sequences {
    std::atomic<int64_t> sequence;         // 0x00: Current read position (tail)
    int64_t cached_available;              // 0x08: Cached producer.published
    std::atomic<uint32_t> status;          // 0x10: See status enum
    uint32_t consumer_id;                  // 0x14: Identity
    uint32_t wait_strategy;                // 0x18: See wait strategy enum
    uint32_t reserved;                     // 0x1C
    uint8_t  padding[32];                  // 0x20-0x3F
};

// Status values
constexpr uint32_t STATUS_INACTIVE  = 0;
constexpr uint32_t STATUS_ACTIVE    = 1;
constexpr uint32_t STATUS_LAGGING   = 2;
constexpr uint32_t STATUS_ALERTED   = 3;

// Wait strategy values
constexpr uint32_t WAIT_BUSY_SPIN   = 0;
constexpr uint32_t WAIT_YIELD       = 1;
constexpr uint32_t WAIT_ADAPTIVE    = 2;
constexpr uint32_t WAIT_BLOCK       = 3;
```

### Cache Line 2: Cold Path (metrics)

```cpp
struct alignas(CACHE_LINE) consumer_metrics {
    std::atomic<uint64_t> process_count;   // 0x00: Events processed
    std::atomic<uint64_t> batch_count;     // 0x08: Batches processed
    std::atomic<uint64_t> wait_cycles;     // 0x10: Total wait cycles
    std::atomic<uint64_t> lag_events;      // 0x18: Missed due to overwrite
    uint64_t last_read_ts;                 // 0x20: Last read timestamp ns
    uint8_t  padding[24];                  // 0x28-0x3F
};
```

### Combined

```cpp
struct consumer_state {
    consumer_sequences seq;    // Hot: every read
    consumer_metrics metrics;  // Cold: monitoring only
};
static_assert(sizeof(consumer_state) == 128);
```

---

## Offset Calculations (Implemented)

```cpp
// layout.hpp
inline constexpr uint32_t DEFAULT_PRODUCER_SECTION_SIZE = 2 * CACHE_LINE;  // 128 bytes
inline constexpr uint32_t DEFAULT_CONSUMER_SECTION_SIZE = 2 * CACHE_LINE;  // 128 bytes

inline constexpr uint32_t default_producer_offset() {
    return CACHE_LINE;  // Right after metadata
}

inline constexpr uint32_t default_consumer_0_offset(
    uint32_t producer_section_size = DEFAULT_PRODUCER_SECTION_SIZE
) {
    return CACHE_LINE + producer_section_size;
}

// Calculate raw header size (before page alignment)
inline constexpr uint32_t raw_header_size(
    uint8_t max_consumers,
    uint32_t producer_section_size = DEFAULT_PRODUCER_SECTION_SIZE,
    uint32_t consumer_section_size = DEFAULT_CONSUMER_SECTION_SIZE
) {
    return CACHE_LINE + producer_section_size + (max_consumers * consumer_section_size);
}

// Calculate header segment size (page-aligned)
inline uint32_t header_segment_size(
    uint8_t max_consumers,
    uint32_t producer_section_size = DEFAULT_PRODUCER_SECTION_SIZE,
    uint32_t consumer_section_size = DEFAULT_CONSUMER_SECTION_SIZE
) {
    uint32_t raw = raw_header_size(max_consumers, producer_section_size, consumer_section_size);
    return ((raw + PAGE_SIZE - 1) / PAGE_SIZE) * PAGE_SIZE;
}

// Calculate data segment size (hugepage-aligned when using hugepages)
inline uint32_t data_segment_size(
    uint32_t buffer_size,
    uint32_t hugepage_size  // 0 for regular pages
) {
    if (hugepage_size == 0) {
        return buffer_size;  // Already power of 2
    }
    return ((buffer_size + hugepage_size - 1) / hugepage_size) * hugepage_size;
}
```

### Example Calculations

**max_consumers=8, buffer_size=32MB:**
```
raw_header_size = 64 + 128 + (8 × 128) = 1216 bytes
header_segment_size = round_up(1216, 4096) = 4096 bytes (1 page)
data_segment_size = 32MB (power of 2, no alignment needed)

Header Segment Layout:
  Offset 0x000: metadata              (64 bytes)
  Offset 0x040: producer section      (128 bytes)
  Offset 0x0C0: consumer 0            (128 bytes)
  Offset 0x140: consumer 1            (128 bytes)
  ...
  Offset 0x440: consumer 7            (128 bytes)
  Offset 0x4C0: padding               (2880 bytes)
  Total: 4096 bytes (1 page)
```

---

## Design Rationale

| Decision | Rationale |
|----------|-----------|
| **Separate header/data segments** | Header uses regular pages (small, frequently modified), data uses hugepages (large, sequential access) |
| **2 cache lines per actor** | Hot/cold separation prevents metrics from polluting sequence cache lines |
| **cursor vs published** | Two-phase commit: claim slots, write data, then publish (batch-friendly) |
| **cached_min_consumer** | Producer avoids scanning all consumers on every publish |
| **cached_available** | Consumer avoids cross-cache-line read of producer.published |
| **wait_strategy field** | Consumer signals preferred wait mode for adaptive behavior |
| **Monotonic 64-bit sequences** | Never wrap - use `seq & index_mask` for buffer indexing |
| **index_mask precomputed** | Avoids modulo; enables branchless `pos & mask` |
| **Page-aligned header** | Ensures clean memory boundaries, simplifies mmap |
| **Compact uint32 offsets** | Sufficient for ~2GB segments, reduces metadata size |

---

## Memory Ordering

Based on `disruptor_zwy` patterns:

| Operation | Memory Order | Rationale |
|-----------|--------------|-----------|
| Producer cursor claim | `acquire` | See previous writes |
| Producer publish | `release` | Make event data visible |
| Consumer sequence read | `acquire` | See published data |
| Consumer sequence update | `release` | Signal progress to producer |
| cached_* fields | `relaxed` | Optimization only, stale values acceptable |
| Metrics counters | `relaxed` | Approximate counts sufficient |

---

## CLI Usage

```bash
# Create segments from config
$ hft-shm init
Creating zwy.mktdata.binance.raw.rx:
  Header: /dev/shm/hft/zwy.mktdata.binance.raw.rx.hdr (4KB)
  Data:   /dev/shm/hft/zwy.mktdata.binance.raw.rx.dat (32MB, 2MB hugepages)

# Show segment info
$ hft-shm info zwy.mktdata.binance.raw.rx
name: zwy/mktdata/binance/raw/rx
header_path: /dev/shm/hft/zwy.mktdata.binance.raw.rx.hdr
header_size: 4096
data_path: /dev/shm/hft/zwy.mktdata.binance.raw.rx.dat
data_size: 33554432
...

# Metadata (from header segment)
magic: 0x00024d4853544648
version: 2
max_consumers: 8
header_size: 4096
...

# Destroy segments
$ hft-shm destroy zwy.mktdata.binance.raw.rx
Destroyed zwy.mktdata.binance.raw.rx
  Header: /dev/shm/hft/zwy.mktdata.binance.raw.rx.hdr
  Data:   /dev/shm/hft/zwy.mktdata.binance.raw.rx.dat
```

---

## Implementation Status

### Completed (Version 2)

| File | Status |
|------|--------|
| `src/include/hftshm/layout.hpp` | Implemented - metadata, segment size functions |
| `src/include/hftshm/types.hpp` | Implemented - size parsing, hugepage support |
| `src/include/hftshm/policies/platform.hpp` | Implemented - dual segment path helpers |
| `src/include/hftshm/policies/config.hpp` | Implemented - TOML parsing with max_consumers |
| `src/cli/main.cpp` | Implemented - init/info/destroy with dual segments |
| `test/test_layout.cpp` | Implemented - layout tests |

### Future Work

| Component | Description |
|-----------|-------------|
| `channel.hpp` | Channel class wrapping memory layout |
| Producer/Consumer APIs | Attach/detach, publish/consume methods |
| Wait strategies | Busy spin, yield, adaptive, block |
| Metrics collection | Runtime metrics via cold cache lines |

---
---

# HFT 共享内存布局 (版本 2) - 中文版

## 概述

为 `hft-shm` 设计的增强型 SPMC（单生产者多消费者）共享内存布局，基于 `disruptor_zwy` 的设计模式。

**核心设计决策 (v2)**：头部和数据存储在**独立的内存段**中，以获得最佳内存性能。

---

## 内存段架构

每个环形缓冲区定义会创建两个共享内存段：

```
头部段 (.hdr) - 使用普通 4KB 页面
┌─────────────────────────────────────────────────────────────┐
│ 区块 0: 元数据 (64 字节 = 1 个缓存行)                         │
├─────────────────────────────────────────────────────────────┤
│ 区块 1: 生产者状态 (128 字节 = 2 个缓存行)                    │
├─────────────────────────────────────────────────────────────┤
│ 区块 2: 消费者 0 状态 (128 字节)                              │
├─────────────────────────────────────────────────────────────┤
│ ...                                                         │
├─────────────────────────────────────────────────────────────┤
│ 区块 N+1: 消费者 N-1 状态 (128 字节)                          │
├─────────────────────────────────────────────────────────────┤
│ 填充 (对齐到 4KB 页面边界)                                    │
└─────────────────────────────────────────────────────────────┘

数据段 (.dat) - 启用时使用大页
┌─────────────────────────────────────────────────────────────┐
│ 环形缓冲区数据 (buffer_size 字节，2的幂次方)                   │
└─────────────────────────────────────────────────────────────┘
```

### 为什么要分离内存段？

| 方面 | 单一内存段 | 分离内存段 |
|------|-----------|-----------|
| 内存浪费 | 使用大页时约 2MB 填充 | 无 |
| 头部 TLB | 使用大页 TLB（浪费） | 使用普通 TLB |
| 数据 TLB | 最优 | 最优 |
| 缓存行为 | 大页可能导致更大的缓存失效范围 | 更好 - 头部使用普通页面 |

**结果**：头部（约 1-2KB，频繁修改）使用普通 4KB 页面。数据（32MB-1GB，顺序访问）获得完整的大页优势。

---

## 命名规范

对于段键 `foo.bar.baz`：
- 头部段：`/dev/shm/hft/foo.bar.baz.hdr`
- 数据段：`/dev/shm/hft/foo.bar.baz.dat`

---

## 区块 0：元数据 (64 字节)

```cpp
// layout.hpp - 版本 2
inline constexpr std::size_t CACHE_LINE = std::hardware_destructive_interference_size;
inline constexpr uint32_t PAGE_SIZE = 4096;
inline constexpr uint64_t METADATA_MAGIC = 0x00024D4853544648ULL;  // "HFTSHM\x02\x00"
inline constexpr uint8_t METADATA_VERSION = 2;

struct alignas(CACHE_LINE) metadata {
    uint64_t magic;               // 0x00: 魔数，用于验证
    uint8_t  version;             // 0x08: 布局版本 (2)
    uint8_t  max_consumers;       // 0x09: 最大消费者数（创建时固定）
    uint16_t event_size;          // 0x0A: 每个事件/元素的大小
    uint32_t producer_pid;        // 0x0C: 生产者 PID（0 = 未附加）
    uint32_t buffer_size;         // 0x10: 环形缓冲区容量（2的幂次方）
    uint32_t producer_offset;     // 0x14: 生产者区块偏移量
    uint32_t consumer_0_offset;   // 0x18: 消费者 0 区块偏移量
    uint32_t header_size;         // 0x1C: 头部段总大小（页面对齐）
    uint32_t index_mask;          // 0x20: = buffer_size - 1（预计算）
    uint8_t  padding[CACHE_LINE - 36];  // 0x24-0x3F（根据 CACHE_LINE 动态调整）
};
static_assert(sizeof(metadata) == CACHE_LINE);
static_assert(alignof(metadata) == CACHE_LINE);
```

### 内存布局偏移量

```
偏移 0x00: magic               (8 字节)
偏移 0x08: version             (1 字节)
偏移 0x09: max_consumers       (1 字节)
偏移 0x0A: event_size          (2 字节)
偏移 0x0C: producer_pid        (4 字节)
偏移 0x10: buffer_size         (4 字节)
偏移 0x14: producer_offset     (4 字节)
偏移 0x18: consumer_0_offset   (4 字节)
偏移 0x1C: header_size         (4 字节)
偏移 0x20: index_mask          (4 字节)
偏移 0x24: padding             (28 字节，64字节缓存行)
```

---

## 区块 1：生产者状态 (128 字节 = 2 个缓存行)

### 缓存行 1：热路径（序列号）

```cpp
struct alignas(CACHE_LINE) producer_sequences {
    std::atomic<int64_t> cursor;           // 0x00: 已声明的序列号（写入头）
    std::atomic<int64_t> published;        // 0x08: 对消费者可见
    int64_t cached_min_consumer;           // 0x10: 缓存的最慢消费者（relaxed）
    uint32_t flags;                        // 0x18: ACTIVE=1, DRAINING=2
    uint32_t producer_id;                  // 0x1C: 身份标识
    uint8_t  padding[32];                  // 0x20-0x3F
};
```

### 缓存行 2：冷路径（指标）

```cpp
struct alignas(CACHE_LINE) producer_metrics {
    std::atomic<uint64_t> publish_count;   // 0x00: 已发布事件总数
    std::atomic<uint64_t> claim_spins;     // 0x08: 等待容量的自旋次数
    std::atomic<uint64_t> batch_count;     // 0x10: 批量发布操作次数
    uint64_t last_publish_ts;              // 0x18: 最后发布时间戳（纳秒）
    uint8_t  padding[32];                  // 0x20-0x3F
};
```

### 组合结构

```cpp
struct producer_state {
    producer_sequences seq;    // 热：每次发布
    producer_metrics metrics;  // 冷：仅用于监控
};
static_assert(sizeof(producer_state) == 128);
```

---

## 区块 2-N：消费者状态 (每个 128 字节)

### 缓存行 1：热路径（序列号）

```cpp
struct alignas(CACHE_LINE) consumer_sequences {
    std::atomic<int64_t> sequence;         // 0x00: 当前读取位置（尾部）
    int64_t cached_available;              // 0x08: 缓存的 producer.published
    std::atomic<uint32_t> status;          // 0x10: 见状态枚举
    uint32_t consumer_id;                  // 0x14: 身份标识
    uint32_t wait_strategy;                // 0x18: 见等待策略枚举
    uint32_t reserved;                     // 0x1C
    uint8_t  padding[32];                  // 0x20-0x3F
};

// 状态值
constexpr uint32_t STATUS_INACTIVE  = 0;  // 未激活
constexpr uint32_t STATUS_ACTIVE    = 1;  // 激活
constexpr uint32_t STATUS_LAGGING   = 2;  // 落后
constexpr uint32_t STATUS_ALERTED   = 3;  // 已告警

// 等待策略值
constexpr uint32_t WAIT_BUSY_SPIN   = 0;  // 忙等待
constexpr uint32_t WAIT_YIELD       = 1;  // 让出 CPU
constexpr uint32_t WAIT_ADAPTIVE    = 2;  // 自适应
constexpr uint32_t WAIT_BLOCK       = 3;  // 阻塞
```

### 缓存行 2：冷路径（指标）

```cpp
struct alignas(CACHE_LINE) consumer_metrics {
    std::atomic<uint64_t> process_count;   // 0x00: 已处理事件数
    std::atomic<uint64_t> batch_count;     // 0x08: 已处理批次数
    std::atomic<uint64_t> wait_cycles;     // 0x10: 总等待周期
    std::atomic<uint64_t> lag_events;      // 0x18: 因覆盖而丢失的事件
    uint64_t last_read_ts;                 // 0x20: 最后读取时间戳（纳秒）
    uint8_t  padding[24];                  // 0x28-0x3F
};
```

### 组合结构

```cpp
struct consumer_state {
    consumer_sequences seq;    // 热：每次读取
    consumer_metrics metrics;  // 冷：仅用于监控
};
static_assert(sizeof(consumer_state) == 128);
```

---

## 偏移量计算（已实现）

```cpp
// layout.hpp
inline constexpr uint32_t DEFAULT_PRODUCER_SECTION_SIZE = 2 * CACHE_LINE;  // 128 字节
inline constexpr uint32_t DEFAULT_CONSUMER_SECTION_SIZE = 2 * CACHE_LINE;  // 128 字节

inline constexpr uint32_t default_producer_offset() {
    return CACHE_LINE;  // 紧跟元数据之后
}

inline constexpr uint32_t default_consumer_0_offset(
    uint32_t producer_section_size = DEFAULT_PRODUCER_SECTION_SIZE
) {
    return CACHE_LINE + producer_section_size;
}

// 计算原始头部大小（页面对齐前）
inline constexpr uint32_t raw_header_size(
    uint8_t max_consumers,
    uint32_t producer_section_size = DEFAULT_PRODUCER_SECTION_SIZE,
    uint32_t consumer_section_size = DEFAULT_CONSUMER_SECTION_SIZE
) {
    return CACHE_LINE + producer_section_size + (max_consumers * consumer_section_size);
}

// 计算头部段大小（页面对齐）
inline uint32_t header_segment_size(
    uint8_t max_consumers,
    uint32_t producer_section_size = DEFAULT_PRODUCER_SECTION_SIZE,
    uint32_t consumer_section_size = DEFAULT_CONSUMER_SECTION_SIZE
) {
    uint32_t raw = raw_header_size(max_consumers, producer_section_size, consumer_section_size);
    return ((raw + PAGE_SIZE - 1) / PAGE_SIZE) * PAGE_SIZE;
}

// 计算数据段大小（使用大页时对齐到大页边界）
inline uint32_t data_segment_size(
    uint32_t buffer_size,
    uint32_t hugepage_size  // 0 表示普通页面
) {
    if (hugepage_size == 0) {
        return buffer_size;  // 已是 2 的幂次方
    }
    return ((buffer_size + hugepage_size - 1) / hugepage_size) * hugepage_size;
}
```

### 计算示例

**max_consumers=8, buffer_size=32MB：**
```
raw_header_size = 64 + 128 + (8 × 128) = 1216 字节
header_segment_size = round_up(1216, 4096) = 4096 字节 (1 页)
data_segment_size = 32MB（2 的幂次方，无需对齐）

头部段布局：
  偏移 0x000: 元数据               (64 字节)
  偏移 0x040: 生产者区块           (128 字节)
  偏移 0x0C0: 消费者 0             (128 字节)
  偏移 0x140: 消费者 1             (128 字节)
  ...
  偏移 0x440: 消费者 7             (128 字节)
  偏移 0x4C0: 填充                 (2880 字节)
  总计: 4096 字节 (1 页)
```

---

## 设计原理

| 决策 | 原理 |
|------|------|
| **分离头部/数据段** | 头部使用普通页面（小，频繁修改），数据使用大页（大，顺序访问） |
| **每个角色 2 个缓存行** | 热/冷分离，防止指标污染序列号缓存行 |
| **cursor vs published** | 两阶段提交：声明槽位，写入数据，然后发布（批处理友好） |
| **cached_min_consumer** | 生产者避免每次发布都扫描所有消费者 |
| **cached_available** | 消费者避免跨缓存行读取 producer.published |
| **wait_strategy 字段** | 消费者指示首选等待模式，用于自适应行为 |
| **单调 64 位序列号** | 永不回绕 - 使用 `seq & index_mask` 进行缓冲区索引 |
| **预计算 index_mask** | 避免取模；支持无分支 `pos & mask` |
| **页面对齐头部** | 确保干净的内存边界，简化 mmap |
| **紧凑 uint32 偏移量** | 足以支持约 2GB 的段，减少元数据大小 |

---

## 内存序

基于 `disruptor_zwy` 模式：

| 操作 | 内存序 | 原理 |
|------|--------|------|
| 生产者声明 cursor | `acquire` | 看到之前的写入 |
| 生产者发布 | `release` | 使事件数据可见 |
| 消费者读取序列号 | `acquire` | 看到已发布的数据 |
| 消费者更新序列号 | `release` | 向生产者发出进度信号 |
| cached_* 字段 | `relaxed` | 仅用于优化，可接受过期值 |
| 指标计数器 | `relaxed` | 近似计数即可 |

---

## CLI 使用方法

```bash
# 从配置创建段
$ hft-shm init
Creating zwy.mktdata.binance.raw.rx:
  Header: /dev/shm/hft/zwy.mktdata.binance.raw.rx.hdr (4KB)
  Data:   /dev/shm/hft/zwy.mktdata.binance.raw.rx.dat (32MB, 2MB hugepages)

# 显示段信息
$ hft-shm info zwy.mktdata.binance.raw.rx
name: zwy/mktdata/binance/raw/rx
header_path: /dev/shm/hft/zwy.mktdata.binance.raw.rx.hdr
header_size: 4096
data_path: /dev/shm/hft/zwy.mktdata.binance.raw.rx.dat
data_size: 33554432
...

# 元数据（来自头部段）
magic: 0x00024d4853544648
version: 2
max_consumers: 8
header_size: 4096
...

# 销毁段
$ hft-shm destroy zwy.mktdata.binance.raw.rx
Destroyed zwy.mktdata.binance.raw.rx
  Header: /dev/shm/hft/zwy.mktdata.binance.raw.rx.hdr
  Data:   /dev/shm/hft/zwy.mktdata.binance.raw.rx.dat
```

---

## 实现状态

### 已完成（版本 2）

| 文件 | 状态 |
|------|------|
| `src/include/hftshm/layout.hpp` | 已实现 - 元数据，段大小函数 |
| `src/include/hftshm/types.hpp` | 已实现 - 大小解析，大页支持 |
| `src/include/hftshm/policies/platform.hpp` | 已实现 - 双段路径辅助函数 |
| `src/include/hftshm/policies/config.hpp` | 已实现 - TOML 解析，含 max_consumers |
| `src/cli/main.cpp` | 已实现 - init/info/destroy 支持双段 |
| `test/test_layout.cpp` | 已实现 - 布局测试 |

### 待完成

| 组件 | 描述 |
|------|------|
| `channel.hpp` | 封装内存布局的 Channel 类 |
| 生产者/消费者 API | attach/detach，publish/consume 方法 |
| 等待策略 | 忙等待，让出，自适应，阻塞 |
| 指标收集 | 通过冷缓存行收集运行时指标 |
