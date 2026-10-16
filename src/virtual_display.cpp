/**
 * @file src/virtual_display.cpp
 * @brief Definitions for on-demand virtual displays that match the streaming client.
 */
// header include
#include "virtual_display.h"

// standard includes
#include <algorithm>
#include <cstdlib>
#include <mutex>
#include <sstream>

// local includes
#include "logging.h"

namespace virtual_display {
  using namespace std::literals;

  namespace {
    /**
     * @brief Session state shared by the virtual display functions.
     */
    struct state_t {
      std::mutex mutex;  ///< Serializes access to the backend and the fields below.
      std::unique_ptr<backend_t> backend;  ///< Platform backend, created on first use.
      bool backend_initialized {false};  ///< Whether `backend` has been created or replaced.
      bool active {false};  ///< Whether a virtual display exists.
      std::string display_name;  ///< Capture selector of the active display.
      mode_t mode {};  ///< Mode of the active display.
      options_t options {};  ///< Options of the active display.
    };

    /**
     * @brief Get the shared session state.
     *
     * @return Session state singleton.
     */
    state_t &state() {
      static state_t instance;
      return instance;
    }

    /**
     * @brief Get the backend, creating the platform backend on first use.
     *
     * @param st Session state; its mutex must be held.
     * @return Backend, or `nullptr` when the platform has no implementation.
     */
    backend_t *backend_locked(state_t &st) {
      if (!st.backend_initialized) {
        st.backend = make_platform_backend();
        st.backend_initialized = true;
      }
      return st.backend.get();
    }

    /**
     * @brief Report whether the user forced the feature off through the environment.
     *
     * @return True when `SUNSHINE_DISABLE_VIRTUAL_DISPLAY` is set to a value other than `0`.
     */
    bool disabled_by_environment() {
      const auto *value = std::getenv("SUNSHINE_DISABLE_VIRTUAL_DISPLAY");  // NOSONAR(cpp:S5421): read-only lookup
      return value != nullptr && *value != '\0' && std::string_view {value} != "0"sv;
    }

    /**
     * @brief Report whether the backend can create virtual displays.
     *
     * @param backend Backend to check, may be `nullptr`.
     * @return True when the feature is usable.
     */
    bool available_locked(const backend_t *backend) {
      return backend != nullptr && !disabled_by_environment() && backend->is_available();
    }

    /**
     * @brief Hash a string with 64-bit FNV-1a.
     *
     * The result must be identical across runs, builds and platforms, so `std::hash` is not used.
     *
     * @param value Bytes to hash.
     * @return Hash of the bytes.
     */
    std::uint64_t fnv1a_64(std::string_view value) {
      std::uint64_t hash {0xcbf29ce484222325ULL};
      for (const auto byte : value) {
        hash ^= static_cast<std::uint8_t>(byte);
        hash *= 0x100000001b3ULL;
      }
      return hash;
    }

    /**
     * @brief Scale a dimension pair by a factor.
     *
     * @param mode Mode whose width and height are scaled in place.
     * @param factor Scale factor.
     */
    void scale_dimensions(mode_t &mode, double factor) {
      mode.width = static_cast<int>(static_cast<double>(mode.width) * factor);
      mode.height = static_cast<int>(static_cast<double>(mode.height) * factor);
    }

    /**
     * @brief Log the mode used for a virtual display and whether it differs from the request.
     *
     * @param requested Mode requested by the client.
     * @param used Mode that will be created.
     */
    void log_mode(const mode_t &requested, const mode_t &used) {
      if (requested == used) {
        return;
      }

      BOOST_LOG(warning) << "Virtual display mode "sv << requested.width << 'x' << requested.height << '@' << requested.refresh_rate
                         << " cannot be created exactly. Using "sv << used.width << 'x' << used.height << '@' << used.refresh_rate << " instead."sv;
    }
  }  // namespace

  decision_e decide(const decision_input_t &input) {
    if (input.app_requests_virtual_display) {
      return decision_e::app_option;
    }
    if (input.headless_mode) {
      return decision_e::headless_mode;
    }
    if (!input.physical_display_available) {
      return decision_e::no_physical_display;
    }
    return decision_e::not_needed;
  }

  std::string_view to_string(decision_e decision) {
    switch (decision) {
      case decision_e::app_option:
        return "the app requests a virtual display"sv;
      case decision_e::headless_mode:
        return "headless mode is enabled"sv;
      case decision_e::no_physical_display:
        return "no physical display is available"sv;
      case decision_e::not_needed:
        break;
    }
    return "a virtual display is not needed"sv;
  }

  identity_t derive_identity(std::string_view client_id, std::string_view client_name) {
    const auto hash {fnv1a_64(client_id)};

    identity_t identity {};
    identity.vendor_id = VENDOR_ID;
    // EDID product codes are 16 bits wide. Zero is avoided because some systems treat it as "unknown".
    identity.product_id = static_cast<std::uint32_t>(hash & 0xFFFFU);
    if (identity.product_id == 0) {
      identity.product_id = 1;
    }
    identity.serial_number = static_cast<std::uint32_t>(hash >> 32U);
    if (identity.serial_number == 0) {
      identity.serial_number = static_cast<std::uint32_t>(hash & 0xFFFFFFFFU) | 1U;
    }
    identity.name = client_name.empty() ? std::string {DEFAULT_DISPLAY_NAME} : std::string {client_name};
    return identity;
  }

  identity_t identity_for_mode(const identity_t &client, const mode_t &mode, const options_t &options) {
    std::ostringstream key;
    key << client.product_id << ':' << client.serial_number << ':' << mode.width << 'x' << mode.height << '@' << mode.refresh_rate
        << ':' << options.hidpi << ':' << options.make_main;
    const auto hash {fnv1a_64(key.str())};

    identity_t identity {client};
    identity.serial_number = static_cast<std::uint32_t>(hash >> 32U);
    if (identity.serial_number == 0) {
      identity.serial_number = static_cast<std::uint32_t>(hash & 0xFFFFFFFFU) | 1U;
    }
    return identity;
  }

  mode_t sanitize_mode(const mode_t &requested, const limits_t &limits) {
    mode_t mode {requested};

    if (mode.width <= 0 || mode.height <= 0) {
      mode.width = DEFAULT_MODE.width;
      mode.height = DEFAULT_MODE.height;
    }

    // Some clients report the refresh rate in millihertz.
    if (mode.refresh_rate >= 1000) {
      mode.refresh_rate = (mode.refresh_rate + 500) / 1000;
    }
    if (mode.refresh_rate <= 0) {
      mode.refresh_rate = DEFAULT_MODE.refresh_rate;
    }
    mode.refresh_rate = std::clamp(mode.refresh_rate, limits.min_refresh_rate, limits.max_refresh_rate);

    // Keep the aspect ratio when the mode is too large or too small.
    if (mode.width > limits.max_width || mode.height > limits.max_height) {
      scale_dimensions(mode, std::min(static_cast<double>(limits.max_width) / mode.width, static_cast<double>(limits.max_height) / mode.height));
    }
    if (mode.width < limits.min_width || mode.height < limits.min_height) {
      scale_dimensions(mode, std::max(static_cast<double>(limits.min_width) / mode.width, static_cast<double>(limits.min_height) / mode.height));
    }
    mode.width = std::clamp(mode.width, limits.min_width, limits.max_width);
    mode.height = std::clamp(mode.height, limits.min_height, limits.max_height);

    // 4:2:0 video encoding and the 2x HiDPI point layout both need even dimensions.
    mode.width &= ~1;
    mode.height &= ~1;

    return mode;
  }

  bool supports_hidpi(const mode_t &mode) {
    constexpr int min_long_side_points {800};
    constexpr int min_short_side_points {501};
    const auto long_side {std::max(mode.width, mode.height) / 2};
    const auto short_side {std::min(mode.width, mode.height) / 2};
    return long_side >= min_long_side_points && short_side >= min_short_side_points;
  }

  bool is_available() {
    auto &st {state()};
    std::scoped_lock lock {st.mutex};
    return available_locked(backend_locked(st));
  }

  status_e prepare_session(const session_request_t &request) {
    auto &st {state()};
    std::scoped_lock lock {st.mutex};
    auto *backend {backend_locked(st)};

    const bool available {available_locked(backend)};
    if (available) {
      // A sleeping physical display does not count as usable, and a display created while the
      // displays sleep cannot be captured.
      backend->wake();
    }
    const bool physical_display {backend == nullptr || backend->has_physical_display()};
    const auto decision {decide({request.app_requests_virtual_display, request.headless_mode, physical_display})};

    if (decision == decision_e::not_needed && !st.active) {
      return status_e::not_used;
    }

    if (!available) {
      if (physical_display) {
        BOOST_LOG(error) << "A virtual display was requested because "sv << to_string(decision)
                         << ", but virtual displays are not available on this system. Streaming a physical display instead."sv;
        return status_e::fallback_physical;
      }

      BOOST_LOG(error) << "No physical display is available and virtual displays are not available on this system."sv;
      return status_e::failed;
    }

    const auto mode {sanitize_mode(request.mode)};
    log_mode(request.mode, mode);

    auto options {request.options};
    if (options.hidpi && !supports_hidpi(mode)) {
      BOOST_LOG(info) << "HiDPI is not available for "sv << mode.width << 'x' << mode.height << ". Creating a 1x virtual display."sv;
      options.hidpi = false;
    }

    if (st.active) {
      if (mode == st.mode && options == st.options) {
        if (backend->ensure_intact()) {
          BOOST_LOG(info) << "Sharing the existing virtual display ["sv << st.display_name << ']';
          return status_e::active;
        }

        BOOST_LOG(warning) << "The virtual display ["sv << st.display_name << "] lost its mode or arrangement. Creating it again."sv;
      } else {
        // Each mode has its own identity, so a different mode needs a new display.
        BOOST_LOG(info) << "Replacing virtual display ["sv << st.display_name << "] for mode "sv
                        << mode.width << 'x' << mode.height << '@' << mode.refresh_rate << (options.hidpi ? " (HiDPI)"sv : ""sv);
      }
      backend->destroy();
      st.active = false;
      st.display_name.clear();
    } else {
      BOOST_LOG(info) << "Using a virtual display because "sv << to_string(decision);
    }

    const auto identity {identity_for_mode(derive_identity(request.client_id, request.client_name), mode, options)};
    BOOST_LOG(info) << "Creating virtual display ["sv << identity.name << "] "sv
                    << mode.width << 'x' << mode.height << '@' << mode.refresh_rate << (options.hidpi ? " (HiDPI)"sv : ""sv);

    auto name {backend->create(identity, mode, options)};
    if (!name) {
      if (physical_display) {
        BOOST_LOG(error) << "Unable to create a virtual display. Streaming a physical display instead."sv;
        return status_e::fallback_physical;
      }

      BOOST_LOG(error) << "Unable to create a virtual display and no physical display is available."sv;
      return status_e::failed;
    }

    BOOST_LOG(info) << "Virtual display ["sv << identity.name << "] is ready as display ["sv << *name << ']';
    st.active = true;
    st.display_name = std::move(*name);
    st.mode = mode;
    st.options = options;
    return status_e::active;
  }

  void end_session() {
    auto &st {state()};
    std::scoped_lock lock {st.mutex};
    if (!st.active) {
      return;
    }

    BOOST_LOG(info) << "Removing virtual display ["sv << st.display_name << ']';
    if (st.backend) {
      st.backend->destroy();
    }
    st.active = false;
    st.display_name.clear();
    st.mode = {};
    st.options = {};
  }

  bool fall_back_to_physical() {
    auto &st {state()};
    std::scoped_lock lock {st.mutex};
    if (!st.active || !st.backend || !st.backend->has_physical_display()) {
      return false;
    }

    BOOST_LOG(warning) << "The virtual display ["sv << st.display_name << "] cannot be captured. Streaming a physical display instead."sv;
    st.backend->destroy();
    st.active = false;
    st.display_name.clear();
    st.mode = {};
    st.options = {};
    return true;
  }

  bool is_active() {
    auto &st {state()};
    std::scoped_lock lock {st.mutex};
    return st.active;
  }

  std::string active_display_name() {
    auto &st {state()};
    std::scoped_lock lock {st.mutex};
    return st.active ? st.display_name : std::string {};
  }

  bool create_probe_display() {
    auto &st {state()};
    std::scoped_lock lock {st.mutex};
    auto *backend {backend_locked(st)};
    if (st.active || !available_locked(backend)) {
      return false;
    }

    // A failed probe on a host with a display has another cause, such as missing permissions.
    backend->wake();
    if (backend->has_physical_display()) {
      return false;
    }

    constexpr options_t probe_options {false, false};
    const auto identity {identity_for_mode(derive_identity("sunshine-encoder-probe"sv, "Sunshine Probe"sv), DEFAULT_MODE, probe_options)};
    auto name {backend->create(identity, DEFAULT_MODE, probe_options)};
    if (!name) {
      return false;
    }

    st.active = true;
    st.display_name = std::move(*name);
    st.mode = DEFAULT_MODE;
    st.options = probe_options;
    return true;
  }

  void set_backend(std::unique_ptr<backend_t> backend) {
    auto &st {state()};
    std::scoped_lock lock {st.mutex};
    if (st.active && st.backend) {
      st.backend->destroy();
    }
    st.backend = std::move(backend);
    st.backend_initialized = true;
    st.active = false;
    st.display_name.clear();
    st.mode = {};
    st.options = {};
  }

#ifndef __APPLE__
  std::unique_ptr<backend_t> make_platform_backend() {
    return nullptr;
  }
#endif
}  // namespace virtual_display
