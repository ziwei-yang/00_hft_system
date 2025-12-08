#include <cassert>
#include <iostream>
#include <cstring>

#include <hftshm/layout.hpp>

namespace {

void test_cache_line_size() {
    // Cache line must be at least 64 bytes
    assert(hftshm::CACHE_LINE >= 64);
    // Cache line should be a power of 2
    assert((hftshm::CACHE_LINE & (hftshm::CACHE_LINE - 1)) == 0);
    std::cout << "  [PASS] CACHE_LINE size (= " << hftshm::CACHE_LINE << ")\n";
}

void test_metadata_size() {
    // Metadata must be exactly one cache line
    assert(sizeof(hftshm::metadata) == hftshm::CACHE_LINE);
    std::cout << "  [PASS] metadata size (= " << sizeof(hftshm::metadata) << ")\n";
}

void test_metadata_alignment() {
    // Metadata must be cache-line aligned
    assert(alignof(hftshm::metadata) == hftshm::CACHE_LINE);
    std::cout << "  [PASS] metadata alignment (= " << alignof(hftshm::metadata) << ")\n";
}

void test_metadata_fixed_size() {
    // Fixed fields should be 36 bytes
    assert(hftshm::METADATA_FIXED_SIZE == 36);
    std::cout << "  [PASS] METADATA_FIXED_SIZE (= " << hftshm::METADATA_FIXED_SIZE << ")\n";
}

void test_default_offsets() {
    // Producer offset should be right after metadata
    assert(hftshm::default_producer_offset() == hftshm::CACHE_LINE);

    // Consumer 0 offset should be after producer section
    assert(hftshm::default_consumer_0_offset() == hftshm::CACHE_LINE + hftshm::DEFAULT_PRODUCER_SECTION_SIZE);

    // Raw header size for 4 consumers
    uint8_t max_consumers = 4;
    uint32_t expected_raw_hdr = hftshm::CACHE_LINE +
                                  hftshm::DEFAULT_PRODUCER_SECTION_SIZE +
                                  max_consumers * hftshm::DEFAULT_CONSUMER_SECTION_SIZE;
    assert(hftshm::raw_header_size(max_consumers) == expected_raw_hdr);

    // Header segment size should be page-aligned
    uint32_t hdr_size = hftshm::header_segment_size(max_consumers);
    assert(hdr_size >= expected_raw_hdr);
    assert(hdr_size % hftshm::PAGE_SIZE == 0);

    std::cout << "  [PASS] default offsets\n";
}

void test_segment_sizes() {
    // Test header_segment_size - should be page aligned
    uint8_t max_consumers = 8;
    uint32_t raw = hftshm::raw_header_size(max_consumers);
    uint32_t hdr_size = hftshm::header_segment_size(max_consumers);

    assert(hdr_size >= raw);
    assert(hdr_size % hftshm::PAGE_SIZE == 0);
    assert(hdr_size == hftshm::PAGE_SIZE);  // For 8 consumers, raw=1216, rounds to 4096

    // Test data_segment_size without hugepages
    uint32_t buffer_size = 32 * 1024 * 1024;  // 32MB
    uint32_t dat_size = hftshm::data_segment_size(buffer_size, 0);
    assert(dat_size == buffer_size);

    // Test data_segment_size with 2MB hugepages
    uint32_t dat_size_hp = hftshm::data_segment_size(buffer_size, 2 * 1024 * 1024);
    assert(dat_size_hp == buffer_size);  // 32MB is already aligned to 2MB

    // Test data_segment_size with non-aligned buffer
    uint32_t small_buf = 3 * 1024 * 1024;  // 3MB
    uint32_t small_dat_hp = hftshm::data_segment_size(small_buf, 2 * 1024 * 1024);
    assert(small_dat_hp == 4 * 1024 * 1024);  // Rounds up to 4MB

    std::cout << "  [PASS] segment sizes\n";
}

void test_metadata_init() {
    // Allocate aligned memory for metadata
    alignas(hftshm::CACHE_LINE) uint8_t buffer[hftshm::CACHE_LINE * 2];
    std::memset(buffer, 0xFF, sizeof(buffer));  // Fill with non-zero to detect zeroing

    uint8_t max_consumers = 4;
    uint16_t event_size = 128;
    uint32_t buffer_size = 4 * 1024 * 1024;  // 4MB
    uint32_t prod_off = hftshm::default_producer_offset();
    uint32_t cons_off = hftshm::default_consumer_0_offset();
    uint32_t hdr_size = hftshm::header_segment_size(max_consumers);

    hftshm::metadata_init(buffer, max_consumers, event_size, buffer_size, prod_off, cons_off, hdr_size);

    const auto* meta = hftshm::metadata_get(buffer);

    assert(meta->magic == hftshm::METADATA_MAGIC);
    assert(meta->version == hftshm::METADATA_VERSION);
    assert(meta->max_consumers == max_consumers);
    assert(meta->event_size == event_size);
    assert(meta->producer_pid == 0);
    assert(meta->buffer_size == buffer_size);
    assert(meta->producer_offset == prod_off);
    assert(meta->consumer_0_offset == cons_off);
    assert(meta->header_size == hdr_size);
    assert(meta->index_mask == buffer_size - 1);

    // Check padding is zeroed
    for (size_t i = 0; i < sizeof(meta->padding); ++i) {
        assert(meta->padding[i] == 0);
    }

    std::cout << "  [PASS] metadata_init\n";
}

void test_metadata_validate() {
    alignas(hftshm::CACHE_LINE) uint8_t buffer[hftshm::CACHE_LINE];

    // Initialize valid metadata
    hftshm::metadata_init(buffer, 4, 128, 4 * 1024 * 1024,
                          hftshm::default_producer_offset(),
                          hftshm::default_consumer_0_offset(),
                          hftshm::header_segment_size(4));

    assert(hftshm::metadata_validate(buffer) == true);

    // Corrupt magic
    auto* meta = reinterpret_cast<hftshm::metadata*>(buffer);
    meta->magic = 0;
    assert(hftshm::metadata_validate(buffer) == false);

    // Restore magic, corrupt version
    meta->magic = hftshm::METADATA_MAGIC;
    meta->version = 99;
    assert(hftshm::metadata_validate(buffer) == false);

    std::cout << "  [PASS] metadata_validate\n";
}

void test_section_sizes_from_meta() {
    alignas(hftshm::CACHE_LINE) uint8_t buffer[hftshm::CACHE_LINE];

    uint8_t max_consumers = 4;
    hftshm::metadata_init(buffer, max_consumers, 128, 4 * 1024 * 1024,
                          hftshm::default_producer_offset(),
                          hftshm::default_consumer_0_offset(),
                          hftshm::header_segment_size(max_consumers));

    const auto* meta = hftshm::metadata_get(buffer);

    // Producer section size
    uint32_t prod_size = hftshm::producer_section_size(meta);
    assert(prod_size == hftshm::DEFAULT_PRODUCER_SECTION_SIZE);

    // Consumer section size
    uint32_t cons_size = hftshm::consumer_section_size(meta);
    assert(cons_size == hftshm::DEFAULT_CONSUMER_SECTION_SIZE);

    std::cout << "  [PASS] section sizes from metadata\n";
}

void test_consumer_offsets() {
    alignas(hftshm::CACHE_LINE) uint8_t buffer[hftshm::CACHE_LINE];

    uint8_t max_consumers = 4;
    hftshm::metadata_init(buffer, max_consumers, 128, 4 * 1024 * 1024,
                          hftshm::default_producer_offset(),
                          hftshm::default_consumer_0_offset(),
                          hftshm::header_segment_size(max_consumers));

    const auto* meta = hftshm::metadata_get(buffer);
    uint32_t cons_size = hftshm::consumer_section_size(meta);

    // Consumer 0 offset should match metadata
    assert(hftshm::consumer_offset(meta, 0) == meta->consumer_0_offset);

    // Each subsequent consumer should be cons_size bytes further
    for (uint8_t i = 1; i < max_consumers; ++i) {
        uint32_t expected = meta->consumer_0_offset + i * cons_size;
        assert(hftshm::consumer_offset(meta, i) == expected);
    }

    std::cout << "  [PASS] consumer offsets\n";
}

void test_memory_layout() {
    // Verify the memory layout matches the documented offsets
    alignas(hftshm::CACHE_LINE) uint8_t buffer[hftshm::CACHE_LINE];
    std::memset(buffer, 0, sizeof(buffer));

    auto* meta = reinterpret_cast<hftshm::metadata*>(buffer);

    // Check field offsets (assuming 64-byte cache line)
    assert(reinterpret_cast<uint8_t*>(&meta->magic) - buffer == 0x00);
    assert(reinterpret_cast<uint8_t*>(&meta->version) - buffer == 0x08);
    assert(reinterpret_cast<uint8_t*>(&meta->max_consumers) - buffer == 0x09);
    assert(reinterpret_cast<uint8_t*>(&meta->event_size) - buffer == 0x0A);
    assert(reinterpret_cast<uint8_t*>(&meta->producer_pid) - buffer == 0x0C);
    assert(reinterpret_cast<uint8_t*>(&meta->buffer_size) - buffer == 0x10);
    assert(reinterpret_cast<uint8_t*>(&meta->producer_offset) - buffer == 0x14);
    assert(reinterpret_cast<uint8_t*>(&meta->consumer_0_offset) - buffer == 0x18);
    assert(reinterpret_cast<uint8_t*>(&meta->header_size) - buffer == 0x1C);
    assert(reinterpret_cast<uint8_t*>(&meta->index_mask) - buffer == 0x20);
    assert(reinterpret_cast<uint8_t*>(&meta->padding) - buffer == 0x24);

    std::cout << "  [PASS] memory layout offsets\n";
}

} // anonymous namespace

void run_layout_tests() {
    std::cout << "Running layout tests...\n";
    test_cache_line_size();
    test_metadata_size();
    test_metadata_alignment();
    test_metadata_fixed_size();
    test_default_offsets();
    test_segment_sizes();
    test_metadata_init();
    test_metadata_validate();
    test_section_sizes_from_meta();
    test_consumer_offsets();
    test_memory_layout();
    std::cout << "All layout tests passed!\n\n";
}
