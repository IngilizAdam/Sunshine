/**
 * @file src/platform/macos/virtual_display.mm
 * @brief Definitions for macOS virtual displays based on the private CGVirtualDisplay API.
 *
 * CGVirtualDisplay is part of CoreGraphics but has no public header. The classes are looked up
 * at runtime so a macOS release without them disables the feature instead of preventing launch.
 *
 * The window server only removes a virtual display that was made the main display reliably when
 * the process that owns it exits, and it then also reverts the application-only arrangement
 * changes of that process. Each display is therefore owned by a helper process, which is Sunshine
 * started with `HELPER_ARGUMENT`. Sunshine talks to the helper over a pipe and removes the display
 * by ending the helper. The helper exits when the pipe closes, so a crash of Sunshine also removes
 * the display and restores the arrangement.
 */
// header include
#include "virtual_display.h"

// platform includes
#import <AppKit/AppKit.h>
#import <CoreGraphics/CoreGraphics.h>
#include <fcntl.h>
#import <Foundation/Foundation.h>
#import <IOKit/pwr_mgt/IOPMLib.h>
#include <mach-o/dyld.h>
#include <poll.h>
#include <pthread.h>
#include <signal.h>
#include <spawn.h>
#include <sys/wait.h>
#include <unistd.h>

// standard includes
#include <algorithm>
#include <cerrno>
#include <chrono>
#include <climits>
#include <cmath>
#include <condition_variable>
#include <cstring>
#include <functional>
#include <iostream>
#include <limits>
#include <mutex>
#include <optional>
#include <sstream>
#include <string>
#include <thread>
#include <vector>

// local includes
#include "src/logging.h"
#include "src/virtual_display.h"

/**
 * @brief Environment of this process, passed to the helper process.
 */
extern char **environ;  // NOSONAR(cpp:S5421): POSIX process environment

/**
 * @brief Private descriptor that defines the identity and limits of a virtual display.
 */
@interface CGVirtualDisplayDescriptor: NSObject
/**
 * @brief Queue used for the termination handler.
 */
@property (retain, nonatomic) dispatch_queue_t queue;
/**
 * @brief Display name shown in System Settings.
 */
@property (retain, nonatomic) NSString *name;
/**
 * @brief Largest framebuffer height in pixels.
 */
@property (nonatomic) unsigned int maxPixelsHigh;
/**
 * @brief Largest framebuffer width in pixels.
 */
@property (nonatomic) unsigned int maxPixelsWide;
/**
 * @brief Physical size reported to the system.
 */
@property (nonatomic) CGSize sizeInMillimeters;
/**
 * @brief EDID serial number.
 */
@property (nonatomic) unsigned int serialNum;
/**
 * @brief EDID product identifier.
 */
@property (nonatomic) unsigned int productID;
/**
 * @brief EDID vendor identifier.
 */
@property (nonatomic) unsigned int vendorID;
@end

/**
 * @brief Private display mode of a virtual display.
 */
@interface CGVirtualDisplayMode: NSObject
/**
 * @brief Initialize a mode.
 *
 * @param width Width in points.
 * @param height Height in points.
 * @param refreshRate Refresh rate in Hz.
 * @return Initialized mode.
 */
- (instancetype)initWithWidth:(unsigned int)width height:(unsigned int)height refreshRate:(double)refreshRate;
@end

/**
 * @brief Private settings of a virtual display.
 */
@interface CGVirtualDisplaySettings: NSObject
/**
 * @brief Modes offered by the display.
 */
@property (retain, nonatomic) NSArray *modes;
/**
 * @brief Whether the display is a 2x HiDPI display.
 */
@property (nonatomic) unsigned int hiDPI;
@end

/**
 * @brief Private virtual display object; the display exists while this object is alive.
 */
@interface CGVirtualDisplay: NSObject
/**
 * @brief CoreGraphics identifier of the display.
 */
@property (readonly, nonatomic) CGDirectDisplayID displayID;
/**
 * @brief Create the display.
 *
 * @param descriptor Descriptor of the display.
 * @return Initialized display, or nil on failure.
 */
- (instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
/**
 * @brief Apply settings to the display.
 *
 * @param settings Settings to apply.
 * @return YES on success.
 */
- (BOOL)applySettings:(CGVirtualDisplaySettings *)settings;
@end

namespace virtual_display {
  using namespace std::literals;

  namespace {
    constexpr auto ONLINE_TIMEOUT {10s};  ///< Time allowed for a new display to come online; large modes can take several seconds.
    constexpr auto HIDPI_ONLINE_TIMEOUT {3s};  ///< Time allowed for a HiDPI display to come online before falling back to 1x.
    constexpr auto MODE_TIMEOUT {3s};  ///< Time allowed for a mode change to take effect.
    constexpr auto REPLY_TIMEOUT {30s};  ///< Time allowed for the helper to answer a command.
    constexpr auto EXIT_TIMEOUT {3s};  ///< Time allowed for the helper to exit before it is killed.
    constexpr auto POLL_INTERVAL {50ms};  ///< Interval between display state checks.
    constexpr auto SETTLE_DELAY {500ms};  ///< Time for the window server to finish adding, changing or removing a display.
    constexpr auto WAKE_TIMEOUT {5s};  ///< Time allowed for sleeping displays to wake.
    constexpr auto MONITOR_INTERVAL {1s};  ///< Interval at which Sunshine checks that macOS kept the display's mode and arrangement.
    constexpr double MAX_DIAGONAL_INCHES {24.0};  ///< macOS keeps very large panels offline, so the reported size is capped.

    /**
     * @brief Callback used by the helper to report messages to Sunshine.
     */
    using report_t = std::function<void(std::string_view level, const std::string &message)>;

    /**
     * @brief Get the list of online displays.
     *
     * @return Online display identifiers.
     */
    std::vector<CGDirectDisplayID> online_displays() {
      std::uint32_t count {};
      if (CGGetOnlineDisplayList(0, nullptr, &count) != kCGErrorSuccess || count == 0) {
        return {};
      }

      std::vector<CGDirectDisplayID> displays(count);
      if (CGGetOnlineDisplayList(count, displays.data(), &count) != kCGErrorSuccess) {
        return {};
      }
      displays.resize(count);
      return displays;
    }

    /**
     * @brief Report whether a display is online.
     *
     * @param id Display to check.
     * @return True when the display is in the online display list.
     */
    bool is_online(CGDirectDisplayID id) {
      if (id == kCGNullDirectDisplay) {
        return false;
      }
      const auto displays {online_displays()};
      return std::ranges::find(displays, id) != displays.end();
    }

    /**
     * @brief Report whether a display currently uses a mode.
     *
     * @param display_id Display to check.
     * @param width Expected framebuffer width in pixels.
     * @param height Expected framebuffer height in pixels.
     * @return True when the current mode has the expected pixel size.
     */
    bool has_pixel_size(CGDirectDisplayID display_id, int width, int height) {
      const auto mode {CGDisplayCopyDisplayMode(display_id)};
      if (!mode) {
        return false;
      }

      const bool matches {static_cast<int>(CGDisplayModeGetPixelWidth(mode)) == width && static_cast<int>(CGDisplayModeGetPixelHeight(mode)) == height};
      CGDisplayModeRelease(mode);
      return matches;
    }

    bool is_helper_process {false};  ///< Whether this process is a virtual display helper, which does not use AppKit.

    /**
     * @brief Process AppKit events on the main thread for a short time.
     *
     * In an AppKit process, CoreGraphics only learns about displays that other processes add,
     * remove or reconfigure while the main thread processes AppKit events. Without this, the
     * display list, modes and bounds of a virtual display owned by the helper stay stale.
     *
     * @param duration Maximum time to wait for an event.
     */
    void process_display_events(std::chrono::milliseconds duration) {
      @autoreleasepool {
        NSApplication *application {[NSApplication sharedApplication]};
        NSEvent *event {[application nextEventMatchingMask:NSEventMaskAny
                                                 untilDate:[NSDate dateWithTimeIntervalSinceNow:std::chrono::duration<double>(duration).count()]
                                                    inMode:NSDefaultRunLoopMode
                                                   dequeue:YES]};
        if (event) {
          [application sendEvent:event];
        }
      }
    }

    /**
     * @brief Wait until a condition is true or a timeout expires.
     *
     * @param timeout Maximum time to wait.
     * @param condition Condition to poll.
     * @return True when the condition became true.
     */
    template<class F>
    bool wait_for(std::chrono::milliseconds timeout, F &&condition) {
      const auto deadline {std::chrono::steady_clock::now() + timeout};
      while (!condition()) {
        if (std::chrono::steady_clock::now() >= deadline) {
          return false;
        }
        if (pthread_main_np() != 0 && !is_helper_process) {
          process_display_events(POLL_INTERVAL);
        } else {
          std::this_thread::sleep_for(POLL_INTERVAL);
        }
      }
      return true;
    }

    /**
     * @brief Report whether a display mode is a 2x HiDPI mode.
     *
     * @param mode Mode to check.
     * @return True when the pixel width is at least 1.5 times the point width.
     */
    bool is_hidpi_mode(CGDisplayModeRef mode) {
      const auto point_width {CGDisplayModeGetWidth(mode)};
      return point_width > 0 && static_cast<double>(CGDisplayModeGetPixelWidth(mode)) / static_cast<double>(point_width) > 1.5;
    }

    /**
     * @brief Score how far a display mode is from the requested mode.
     *
     * @param mode Candidate display mode.
     * @param requested Requested mode in pixels.
     * @param hidpi Whether a 2x mode is wanted.
     * @return Lower is better; zero is an exact match.
     */
    double mode_distance(CGDisplayModeRef mode, const mode_t &requested, bool hidpi) {
      const auto pixel_width {static_cast<double>(CGDisplayModeGetPixelWidth(mode))};
      const auto pixel_height {static_cast<double>(CGDisplayModeGetPixelHeight(mode))};

      double distance {(std::abs(pixel_width - requested.width) + std::abs(pixel_height - requested.height)) * 1000.0};
      distance += std::abs(CGDisplayModeGetRefreshRate(mode) - requested.refresh_rate);
      if (is_hidpi_mode(mode) != hidpi) {
        distance += 1.0;
      }
      return distance;
    }

    /**
     * @brief Find the display mode closest to the requested mode.
     *
     * @param display_id Display whose modes are searched.
     * @param requested Requested mode in pixels.
     * @param hidpi Whether a 2x mode is wanted.
     * @return Retained closest mode, or `nullptr` when the display has no modes.
     */
    CGDisplayModeRef copy_closest_mode(CGDirectDisplayID display_id, const mode_t &requested, bool hidpi) {
      NSDictionary *options {
        @{(NSString *) kCGDisplayShowDuplicateLowResolutionModes: @YES}
      };
      const auto modes {CGDisplayCopyAllDisplayModes(display_id, (CFDictionaryRef) options)};
      if (!modes) {
        return nullptr;
      }

      CGDisplayModeRef best {nullptr};
      double best_distance {std::numeric_limits<double>::max()};
      for (CFIndex index = 0; index < CFArrayGetCount(modes); ++index) {
        const auto mode {(CGDisplayModeRef) CFArrayGetValueAtIndex(modes, index)};
        if (const auto distance {mode_distance(mode, requested, hidpi)}; distance < best_distance) {
          best = mode;
          best_distance = distance;
        }
      }

      if (best) {
        CGDisplayModeRetain(best);
      }
      CFRelease(modes);
      return best;
    }

    /**
     * @brief Make a display the main display while keeping the relative arrangement.
     *
     * The main display is the one at origin (0,0), so every display is moved by the same offset.
     * The change uses the application-only scope, which macOS reverts when the helper exits.
     *
     * @param display_id Display to make the main display.
     * @return True when the configuration was applied.
     */
    bool make_main_display(CGDirectDisplayID display_id) {
      const auto origin {CGDisplayBounds(display_id).origin};
      if (origin.x == 0 && origin.y == 0) {
        return true;
      }

      CGDisplayConfigRef config {};
      if (CGBeginDisplayConfiguration(&config) != kCGErrorSuccess) {
        return false;
      }

      for (const auto display : online_displays()) {
        if (CGDisplayIsInMirrorSet(display) && CGDisplayMirrorsDisplay(display) != kCGNullDirectDisplay) {
          continue;
        }

        const auto bounds {CGDisplayBounds(display)};
        CGConfigureDisplayOrigin(config, display, static_cast<int32_t>(bounds.origin.x - origin.x), static_cast<int32_t>(bounds.origin.y - origin.y));
      }

      return CGCompleteDisplayConfiguration(config, kCGConfigureForAppOnly) == kCGErrorSuccess;
    }

    /**
     * @brief Take a display out of a mirror set.
     *
     * macOS restores the mirroring it stored for a display identity. A mirrored virtual display
     * shows another display's desktop and only offers that display's modes.
     *
     * @param display_id Display to take out of its mirror set.
     * @return True when the display does not mirror another display afterwards.
     */
    bool leave_mirror_set(CGDirectDisplayID display_id) {
      if (!CGDisplayIsInMirrorSet(display_id)) {
        return true;
      }

      CGDisplayConfigRef config {};
      if (CGBeginDisplayConfiguration(&config) != kCGErrorSuccess) {
        return false;
      }
      CGConfigureDisplayMirrorOfDisplay(config, display_id, kCGNullDirectDisplay);
      if (CGCompleteDisplayConfiguration(config, kCGConfigureForAppOnly) != kCGErrorSuccess) {
        return false;
      }

      return wait_for(MODE_TIMEOUT, [display_id]() {
        return !CGDisplayIsInMirrorSet(display_id);
      });
    }

    /**
     * @brief Report whether an online display sleeps.
     *
     * @return True when at least one online display is asleep.
     */
    bool any_display_asleep() {
      return std::ranges::any_of(online_displays(), [](const auto display) {
        return CGDisplayIsAsleep(display) != 0;
      });
    }

    /**
     * @brief Compute a physical size macOS accepts for a mode.
     *
     * macOS keeps displays with very large reported panels offline, so the diagonal is capped.
     *
     * @param mode Mode in pixels.
     * @param hidpi Whether the display is a 2x HiDPI display.
     * @return Physical size in millimetres.
     */
    CGSize physical_size(const mode_t &mode, bool hidpi) {
      const double diagonal_pixels {std::hypot(static_cast<double>(mode.width), static_cast<double>(mode.height))};
      const double dpi {std::max(hidpi ? 220.0 : 110.0, diagonal_pixels / MAX_DIAGONAL_INCHES)};
      return CGSizeMake(25.4 * mode.width / dpi, 25.4 * mode.height / dpi);
    }

    /**
     * @brief Report whether the CGVirtualDisplay API exists on the running system.
     *
     * @return True when all private classes and selectors are present.
     */
    bool api_available() {
      const Class display_class {NSClassFromString(@"CGVirtualDisplay")};
      return NSClassFromString(@"CGVirtualDisplayDescriptor") && NSClassFromString(@"CGVirtualDisplaySettings") &&
             NSClassFromString(@"CGVirtualDisplayMode") && display_class &&
             [display_class instancesRespondToSelector:@selector(initWithDescriptor:)] &&
             [display_class instancesRespondToSelector:@selector(applySettings:)] &&
             [display_class instancesRespondToSelector:@selector(displayID)];
    }

    /**
     * @brief Owner of a CGVirtualDisplay; runs inside the helper process.
     */
    class display_owner_t {
    public:
      /**
       * @brief Construct an owner.
       *
       * @param report Callback for messages that Sunshine should log.
       */
      explicit display_owner_t(report_t report):
          report {std::move(report)} {
      }

      ~display_owner_t() {
        [display release];
      }

      display_owner_t(const display_owner_t &) = delete;
      display_owner_t &operator=(const display_owner_t &) = delete;

      /**
       * @brief Create the display and wait until it is online in the requested mode.
       *
       * @param identity Stable identity of the display.
       * @param mode Mode in pixels.
       * @param options Creation options.
       * @return Display identifier, or `kCGNullDirectDisplay` on failure.
       */
      CGDirectDisplayID create(const identity_t &identity, const mode_t &mode, const options_t &options) {
        if (display || !api_available()) {
          return kCGNullDirectDisplay;
        }

        @autoreleasepool {
          auto *descriptor {(CGVirtualDisplayDescriptor *) [[NSClassFromString(@"CGVirtualDisplayDescriptor") alloc] init]};
          descriptor.queue = dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0);
          descriptor.name = [NSString stringWithUTF8String:identity.name.c_str()] ?: @"Sunshine Virtual Display";
          descriptor.maxPixelsWide = static_cast<unsigned int>(mode.width);
          descriptor.maxPixelsHigh = static_cast<unsigned int>(mode.height);
          descriptor.sizeInMillimeters = physical_size(mode, options.hidpi);
          descriptor.vendorID = identity.vendor_id;
          descriptor.productID = identity.product_id;
          descriptor.serialNum = identity.serial_number;

          display = (CGVirtualDisplay *) [[NSClassFromString(@"CGVirtualDisplay") alloc] initWithDescriptor:descriptor];
          [descriptor release];
        }

        if (!display || display.displayID == kCGNullDirectDisplay) {
          report("error"sv, "CGVirtualDisplay could not create a display");
          return kCGNullDirectDisplay;
        }

        return apply_mode(mode, options) ? display.displayID : kCGNullDirectDisplay;
      }

      /**
       * @brief Apply the display's mode and arrangement again.
       *
       * macOS rearranges the displays from its stored configuration when another display is
       * added or removed, such as a TV that leaves and returns from standby. That replaces the
       * application-only configuration of this helper, but CoreGraphics in this process keeps
       * reporting the helper's own configuration, so the change can only be seen from another
       * process. Everything is therefore submitted again, even when it looks unchanged here.
       *
       * @return Display identifier, or `kCGNullDirectDisplay` on failure.
       */
      CGDirectDisplayID reapply() {
        if (!display || !applied) {
          return kCGNullDirectDisplay;
        }

        const auto id {display.displayID};
        const auto mode {copy_closest_mode(id, applied_mode, applied_hidpi)};
        CGDisplayConfigRef config {};
        if (!mode || CGBeginDisplayConfiguration(&config) != kCGErrorSuccess) {
          if (mode) {
            CGDisplayModeRelease(mode);
          }
          return kCGNullDirectDisplay;
        }

        CGConfigureDisplayWithDisplayMode(config, id, mode, nullptr);
        CGDisplayModeRelease(mode);
        CGConfigureDisplayMirrorOfDisplay(config, id, kCGNullDirectDisplay);
        if (applied_make_main) {
          // This process still sees the arrangement it configured, so it is submitted as it is.
          for (const auto other : online_displays()) {
            if (other != id && CGDisplayIsInMirrorSet(other) && CGDisplayMirrorsDisplay(other) != kCGNullDirectDisplay) {
              continue;
            }
            const auto origin {CGDisplayBounds(other).origin};
            CGConfigureDisplayOrigin(config, other, static_cast<int32_t>(origin.x), static_cast<int32_t>(origin.y));
          }
        }

        if (CGCompleteDisplayConfiguration(config, kCGConfigureForAppOnly) != kCGErrorSuccess) {
          report("warning"sv, "Unable to restore the virtual display");
          return kCGNullDirectDisplay;
        }
        return id;
      }

    private:
      /**
       * @brief Offer a single mode to the display.
       *
       * @param mode Mode in pixels.
       * @param hidpi Whether to offer the mode as a 2x HiDPI mode.
       * @return True when the settings were accepted.
       */
      bool apply_settings(const mode_t &mode, bool hidpi) {
        @autoreleasepool {
          const auto scale {hidpi ? 2 : 1};
          auto *display_mode {(CGVirtualDisplayMode *) [[NSClassFromString(@"CGVirtualDisplayMode") alloc] initWithWidth:static_cast<unsigned int>(mode.width / scale)
                                                                                                                  height:static_cast<unsigned int>(mode.height / scale)
                                                                                                             refreshRate:static_cast<double>(mode.refresh_rate)]};
          auto *settings {(CGVirtualDisplaySettings *) [[NSClassFromString(@"CGVirtualDisplaySettings") alloc] init]};
          settings.hiDPI = hidpi ? 1 : 0;
          settings.modes = @[display_mode];
          const bool applied {[display applySettings:settings] == YES};
          [settings release];
          [display_mode release];
          return applied;
        }
      }

      /**
       * @brief Select the display mode closest to the requested mode.
       *
       * @param mode Mode in pixels.
       * @param hidpi Whether a 2x mode is wanted.
       * @return True when the current mode has the requested pixel size and scale.
       */
      bool select_mode(const mode_t &mode, bool hidpi) {
        const auto id {display.displayID};
        const auto closest {copy_closest_mode(id, mode, hidpi)};
        if (!closest) {
          return false;
        }

        const auto pixel_width {static_cast<int>(CGDisplayModeGetPixelWidth(closest))};
        const auto pixel_height {static_cast<int>(CGDisplayModeGetPixelHeight(closest))};
        const bool exact {pixel_width == mode.width && pixel_height == mode.height && is_hidpi_mode(closest) == hidpi};

        // macOS may pick a default mode for a new display, so the closest mode is selected explicitly.
        CGDisplayConfigRef config {};
        if (CGBeginDisplayConfiguration(&config) == kCGErrorSuccess) {
          CGConfigureDisplayWithDisplayMode(config, id, closest, nullptr);
          if (CGCompleteDisplayConfiguration(config, kCGConfigureForAppOnly) != kCGErrorSuccess) {
            report("warning"sv, "Unable to select the virtual display mode");
          }
        }

        if (!exact) {
          std::ostringstream message;
          message << "Virtual display mode " << mode.width << 'x' << mode.height << '@' << mode.refresh_rate << (hidpi ? " (HiDPI)" : "")
                  << " is not offered by macOS. Using " << pixel_width << 'x' << pixel_height << '@' << CGDisplayModeGetRefreshRate(closest)
                  << (is_hidpi_mode(closest) ? " (HiDPI)" : "") << " instead.";
          report("warning"sv, message.str());
        }
        CGDisplayModeRelease(closest);

        wait_for(MODE_TIMEOUT, [id, pixel_width, pixel_height]() {
          return has_pixel_size(id, pixel_width, pixel_height);
        });
        return exact;
      }

      /**
       * @brief Apply a mode, wait for the display to come online and arrange it.
       *
       * @param mode Mode in pixels.
       * @param options Creation options.
       * @return True when the display is online.
       */
      bool apply_mode(const mode_t &mode, const options_t &options) {
        const auto id {display.displayID};
        const auto online {[id]() {
          return is_online(id);
        }};

        if (!apply_settings(mode, options.hidpi)) {
          report("error"sv, "CGVirtualDisplay rejected the display settings");
          return false;
        }

        // macOS only offers 2x modes above a minimum size; smaller HiDPI displays never come
        // online or get a 1x mode. Fall back to a 1x display with the same pixel size so the
        // captured frame still matches the client.
        bool hidpi {options.hidpi};
        const auto fall_back_to_1x {[&]() {
          std::ostringstream message;
          message << "HiDPI is not available for " << mode.width << 'x' << mode.height << ". Creating a 1x display instead.";
          report("warning"sv, message.str());
          hidpi = false;
          if (!apply_settings(mode, false) || !wait_for(ONLINE_TIMEOUT, online)) {
            return false;
          }

          // The new mode list arrives after the display is online again, so wait for the 1x mode.
          wait_for(MODE_TIMEOUT, [id, &mode]() {
            const auto closest {copy_closest_mode(id, mode, false)};
            if (!closest) {
              return false;
            }
            const bool offered {static_cast<int>(CGDisplayModeGetPixelWidth(closest)) == mode.width && static_cast<int>(CGDisplayModeGetPixelHeight(closest)) == mode.height};
            CGDisplayModeRelease(closest);
            return offered;
          });
          return true;
        }};

        if (!wait_for(hidpi ? HIDPI_ONLINE_TIMEOUT : ONLINE_TIMEOUT, online) && (!hidpi || !fall_back_to_1x())) {
          report("error"sv, "The virtual display did not come online");
          return false;
        }

        if (CGDisplayIsInMirrorSet(id)) {
          report("warning"sv, "macOS restored the virtual display as a mirror. Turning mirroring off.");
          if (!leave_mirror_set(id)) {
            report("error"sv, "Unable to turn mirroring off for the virtual display");
            return false;
          }
        }

        if (!select_mode(mode, hidpi) && hidpi && fall_back_to_1x()) {
          select_mode(mode, false);
        }

        // Remember the mode the display ended up with, so restore() never chases a mode that
        // macOS does not offer exactly.
        {
          applied = true;
          applied_mode = mode;
          applied_hidpi = hidpi;
          if (const auto current {CGDisplayCopyDisplayMode(id)}) {
            applied_mode.width = static_cast<int>(CGDisplayModeGetPixelWidth(current));
            applied_mode.height = static_cast<int>(CGDisplayModeGetPixelHeight(current));
            applied_hidpi = is_hidpi_mode(current);
            CGDisplayModeRelease(current);
          }
          applied_make_main = options.make_main;
        }

        if (options.make_main) {
          if (make_main_display(id)) {
            // Wait for the window server to move the menu bar before capture starts.
            wait_for(MODE_TIMEOUT, [id]() {
              return CGDisplayIsMain(id);
            });
          } else {
            report("warning"sv, "Unable to make the virtual display the main display");
          }
        }

        return is_online(id);
      }

      report_t report;  ///< Callback for messages that Sunshine should log.
      CGVirtualDisplay *display {nil};  ///< The display; it exists while this object is alive.
      bool applied {false};  ///< Whether the display was configured and should be kept that way.
      mode_t applied_mode {};  ///< Mode the display was configured with.
      bool applied_hidpi {false};  ///< Whether the configured mode is a 2x HiDPI mode.
      bool applied_make_main {false};  ///< Whether the display was made the main display.
    };

    /**
     * @brief Remove characters that would break the line-based helper protocol.
     *
     * @param text Text to clean.
     * @return Text without line breaks.
     */
    std::string single_line(std::string text) {
      std::ranges::replace(text, '\n', ' ');
      std::ranges::replace(text, '\r', ' ');
      return text;
    }

    /**
     * @brief Write a line to a file descriptor.
     *
     * @param fd File descriptor.
     * @param line Line without a trailing newline.
     * @return True when the whole line was written.
     */
    bool write_line(int fd, const std::string &line) {
      const auto data {line + '\n'};
      std::size_t written {};
      while (written < data.size()) {
        const auto result {::write(fd, data.data() + written, data.size() - written)};
        if (result < 0 && errno == EINTR) {
          continue;
        }
        if (result <= 0) {
          return false;
        }
        written += static_cast<std::size_t>(result);
      }
      return true;
    }

    /**
     * @brief Virtual display backend that owns each display through a helper process.
     */
    class macos_backend_t: public backend_t {
    public:
      macos_backend_t() = default;

      ~macos_backend_t() override {
        destroy();
      }

      macos_backend_t(const macos_backend_t &) = delete;
      macos_backend_t &operator=(const macos_backend_t &) = delete;

      [[nodiscard]] bool is_available() const override {
        return api_available();
      }

      [[nodiscard]] bool has_physical_display() const override {
        for (const auto display : online_displays()) {
          if (display != display_id && CGDisplayIsActive(display)) {
            return true;
          }
        }
        return false;
      }

      void wake() override {
        static_cast<void>(wake_displays());
      }

      [[nodiscard]] bool ensure_intact() override {
        std::scoped_lock lock {helper_mutex};
        if (helper_pid <= 0 || waitpid(helper_pid, nullptr, WNOHANG) != 0) {
          return false;
        }
        return is_intact_locked() || restore_locked();
      }

      [[nodiscard]] std::optional<std::string> create(const identity_t &identity, const mode_t &mode, const options_t &options) override {
        destroy();
        static_cast<void>(wake_displays());

        std::unique_lock lock {helper_mutex};
        if (!spawn_helper()) {
          return std::nullopt;
        }

        std::ostringstream command;
        command << "create " << identity.vendor_id << ' ' << identity.product_id << ' ' << identity.serial_number << ' '
                << mode.width << ' ' << mode.height << ' ' << mode.refresh_rate << ' ' << options.hidpi << ' ' << options.make_main << ' '
                << single_line(identity.name);
        if (!send_command(command.str()) || !wait_until_usable()) {
          lock.unlock();
          destroy();
          return std::nullopt;
        }
        made_main = options.make_main;
        start_monitor();
        return std::to_string(display_id);
      }

      void destroy() override {
        stop_monitor();

        std::scoped_lock lock {helper_mutex};
        if (helper_pid <= 0) {
          return;
        }

        // The window server only removes the display and reverts the arrangement while the displays are awake.
        static_cast<void>(wake_displays());
        write_line(to_helper, "quit");
        close_pipes();
        wait_for_helper_exit();

        // macOS removes the display and reverts the helper's arrangement changes when it exits.
        // Wait for both, so a display created right afterwards does not race the revert.
        const auto id {display_id};
        if (!wait_for(ONLINE_TIMEOUT, [id]() {
              return !is_online(id) && CGMainDisplayID() != id;
            })) {
          BOOST_LOG(warning) << "The virtual display is still online after the helper exited"sv;
        }
        std::this_thread::sleep_for(SETTLE_DELAY);
        display_id = kCGNullDirectDisplay;
      }

    private:
      /**
       * @brief Report whether the display still has its mode and arrangement.
       *
       * Only Sunshine can see this: CoreGraphics in the helper keeps reporting the helper's own
       * configuration after macOS replaced it. The helper mutex must be held.
       *
       * @return True when the display is online, unmirrored, in its mode and main when it should be.
       */
      [[nodiscard]] bool is_intact_locked() const {
        return is_online(display_id) && !CGDisplayIsInMirrorSet(display_id) && has_pixel_size(display_id, pixel_width, pixel_height) &&
               (!made_main || CGDisplayIsMain(display_id));
      }

      /**
       * @brief Ask the helper to apply the mode and arrangement again and wait until they are back.
       *
       * The helper mutex must be held.
       *
       * @return True when the display is intact afterwards.
       */
      bool restore_locked() {
        BOOST_LOG(warning) << "macOS changed the virtual display ["sv << display_id << "]. Restoring its mode and arrangement."sv;
        const auto width {pixel_width};
        const auto height {pixel_height};
        if (!send_command("restore")) {
          return false;
        }
        pixel_width = width;
        pixel_height = height;
        if (!wait_for(MODE_TIMEOUT, [this]() {
              return is_intact_locked();
            })) {
          BOOST_LOG(warning) << "Unable to restore the virtual display ["sv << display_id << ']';
          return false;
        }
        return true;
      }

      /**
       * @brief Start checking the display once per second for changes made by macOS.
       *
       * macOS rearranges the displays from its stored configuration when another display is added
       * or removed, such as a TV that leaves and returns from standby, which resets the virtual
       * display to a default mode and can make another display the main display. A change must be
       * seen twice in a row, so a reconfiguration that is still in progress is not interrupted.
       */
      void start_monitor() {
        {
          std::scoped_lock lock {monitor_mutex};
          stop_monitoring = false;
        }
        monitor = std::thread([this]() {
          int changed_checks {0};
          std::unique_lock lock {monitor_mutex};
          while (!monitor_stopped.wait_for(lock, MONITOR_INTERVAL, [this]() {
            return stop_monitoring;
          })) {
            lock.unlock();
            {
              std::scoped_lock helper_lock {helper_mutex};
              if (helper_pid > 0 && !is_intact_locked()) {
                if (++changed_checks >= 2) {
                  changed_checks = 0;
                  static_cast<void>(restore_locked());
                }
              } else {
                changed_checks = 0;
              }
            }
            lock.lock();
          }
        });
      }

      /**
       * @brief Stop the thread started by `start_monitor()`.
       */
      void stop_monitor() {
        {
          std::scoped_lock lock {monitor_mutex};
          stop_monitoring = true;
        }
        monitor_stopped.notify_all();
        if (monitor.joinable()) {
          monitor.join();
        }
      }

      /**
       * @brief Wait until Sunshine sees the helper's display online with a current mode.
       *
       * @return True when the display can be captured.
       */
      [[nodiscard]] bool wait_until_usable() const {
        const auto id {display_id};
        const auto width {pixel_width};
        const auto height {pixel_height};
        if (wait_for(ONLINE_TIMEOUT, [id, width, height]() {
              return is_online(id) && has_pixel_size(id, width, height);
            })) {
          // Screen capture fails if it starts while the window server is still adding the display.
          std::this_thread::sleep_for(SETTLE_DELAY);
          return true;
        }

        // The helper reported the display ready; capture still works if only the mode report lags.
        if (const auto mode {CGDisplayCopyDisplayMode(id)}) {
          CGDisplayModeRelease(mode);
          BOOST_LOG(warning) << "Sunshine does not see the virtual display ["sv << id << "] in its "sv << width << 'x' << height << " mode yet"sv;
          return true;
        }

        BOOST_LOG(error) << "The virtual display ["sv << id << "] is not visible to Sunshine"sv;
        return false;
      }

      /**
       * @brief Start the helper process with pipes for its standard input and output.
       *
       * @return True when the helper was started.
       */
      bool spawn_helper() {
        char executable[PATH_MAX];
        std::uint32_t size {sizeof(executable)};
        if (_NSGetExecutablePath(executable, &size) != 0) {
          BOOST_LOG(error) << "Unable to find the Sunshine executable for the virtual display helper"sv;
          return false;
        }

        int input[2] {-1, -1};
        int output[2] {-1, -1};
        if (pipe(input) != 0 || pipe(output) != 0) {
          BOOST_LOG(error) << "Unable to create pipes for the virtual display helper: "sv << std::strerror(errno);
          for (const auto fd : {input[0], input[1], output[0], output[1]}) {
            if (fd >= 0) {
              ::close(fd);
            }
          }
          return false;
        }

        posix_spawn_file_actions_t actions;
        posix_spawn_file_actions_init(&actions);
        posix_spawn_file_actions_adddup2(&actions, input[0], STDIN_FILENO);
        posix_spawn_file_actions_adddup2(&actions, output[1], STDOUT_FILENO);
        posix_spawn_file_actions_addinherit_np(&actions, STDERR_FILENO);

        posix_spawnattr_t attributes;
        posix_spawnattr_init(&attributes);
        // Only the three standard descriptors are inherited, so the helper holds no sockets or files of Sunshine.
        posix_spawnattr_setflags(&attributes, POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF);
        sigset_t default_signals;
        sigfillset(&default_signals);
        posix_spawnattr_setsigdefault(&attributes, &default_signals);

        std::string argument {HELPER_ARGUMENT};
        char *arguments[] {executable, argument.data(), nullptr};
        const auto result {posix_spawn(&helper_pid, executable, &actions, &attributes, arguments, environ)};
        posix_spawn_file_actions_destroy(&actions);
        posix_spawnattr_destroy(&attributes);
        ::close(input[0]);
        ::close(output[1]);

        if (result != 0) {
          BOOST_LOG(error) << "Unable to start the virtual display helper: "sv << std::strerror(result);
          ::close(input[1]);
          ::close(output[0]);
          helper_pid = -1;
          return false;
        }

        to_helper = input[1];
        from_helper = output[0];
        fcntl(to_helper, F_SETNOSIGPIPE, 1);
        fcntl(to_helper, F_SETFD, FD_CLOEXEC);
        fcntl(from_helper, F_SETFD, FD_CLOEXEC);
        received.clear();
        return true;
      }

      /**
       * @brief Send a command to the helper and wait for its reply.
       *
       * Log lines sent by the helper before the reply are forwarded to the Sunshine log.
       *
       * @param command Command line.
       * @return True when the helper replied with success.
       */
      bool send_command(const std::string &command) {
        if (!write_line(to_helper, command)) {
          BOOST_LOG(error) << "Unable to send a command to the virtual display helper"sv;
          return false;
        }

        while (true) {
          const auto line {read_line()};
          if (!line) {
            BOOST_LOG(error) << "The virtual display helper did not reply"sv;
            return false;
          }

          std::istringstream reply {*line};
          std::string kind;
          reply >> kind;

          if (kind == "log") {
            std::string level;
            std::string text;
            reply >> level;
            std::getline(reply >> std::ws, text);
            if (level == "error") {
              BOOST_LOG(error) << "Virtual display helper: "sv << text;
            } else if (level == "warning") {
              BOOST_LOG(warning) << "Virtual display helper: "sv << text;
            } else {
              BOOST_LOG(info) << "Virtual display helper: "sv << text;
            }
            continue;
          }

          if (kind == "ok") {
            display_id = kCGNullDirectDisplay;
            pixel_width = 0;
            pixel_height = 0;
            reply >> display_id >> pixel_width >> pixel_height;
            return display_id != kCGNullDirectDisplay;
          }

          std::string text;
          std::getline(reply >> std::ws, text);

          BOOST_LOG(error) << "Virtual display helper: "sv << text;
          return false;
        }
      }

      /**
       * @brief Read a line from the helper.
       *
       * @return Line without its newline, or an empty optional on timeout or end of input.
       */
      std::optional<std::string> read_line() {
        const auto deadline {std::chrono::steady_clock::now() + REPLY_TIMEOUT};
        while (true) {
          if (const auto newline {received.find('\n')}; newline != std::string::npos) {
            auto line {received.substr(0, newline)};
            received.erase(0, newline + 1);
            return line;
          }

          const auto remaining {std::chrono::duration_cast<std::chrono::milliseconds>(deadline - std::chrono::steady_clock::now())};
          if (remaining.count() <= 0) {
            return std::nullopt;
          }

          pollfd descriptor {from_helper, POLLIN, 0};
          const auto ready {poll(&descriptor, 1, static_cast<int>(remaining.count()))};
          if (ready < 0 && errno == EINTR) {
            continue;
          }
          if (ready <= 0) {
            return std::nullopt;
          }

          char buffer[256];
          const auto count {::read(from_helper, buffer, sizeof(buffer))};
          if (count < 0 && errno == EINTR) {
            continue;
          }
          if (count <= 0) {
            return std::nullopt;
          }
          received.append(buffer, static_cast<std::size_t>(count));
        }
      }

      /**
       * @brief Close the pipes to the helper; the helper exits when its input closes.
       */
      void close_pipes() {
        if (to_helper >= 0) {
          ::close(to_helper);
          to_helper = -1;
        }
        if (from_helper >= 0) {
          ::close(from_helper);
          from_helper = -1;
        }
      }

      /**
       * @brief Wait for the helper to exit, killing it if it does not exit in time.
       */
      void wait_for_helper_exit() {
        const auto pid {helper_pid};
        helper_pid = -1;

        // Sunshine reaps all children periodically, so ECHILD means the helper already exited.
        const auto exited {[pid]() {
          const auto result {waitpid(pid, nullptr, WNOHANG)};
          return result == pid || (result < 0 && errno == ECHILD);
        }};

        if (!wait_for(EXIT_TIMEOUT, exited)) {
          BOOST_LOG(warning) << "The virtual display helper did not exit. Terminating it."sv;
          kill(pid, SIGKILL);
          wait_for(EXIT_TIMEOUT, exited);
        }
      }

      pid_t helper_pid {-1};  ///< Process identifier of the helper, or -1.
      int to_helper {-1};  ///< Write end of the helper's standard input.
      int from_helper {-1};  ///< Read end of the helper's standard output.
      std::string received;  ///< Data read from the helper that does not form a complete line yet.
      CGDirectDisplayID display_id {kCGNullDirectDisplay};  ///< Identifier of the helper's display.
      int pixel_width {};  ///< Framebuffer width the helper reported.
      int pixel_height {};  ///< Framebuffer height the helper reported.
      bool made_main {false};  ///< Whether the display was made the main display.
      std::mutex helper_mutex;  ///< Serializes use of the helper and the fields above.
      std::thread monitor;  ///< Thread started by `start_monitor()`.
      std::mutex monitor_mutex;  ///< Protects `stop_monitoring`.
      std::condition_variable monitor_stopped;  ///< Signaled when the monitor should stop.
      bool stop_monitoring {false};  ///< Whether the monitor should stop.
    };
  }  // namespace

  bool wake_displays() {
    if (!any_display_asleep()) {
      return true;
    }

    // Local user activity turns the displays on; the assertion is released once they are awake.
    IOPMAssertionID assertion {kIOPMNullAssertionID};
    if (IOPMAssertionDeclareUserActivity(CFSTR("Sunshine virtual display"), kIOPMUserActiveLocal, &assertion) != kIOReturnSuccess) {
      BOOST_LOG(warning) << "Unable to wake the sleeping displays"sv;
      return false;
    }

    BOOST_LOG(info) << "Waking the sleeping displays"sv;
    const bool awake {wait_for(WAKE_TIMEOUT, []() {
      return !any_display_asleep();
    })};
    IOPMAssertionRelease(assertion);
    if (!awake) {
      BOOST_LOG(warning) << "The displays did not wake in time"sv;
    }
    return awake;
  }

  std::unique_ptr<backend_t> make_platform_backend() {
    return std::make_unique<macos_backend_t>();
  }

  void run_display_event_loop(const std::function<bool()> &stop_requested) {
    while (!stop_requested()) {
      process_display_events(250ms);
    }
  }

  int run_helper() {
    is_helper_process = true;

    // The helper must not die from a broken pipe; it exits when its input closes instead.
    signal(SIGPIPE, SIG_IGN);

    // Messages are sent as "log <level> <text>" lines; each command ends with one "ok" or "error" line.
    display_owner_t owner {[](std::string_view level, const std::string &message) {
      write_line(STDOUT_FILENO, "log " + std::string {level} + ' ' + single_line(message));
    }};

    std::string line;
    while (std::getline(std::cin, line)) {
      std::istringstream command {line};
      std::string name;
      command >> name;

      CGDirectDisplayID id {kCGNullDirectDisplay};
      if (name == "create") {
        identity_t identity {};
        mode_t mode {};
        options_t options {};
        if (command >> identity.vendor_id >> identity.product_id >> identity.serial_number >> mode.width >> mode.height >> mode.refresh_rate >> options.hidpi >> options.make_main) {
          std::getline(command >> std::ws, identity.name);
          id = owner.create(identity, mode, options);
        }
      } else if (name == "restore") {
        id = owner.reapply();
      } else if (name == "quit") {
        break;
      } else {
        write_line(STDOUT_FILENO, "error Unknown command: " + single_line(name));
        continue;
      }

      if (id == kCGNullDirectDisplay) {
        write_line(STDOUT_FILENO, "error The virtual display could not be configured");
        continue;
      }

      // Report the framebuffer size, so Sunshine can wait until its own view of the display matches.
      int pixel_width {};
      int pixel_height {};
      if (const auto mode {CGDisplayCopyDisplayMode(id)}) {
        pixel_width = static_cast<int>(CGDisplayModeGetPixelWidth(mode));
        pixel_height = static_cast<int>(CGDisplayModeGetPixelHeight(mode));
        CGDisplayModeRelease(mode);
      }
      write_line(STDOUT_FILENO, "ok " + std::to_string(id) + ' ' + std::to_string(pixel_width) + ' ' + std::to_string(pixel_height));
    }

    // Exiting removes the display and reverts the arrangement changes of this process.
    return 0;
  }
}  // namespace virtual_display
