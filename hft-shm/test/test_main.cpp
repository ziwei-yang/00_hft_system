#include <iostream>
#include <cstdlib>

// Test function declarations
void run_types_tests();
void run_config_tests();
void run_platform_tests();
void run_integration_tests();
void run_layout_tests();

int main() {
    std::cout << "=================================\n";
    std::cout << "HFT Shared Memory Unit Tests\n";
    std::cout << "=================================\n\n";

    try {
        run_types_tests();
        run_layout_tests();
        run_config_tests();
        run_platform_tests();
        run_integration_tests();

        std::cout << "=================================\n";
        std::cout << "All tests passed!\n";
        std::cout << "=================================\n";
        return EXIT_SUCCESS;
    } catch (const std::exception& e) {
        std::cerr << "\nTest failed with exception: " << e.what() << "\n";
        return EXIT_FAILURE;
    }
}
