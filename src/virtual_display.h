/**
 * @file src/virtual_display.h
 * @brief Declarations for on-demand virtual displays that match the streaming client.
 *
 * The session-facing functions in this file are platform neutral. A platform provides a
 * `virtual_display::backend_t` implementation through `make_platform_backend()`. Platforms
 * without an implementation return `nullptr`, which makes the feature report itself as
 * unavailable while Sunshine keeps streaming physical displays as before.
 */
#pragma once

// standard includes
#include <cstdint>
#include <memory>
#include <optional>
#include <string>
#include <string_view>

namespace virtual_display {
  /**
   * @brief A display mode in pixels and frames per second.
   */
  struct mode_t {
    int width;  ///< Framebuffer width in pixels.
    int height;  ///< Framebuffer height in pixels.
    int refresh_rate;  ///< Refresh rate in Hz.

    /**
     * @brief Compare two display modes.
     *
     * @param other Mode to compare against.
     * @return True when width, height and refresh rate are equal.
     */
    bool operator==(const mode_t &other) const = default;
  };

  /**
   * @brief The mode limits a virtual display backend accepts.
   */
  struct limits_t {
    int min_width;  ///< Smallest accepted framebuffer width in pixels.
    int min_height;  ///< Smallest accepted framebuffer height in pixels.
    int max_width;  ///< Largest accepted framebuffer width in pixels.
    int max_height;  ///< Largest accepted framebuffer height in pixels.
    int min_refresh_rate;  ///< Lowest accepted refresh rate in Hz.
    int max_refresh_rate;  ///< Highest accepted refresh rate in Hz.
  };

  /**
   * @brief Mode limits measured with the macOS CGVirtualDisplay API on Apple Silicon.
   */
  inline constexpr limits_t DEFAULT_LIMITS {640, 480, 8192, 4320, 24, 500};

  /**
   * @brief Mode used when the client did not request a usable mode.
   */
  inline constexpr mode_t DEFAULT_MODE {1920, 1080, 60};

  /**
   * @brief The EDID manufacturer code "LZB" (LizardByte) used for every virtual display.
   */
  inline constexpr std::uint32_t VENDOR_ID {0x3342};

  /**
   * @brief Display name used when the client did not provide a device name.
   */
  inline constexpr std::string_view DEFAULT_DISPLAY_NAME {"Sunshine Virtual Display"};

  /**
   * @brief Name of the built-in app entry that always streams a virtual display.
   */
  inline constexpr std::string_view APP_NAME {"Virtual Display"};

  /**
   * @brief Stable identity of a virtual display.
   *
   * macOS stores the mode, arrangement and mirroring of a display by its vendor, product and
   * serial numbers, and restores them whenever a display with the same numbers appears. The
   * product number identifies the client and the serial number also identifies the mode, so a
   * display never inherits a stored state that was saved for a different mode.
   */
  struct identity_t {
    std::uint32_t vendor_id;  ///< EDID vendor identifier.
    std::uint32_t product_id;  ///< EDID product identifier, never zero.
    std::uint32_t serial_number;  ///< EDID serial number, never zero.
    std::string name;  ///< Display name shown in the operating system settings.
  };

  /**
   * @brief Options that control how the virtual display is created.
   */
  struct options_t {
    bool hidpi;  ///< Create a 2x "Retina" display whose desktop is laid out at half the pixel size.
    bool make_main;  ///< Move the menu bar and Dock to the virtual display for the session.

    /**
     * @brief Compare two option sets.
     *
     * @param other Options to compare against.
     * @return True when all options are equal.
     */
    bool operator==(const options_t &other) const = default;
  };

  /**
   * @brief Inputs for deciding whether a session uses a virtual display.
   */
  struct decision_input_t {
    bool app_requests_virtual_display;  ///< The app has "Always use virtual display" enabled or is the built-in entry.
    bool headless_mode;  ///< The global headless mode option is enabled.
    bool physical_display_available;  ///< At least one usable physical display exists.
  };

  /**
   * @brief Reason a session uses or does not use a virtual display.
   */
  enum class decision_e {
    not_needed,  ///< Stream the physical display as upstream Sunshine does.
    app_option,  ///< The launched app asks for a virtual display.
    headless_mode,  ///< The global headless mode option is enabled.
    no_physical_display  ///< No usable physical display exists, so a virtual display is the automatic fallback.
  };

  /**
   * @brief Outcome of preparing a virtual display for a session.
   */
  enum class status_e {
    not_used,  ///< The session does not need a virtual display.
    active,  ///< A virtual display is active and is the capture target.
    fallback_physical,  ///< Creation failed, so the session streams a physical display.
    failed  ///< Creation failed and there is no physical display to fall back to.
  };

  /**
   * @brief A request to prepare a virtual display for a streaming session.
   */
  struct session_request_t {
    bool app_requests_virtual_display;  ///< The app has "Always use virtual display" enabled or is the built-in entry.
    bool headless_mode;  ///< The global headless mode option is enabled.
    options_t options;  ///< Creation options from the configuration.
    std::string client_id;  ///< Persistent client identifier used to derive the display identity.
    std::string client_name;  ///< Client device name used for the display name.
    mode_t mode;  ///< Mode requested by the client.
  };

  /**
   * @brief Platform implementation of a single virtual display.
   */
  class backend_t {
  public:
    virtual ~backend_t() = default;

    /**
     * @brief Report whether the platform can create virtual displays.
     *
     * @return True when the platform API exists on the running system.
     */
    [[nodiscard]] virtual bool is_available() const = 0;

    /**
     * @brief Report whether a usable physical display exists.
     *
     * The virtual display created by this backend is not counted.
     *
     * @return True when at least one physical display is online and active.
     */
    [[nodiscard]] virtual bool has_physical_display() const = 0;

    /**
     * @brief Create the virtual display and wait until it is online in the requested mode.
     *
     * @param identity Stable identity of the display.
     * @param mode Mode to create, already validated with `sanitize_mode()`.
     * @param options Creation options.
     * @return Capture selector of the created display, or an empty optional on failure.
     */
    [[nodiscard]] virtual std::optional<std::string> create(const identity_t &identity, const mode_t &mode, const options_t &options) = 0;

    /**
     * @brief Wake displays that sleep.
     *
     * While the displays sleep, the system neither draws nor removes displays, and a sleeping
     * physical display does not count as usable.
     */
    virtual void wake() = 0;

    /**
     * @brief Remove the virtual display and restore the display arrangement.
     */
    virtual void destroy() = 0;
  };

  /**
   * @brief Create the backend for the current platform.
   *
   * @return Platform backend, or `nullptr` when the platform has no implementation.
   */
  [[nodiscard]] std::unique_ptr<backend_t> make_platform_backend();

  /**
   * @brief Decide whether a session uses a virtual display.
   *
   * @param input Facts about the session and the host.
   * @return The reason a virtual display is used, or `decision_e::not_needed`.
   */
  [[nodiscard]] decision_e decide(const decision_input_t &input);

  /**
   * @brief Convert a decision to a human-readable string for logging.
   *
   * @param decision Decision to describe.
   * @return Short description of the decision.
   */
  [[nodiscard]] std::string_view to_string(decision_e decision);

  /**
   * @brief Derive the stable display identity of a client.
   *
   * @param client_id Persistent client identifier.
   * @param client_name Client device name; an empty name uses `DEFAULT_DISPLAY_NAME`.
   * @return Identity whose numbers depend only on `client_id`.
   */
  [[nodiscard]] identity_t derive_identity(std::string_view client_id, std::string_view client_name);

  /**
   * @brief Derive the identity of a client's display in a specific mode.
   *
   * The serial number also depends on the mode and options, so the state macOS stores for the
   * display always matches the mode it is created in. Reusing one identity for different modes
   * made macOS restore stale modes or mirroring, and could crash the window server.
   *
   * @param client Identity of the client from `derive_identity()`.
   * @param mode Mode the display is created in.
   * @param options Options the display is created with.
   * @return Identity with the client's vendor, product and name and a mode-specific serial number.
   */
  [[nodiscard]] identity_t identity_for_mode(const identity_t &client, const mode_t &mode, const options_t &options);

  /**
   * @brief Validate a requested mode and fall back to the nearest valid mode.
   *
   * Zero or negative values use `DEFAULT_MODE`, refresh rates in millihertz are converted to hertz,
   * and values outside the limits are scaled or clamped while keeping the aspect ratio where
   * possible. Dimensions are rounded down to even numbers, which 4:2:0 video encoding and the
   * HiDPI point layout both need.
   *
   * @param requested Mode requested by the client.
   * @param limits Limits of the backend.
   * @return Mode the backend can create.
   */
  [[nodiscard]] mode_t sanitize_mode(const mode_t &requested, const limits_t &limits = DEFAULT_LIMITS);

  /**
   * @brief Report whether a mode can be created as a 2x HiDPI display.
   *
   * macOS only offers 2x modes whose desktop is at least 800 points on the long side and more
   * than 500 points on the short side. Attempting HiDPI below that leaves macOS with a broken
   * stored state for the display identity, so smaller modes are created as 1x displays.
   *
   * @param mode Mode in pixels.
   * @return True when the mode is large enough for HiDPI.
   */
  [[nodiscard]] bool supports_hidpi(const mode_t &mode);

  /**
   * @brief Report whether virtual displays are supported on this host.
   *
   * @return True when the platform backend exists and its API is available.
   */
  [[nodiscard]] bool is_available();

  /**
   * @brief Prepare the virtual display for a session that is starting or resuming.
   *
   * Creates the display when the session needs one, creates it again when the requested mode or
   * options changed, and keeps an existing display unchanged otherwise.
   *
   * @param request Session request.
   * @return Outcome of the preparation.
   */
  [[nodiscard]] status_e prepare_session(const session_request_t &request);

  /**
   * @brief Remove the active virtual display, if any.
   */
  void end_session();

  /**
   * @brief Remove the active virtual display when it cannot be used and a physical display exists.
   *
   * Called when capture fails on the virtual display, so the session streams a physical display.
   *
   * @return True when the virtual display was removed and a physical display can be streamed.
   */
  [[nodiscard]] bool fall_back_to_physical();

  /**
   * @brief Report whether a virtual display is active.
   *
   * @return True when a virtual display exists.
   */
  [[nodiscard]] bool is_active();

  /**
   * @brief Get the capture selector of the active virtual display.
   *
   * @return Capture selector, or an empty string when no virtual display is active.
   */
  [[nodiscard]] std::string active_display_name();

  /**
   * @brief Create a short-lived virtual display so encoders can be probed on a headless host.
   *
   * Nothing is created when a physical display exists, because the probe then failed for another
   * reason, such as a missing screen recording permission.
   *
   * @return True when a probe display was created. Call `end_session()` after probing.
   */
  [[nodiscard]] bool create_probe_display();

  /**
   * @brief Replace the backend used by the session functions.
   *
   * Any active display of the previous backend is removed first. This is intended for tests.
   *
   * @param backend New backend, or `nullptr` to make the feature unavailable.
   */
  void set_backend(std::unique_ptr<backend_t> backend);
}  // namespace virtual_display
