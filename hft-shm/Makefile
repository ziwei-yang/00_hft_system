# HFT Shared Memory Management Tool
# C++20 with policy-based design

CXX := g++
CXXFLAGS := -std=c++20 -Wall -Wextra -Wpedantic -O2
INCLUDES := -Isrc/include -Isrc/third_party

# Platform-specific flags
UNAME_S := $(shell uname -s)
ifeq ($(UNAME_S),Linux)
    LDFLAGS := -lrt
endif

# Directories
SRC_DIR := src
CLI_DIR := $(SRC_DIR)/cli
TEST_DIR := test
BUILD_DIR := build

# Output binaries
CLI_BIN := $(BUILD_DIR)/hft-shm
TEST_BIN := $(BUILD_DIR)/test_runner

# Source files
CLI_SRCS := $(CLI_DIR)/main.cpp
TEST_SRCS := $(wildcard $(TEST_DIR)/*.cpp)

# Default target
.PHONY: all
all: cli

# Create build directory
$(BUILD_DIR):
	mkdir -p $(BUILD_DIR)

# Build CLI tool
.PHONY: cli
cli: $(BUILD_DIR) $(CLI_BIN)

$(CLI_BIN): $(CLI_SRCS)
	$(CXX) $(CXXFLAGS) $(INCLUDES) -o $@ $^ $(LDFLAGS)

# Build tests
.PHONY: test
test: $(BUILD_DIR) $(TEST_BIN)
	./$(TEST_BIN)

$(TEST_BIN): $(TEST_SRCS)
	$(CXX) $(CXXFLAGS) $(INCLUDES) -o $@ $^ $(LDFLAGS)

# Clean build artifacts
.PHONY: clean
clean:
	rm -rf $(BUILD_DIR)

# Install (optional)
.PHONY: install
install: cli
	cp $(CLI_BIN) /usr/local/bin/

# Debug build
.PHONY: debug
debug: CXXFLAGS := -std=c++20 -Wall -Wextra -Wpedantic -g -O0 -DDEBUG
debug: cli

# Help
.PHONY: help
help:
	@echo "HFT Shared Memory Management Tool"
	@echo ""
	@echo "Targets:"
	@echo "  all     - Build CLI tool (default)"
	@echo "  cli     - Build CLI tool"
	@echo "  test    - Build and run tests"
	@echo "  clean   - Remove build artifacts"
	@echo "  debug   - Build with debug symbols"
	@echo "  install - Install to /usr/local/bin"
	@echo "  help    - Show this help"
