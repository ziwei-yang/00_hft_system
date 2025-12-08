#pragma once

#include <cstdint>
#include <cstddef>
#include <algorithm>
#include <new>  // For std::hardware_destructive_interference_size

namespace hftshm {

// Cache line size - must be available at compile time (C++17 required)
inline constexpr std::size_t CACHE_LINE = std::hardware_destructive_interference_size;
static_assert(CACHE_LINE >= 64, "Unexpected cache line size");

// Page size (for header segment alignment)
inline constexpr uint32_t PAGE_SIZE = 4096;

// Magic number: "HFTSHM\x02\x00" in little-endian (version 2)
inline constexpr uint64_t METADATA_MAGIC = 0x00024D4853544648ULL;

// Current layout version (2 = separate header/data segments)
inline constexpr uint8_t METADATA_VERSION = 2;

// Fixed fields size (before padding)
inline constexpr std::size_t METADATA_FIXED_SIZE =
    sizeof(uint64_t) +  // magic
    sizeof(uint8_t) +   // version
    sizeof(uint8_t) +   // max_consumers
    sizeof(uint16_t) +  // event_size
    sizeof(uint32_t) +  // producer_pid
    sizeof(uint32_t) +  // buffer_size
    sizeof(uint32_t) +  // producer_offset
    sizeof(uint32_t) +  // consumer_0_offset
    sizeof(uint32_t) +  // header_size
    sizeof(uint32_t);   // index_mask
// = 36 bytes

// Metadata section (cache-line aligned)
// SPMC only: single producer, multiple consumers
// Compact 32-bit sizes/offsets (max ~2GB segments)
// Version 2: header and data are separate segments
struct alignas(CACHE_LINE) metadata {
    uint64_t magic;               // 0x00: Magic number
    uint8_t  version;             // 0x08: Layout version
    uint8_t  max_consumers;       // 0x09: Max consumers (fixed at creation)
    uint16_t event_size;          // 0x0A: Size of each event
    uint32_t producer_pid;        // 0x0C: Producer PID (0 = not attached)
    uint32_t buffer_size;         // 0x10: Ring buffer capacity (power of 2)
    uint32_t producer_offset;     // 0x14: Offset to producer section
    uint32_t consumer_0_offset;   // 0x18: Offset to consumer 0 section
    uint32_t header_size;         // 0x1C: Total header segment size
    uint32_t index_mask;          // 0x20: = buffer_size - 1
    uint8_t  padding[CACHE_LINE - METADATA_FIXED_SIZE];  // Dynamic padding
};
static_assert(sizeof(metadata) == CACHE_LINE);
static_assert(alignof(metadata) == CACHE_LINE);

// Default section sizes (can be overridden by clients)
inline constexpr uint32_t DEFAULT_PRODUCER_SECTION_SIZE = 2 * CACHE_LINE;  // 128 bytes
inline constexpr uint32_t DEFAULT_CONSUMER_SECTION_SIZE = 2 * CACHE_LINE;  // 128 bytes

// Calculate offsets for default layout
inline constexpr uint32_t default_producer_offset() {
    return CACHE_LINE;  // Right after metadata
}

inline constexpr uint32_t default_consumer_0_offset(uint32_t producer_section_size = DEFAULT_PRODUCER_SECTION_SIZE) {
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

// Initialize metadata at given memory location
inline void metadata_init(
    void* ptr,
    uint8_t max_consumers,
    uint16_t event_size,
    uint32_t buffer_size,
    uint32_t producer_offset,
    uint32_t consumer_0_offset,
    uint32_t header_size
) {
    auto* meta = static_cast<metadata*>(ptr);
    meta->magic = METADATA_MAGIC;
    meta->version = METADATA_VERSION;
    meta->max_consumers = max_consumers;
    meta->event_size = event_size;
    meta->producer_pid = 0;  // 0 = no producer attached yet
    meta->buffer_size = buffer_size;
    meta->producer_offset = producer_offset;
    meta->consumer_0_offset = consumer_0_offset;
    meta->header_size = header_size;
    meta->index_mask = buffer_size - 1;  // Assumes power of 2
    std::fill(std::begin(meta->padding), std::end(meta->padding), 0);
}

// Validate metadata magic and version
inline bool metadata_validate(const void* ptr) {
    const auto* meta = static_cast<const metadata*>(ptr);
    return meta->magic == METADATA_MAGIC && meta->version == METADATA_VERSION;
}

// Get const pointer to metadata
inline const metadata* metadata_get(const void* ptr) {
    return static_cast<const metadata*>(ptr);
}

// Helper: get producer section size
inline uint32_t producer_section_size(const metadata* meta) {
    return meta->consumer_0_offset - meta->producer_offset;
}

// Helper: get consumer section size
inline uint32_t consumer_section_size(const metadata* meta) {
    // In v2, header_size is page-aligned, so use raw calculation
    uint32_t raw_end = raw_header_size(meta->max_consumers);
    return (raw_end - meta->consumer_0_offset) / meta->max_consumers;
}

// Helper: get consumer N offset
inline uint32_t consumer_offset(const metadata* meta, uint8_t n) {
    return meta->consumer_0_offset + n * consumer_section_size(meta);
}

} // namespace hftshm
