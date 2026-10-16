/**
 * @file tests/virtual_display_test_utils.h
 * @brief Fake virtual display backend shared by Sunshine tests.
 */
#pragma once

// standard includes
#include <memory>
#include <optional>
#include <string>
#include <utility>

// local includes
#include <src/virtual_display.h>

namespace test_utils::virtual_display {
  /**
   * @brief Calls recorded by the fake backend.
   */
  struct backend_log_t {
    int create_calls {};  ///< Number of create() calls.
    int wake_calls {};  ///< Number of wake() calls.
    int destroy_calls {};  ///< Number of destroy() calls.
    ::virtual_display::identity_t last_identity {};  ///< Identity passed to the last create() call.
    ::virtual_display::mode_t last_mode {};  ///< Mode passed to the last create() call.
    ::virtual_display::options_t last_options {};  ///< Options passed to the last create() call.
  };

  /**
   * @brief Backend that records calls and returns configurable results.
   */
  class fake_backend_t: public ::virtual_display::backend_t {
  public:
    /**
     * @brief Construct a fake backend.
     *
     * @param log Shared call log.
     */
    explicit fake_backend_t(std::shared_ptr<backend_log_t> log):
        log {std::move(log)} {
    }

    [[nodiscard]] bool is_available() const override {
      return available;
    }

    [[nodiscard]] bool has_physical_display() const override {
      return physical_display;
    }

    [[nodiscard]] std::optional<std::string> create(const ::virtual_display::identity_t &identity, const ::virtual_display::mode_t &mode, const ::virtual_display::options_t &options) override {
      ++log->create_calls;
      log->last_identity = identity;
      log->last_mode = mode;
      log->last_options = options;
      if (!create_succeeds) {
        return std::nullopt;
      }
      return std::to_string(next_display_id++);
    }

    void wake() override {
      ++log->wake_calls;
    }

    [[nodiscard]] bool is_intact() const override {
      return intact;
    }

    void destroy() override {
      ++log->destroy_calls;
    }

    bool available {true};  ///< Value returned by is_available().
    bool physical_display {true};  ///< Value returned by has_physical_display().
    bool create_succeeds {true};  ///< Whether create() succeeds.
    bool intact {true};  ///< Value returned by is_intact().

  private:
    std::shared_ptr<backend_log_t> log;  ///< Shared call log.
    int next_display_id {100};  ///< Display identifier returned by the next create() call.
  };

}  // namespace test_utils::virtual_display
