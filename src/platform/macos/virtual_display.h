/**
 * @file src/platform/macos/virtual_display.h
 * @brief Declarations for the macOS virtual display helper process.
 */
#pragma once

// standard includes
#include <functional>
#include <string_view>

namespace virtual_display {
  /**
   * @brief Command-line argument that starts Sunshine as a virtual display helper.
   */
  inline constexpr std::string_view HELPER_ARGUMENT {"--virtual-display-helper"};

  /**
   * @brief Run the virtual display helper until its input is closed.
   *
   * macOS removes a virtual display, and reverts the display arrangement changes made for it,
   * only reliably when the process that owns the display exits. Sunshine therefore creates each
   * virtual display in a helper process that reads commands from standard input and writes
   * replies to standard output. The helper exits when Sunshine closes the pipe, including when
   * Sunshine crashes, so no display is left behind.
   *
   * @return Process exit code.
   */
  int run_helper();

  /**
   * @brief Process AppKit events on the main thread until a stop is requested.
   *
   * CoreGraphics in an AppKit process only learns about displays that other processes add,
   * remove or reconfigure, such as the displays of virtual display helpers, while the main thread
   * processes AppKit events. The system tray does this when it is enabled; otherwise Sunshine runs
   * this loop on the main thread.
   *
   * @param stop_requested Returns true when the loop should end.
   */
  void run_display_event_loop(const std::function<bool()> &stop_requested);
}  // namespace virtual_display
