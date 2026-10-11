/**
 * @file tests/tests_main.cpp
 * @brief Entry point definition.
 */

// test includes
#include "tests_common.h"
#include "tests_environment.h"
#include "tests_events.h"

#ifdef __APPLE__
  // local includes
  #include <src/platform/macos/virtual_display.h>
#endif

int main(int argc, char **argv) {
#ifdef __APPLE__
  // The real virtual display tests start this executable as the helper process that owns the display.
  if (argc > 1 && std::string_view {argv[1]} == virtual_display::HELPER_ARGUMENT) {
    return virtual_display::run_helper();
  }
#endif

  testing::InitGoogleTest(&argc, argv);
  testing::AddGlobalTestEnvironment(new SunshineEnvironment);
  testing::UnitTest::GetInstance()->listeners().Append(new SunshineEventListener);
  return RUN_ALL_TESTS();
}
