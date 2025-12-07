#include <cassert>
#include <iostream>
#include <stdexcept>

#include <hftshm/types.hpp>

namespace {

void test_parse_size_bytes() {
    assert(hftshm::parse_size("100") == 100);
    assert(hftshm::parse_size("100B") == 100);
    assert(hftshm::parse_size("100b") == 100);
    std::cout << "  [PASS] parse_size bytes\n";
}

void test_parse_size_kilobytes() {
    assert(hftshm::parse_size("1KB") == 1024);
    assert(hftshm::parse_size("1kb") == 1024);
    assert(hftshm::parse_size("1K") == 1024);
    assert(hftshm::parse_size("2KB") == 2048);
    assert(hftshm::parse_size("512KB") == 512 * 1024);
    std::cout << "  [PASS] parse_size kilobytes\n";
}

void test_parse_size_megabytes() {
    assert(hftshm::parse_size("1MB") == 1024 * 1024);
    assert(hftshm::parse_size("1mb") == 1024 * 1024);
    assert(hftshm::parse_size("1M") == 1024 * 1024);
    assert(hftshm::parse_size("32MB") == 32ULL * 1024 * 1024);
    assert(hftshm::parse_size("2MB") == 2ULL * 1024 * 1024);
    std::cout << "  [PASS] parse_size megabytes\n";
}

void test_parse_size_gigabytes() {
    assert(hftshm::parse_size("1GB") == 1024ULL * 1024 * 1024);
    assert(hftshm::parse_size("1gb") == 1024ULL * 1024 * 1024);
    assert(hftshm::parse_size("1G") == 1024ULL * 1024 * 1024);
    assert(hftshm::parse_size("2GB") == 2ULL * 1024 * 1024 * 1024);
    std::cout << "  [PASS] parse_size gigabytes\n";
}

void test_parse_size_invalid() {
    bool caught = false;
    try {
        hftshm::parse_size("");
    } catch (const hftshm::SizeParseError&) {
        caught = true;
    }
    assert(caught);

    caught = false;
    try {
        hftshm::parse_size("abc");
    } catch (const hftshm::SizeParseError&) {
        caught = true;
    }
    assert(caught);

    caught = false;
    try {
        hftshm::parse_size("100TB");  // Unknown unit
    } catch (const hftshm::SizeParseError&) {
        caught = true;
    }
    assert(caught);

    std::cout << "  [PASS] parse_size invalid input\n";
}

void test_parse_hugepage_size() {
    assert(hftshm::parse_hugepage_size("2MB") == hftshm::HUGEPAGE_2MB);
    assert(hftshm::parse_hugepage_size("1GB") == hftshm::HUGEPAGE_1GB);
    assert(hftshm::parse_hugepage_size("") == hftshm::HUGEPAGE_AUTO);
    assert(hftshm::parse_hugepage_size("auto") == hftshm::HUGEPAGE_AUTO);
    assert(hftshm::parse_hugepage_size("none") == 0);
    assert(hftshm::parse_hugepage_size("0") == 0);
    std::cout << "  [PASS] parse_hugepage_size\n";
}

void test_parse_hugepage_size_invalid() {
    bool caught = false;
    try {
        hftshm::parse_hugepage_size("4MB");  // Invalid hugepage size
    } catch (const hftshm::SizeParseError&) {
        caught = true;
    }
    assert(caught);
    std::cout << "  [PASS] parse_hugepage_size invalid\n";
}

void test_format_size() {
    assert(hftshm::format_size(100) == "100B");
    assert(hftshm::format_size(1024) == "1KB");
    assert(hftshm::format_size(2048) == "2KB");
    assert(hftshm::format_size(1024 * 1024) == "1MB");
    assert(hftshm::format_size(32ULL * 1024 * 1024) == "32MB");
    assert(hftshm::format_size(1024ULL * 1024 * 1024) == "1GB");
    assert(hftshm::format_size(2ULL * 1024 * 1024 * 1024) == "2GB");
    std::cout << "  [PASS] format_size\n";
}

void test_auto_hugepage_size() {
    // < 512MB -> 2MB hugepages
    assert(hftshm::auto_hugepage_size(1ULL * 1024 * 1024) == hftshm::HUGEPAGE_2MB);
    assert(hftshm::auto_hugepage_size(32ULL * 1024 * 1024) == hftshm::HUGEPAGE_2MB);
    assert(hftshm::auto_hugepage_size(511ULL * 1024 * 1024) == hftshm::HUGEPAGE_2MB);

    // >= 512MB -> 1GB hugepages
    assert(hftshm::auto_hugepage_size(512ULL * 1024 * 1024) == hftshm::HUGEPAGE_1GB);
    assert(hftshm::auto_hugepage_size(1024ULL * 1024 * 1024) == hftshm::HUGEPAGE_1GB);
    assert(hftshm::auto_hugepage_size(2ULL * 1024 * 1024 * 1024) == hftshm::HUGEPAGE_1GB);

    std::cout << "  [PASS] auto_hugepage_size\n";
}

void test_align_to_hugepage() {
    // No alignment when hugepage_size is 0
    assert(hftshm::align_to_hugepage(100, 0) == 100);
    assert(hftshm::align_to_hugepage(1024 * 1024, 0) == 1024 * 1024);

    // Align to 2MB boundary
    assert(hftshm::align_to_hugepage(hftshm::HUGEPAGE_2MB, hftshm::HUGEPAGE_2MB) == hftshm::HUGEPAGE_2MB);
    assert(hftshm::align_to_hugepage(1, hftshm::HUGEPAGE_2MB) == hftshm::HUGEPAGE_2MB);
    assert(hftshm::align_to_hugepage(hftshm::HUGEPAGE_2MB + 1, hftshm::HUGEPAGE_2MB) == 2 * hftshm::HUGEPAGE_2MB);
    assert(hftshm::align_to_hugepage(32ULL * 1024 * 1024, hftshm::HUGEPAGE_2MB) == 32ULL * 1024 * 1024);

    // Align to 1GB boundary
    assert(hftshm::align_to_hugepage(hftshm::HUGEPAGE_1GB, hftshm::HUGEPAGE_1GB) == hftshm::HUGEPAGE_1GB);
    assert(hftshm::align_to_hugepage(1, hftshm::HUGEPAGE_1GB) == hftshm::HUGEPAGE_1GB);
    assert(hftshm::align_to_hugepage(512ULL * 1024 * 1024, hftshm::HUGEPAGE_1GB) == hftshm::HUGEPAGE_1GB);

    std::cout << "  [PASS] align_to_hugepage\n";
}

} // anonymous namespace

void run_types_tests() {
    std::cout << "Running types tests...\n";
    test_parse_size_bytes();
    test_parse_size_kilobytes();
    test_parse_size_megabytes();
    test_parse_size_gigabytes();
    test_parse_size_invalid();
    test_parse_hugepage_size();
    test_parse_hugepage_size_invalid();
    test_format_size();
    test_auto_hugepage_size();
    test_align_to_hugepage();
    std::cout << "All types tests passed!\n\n";
}
