/**
 * @file tests/unit/platform/macos/test_virtual_display.mm
 * @brief Unit tests for src/platform/macos/virtual_display.mm.
 */

// Only compile these tests on macOS
#ifdef __APPLE__

  // test includes
  #include "../../../tests_common.h"

  // platform includes
  #import <CoreGraphics/CoreGraphics.h>
  #import <Foundation/Foundation.h>

  // standard includes
  #include <cstdlib>
  #include <string>

  // local includes
  #import <src/platform/macos/sck_video.h>
  #import <src/platform/macos/virtual_display.h>
  #include <src/virtual_display.h>

namespace {
  /**
   * @brief Fixture for tests that create real virtual displays.
   *
   * Creating a display changes the arrangement of the machine running the tests, so these tests
   * only run when `SUNSHINE_TEST_REAL_VIRTUAL_DISPLAY` is set and a window server session exists.
   */
  class MacVirtualDisplayTest: public testing::Test {
  protected:
    void SetUp() override {
      const auto *opt_in = std::getenv("SUNSHINE_TEST_REAL_VIRTUAL_DISPLAY");  // NOSONAR(cpp:S5421): read-only lookup
      if (opt_in == nullptr || std::string_view {opt_in} != "1") {
        GTEST_SKIP() << "Set SUNSHINE_TEST_REAL_VIRTUAL_DISPLAY=1 to create real virtual displays";
      }

      backend = virtual_display::make_platform_backend();
      ASSERT_TRUE(backend);
      if (!backend->is_available()) {
        GTEST_SKIP() << "CGVirtualDisplay is not available on this macOS version";
      }
      main_display = CGMainDisplayID();
      main_bounds = CGDisplayBounds(main_display);
    }

    void TearDown() override {
      if (backend) {
        backend->destroy();
      }
    }

    /**
     * @brief Read the current mode of a display.
     *
     * @param display Display selector returned by the backend.
     * @param pixel_width Receives the framebuffer width.
     * @param pixel_height Receives the framebuffer height.
     * @param point_width Receives the desktop width in points.
     * @param refresh_rate Receives the refresh rate.
     */
    static void read_mode(const std::string &display, int &pixel_width, int &pixel_height, int &point_width, double &refresh_rate) {
      const auto mode = CGDisplayCopyDisplayMode(static_cast<CGDirectDisplayID>(std::stoul(display)));
      ASSERT_NE(mode, nullptr);
      pixel_width = static_cast<int>(CGDisplayModeGetPixelWidth(mode));
      pixel_height = static_cast<int>(CGDisplayModeGetPixelHeight(mode));
      point_width = static_cast<int>(CGDisplayModeGetWidth(mode));
      refresh_rate = CGDisplayModeGetRefreshRate(mode);
      CGDisplayModeRelease(mode);
    }

    std::unique_ptr<virtual_display::backend_t> backend;  ///< Real macOS backend.
    CGDirectDisplayID main_display {};  ///< Main display before the test.
    CGRect main_bounds {};  ///< Bounds of the main display before the test.
  };
}  // namespace

TEST(MacVirtualDisplayBackendTest, ProvidesPlatformBackend) {
  const auto backend = virtual_display::make_platform_backend();
  ASSERT_TRUE(backend);
  EXPECT_EQ(backend->is_available(), NSClassFromString(@"CGVirtualDisplay") != nil);
}

TEST_F(MacVirtualDisplayTest, CreatesExactModeAsMainDisplayAndRestoresLayout) {
  const auto identity = virtual_display::derive_identity("mac-virtual-display-test-main", "Sunshine Test");
  const auto display = backend->create(identity, {2560, 1600, 120}, {.hidpi = false, .make_main = true});
  ASSERT_TRUE(display);

  int pixel_width {}, pixel_height {}, point_width {};
  double refresh_rate {};
  read_mode(*display, pixel_width, pixel_height, point_width, refresh_rate);
  EXPECT_EQ(pixel_width, 2560);
  EXPECT_EQ(pixel_height, 1600);
  EXPECT_EQ(point_width, 2560);
  EXPECT_DOUBLE_EQ(refresh_rate, 120.0);
  EXPECT_EQ(std::to_string(CGMainDisplayID()), *display);
  EXPECT_FALSE(backend->has_physical_display() && CGDisplayIsMain(main_display));

  backend->destroy();
  EXPECT_EQ(CGMainDisplayID(), main_display);
  EXPECT_TRUE(CGRectEqualToRect(CGDisplayBounds(main_display), main_bounds));
}

TEST_F(MacVirtualDisplayTest, CreatesHiDpiDisplayWithRequestedFramebuffer) {
  const auto identity = virtual_display::derive_identity("mac-virtual-display-test-hidpi", "Sunshine Test");
  const auto display = backend->create(identity, {2560, 1600, 60}, {.hidpi = true, .make_main = false});
  ASSERT_TRUE(display);

  int pixel_width {}, pixel_height {}, point_width {};
  double refresh_rate {};
  read_mode(*display, pixel_width, pixel_height, point_width, refresh_rate);
  EXPECT_EQ(pixel_width, 2560);
  EXPECT_EQ(pixel_height, 1600);
  EXPECT_EQ(point_width, 1280);
  EXPECT_EQ(CGMainDisplayID(), main_display);
}

TEST_F(MacVirtualDisplayTest, CreatesLargeModes) {
  const auto identity = virtual_display::derive_identity("mac-virtual-display-test-large", "Sunshine Test");
  const auto display = backend->create(identity, {3840, 2160, 60}, {.hidpi = false, .make_main = false});
  ASSERT_TRUE(display);

  int pixel_width {}, pixel_height {}, point_width {};
  double refresh_rate {};
  read_mode(*display, pixel_width, pixel_height, point_width, refresh_rate);
  EXPECT_EQ(pixel_width, 3840);
  EXPECT_EQ(pixel_height, 2160);
}

TEST_F(MacVirtualDisplayTest, TurnsOffMirroringRestoredByMacOS) {
  const auto identity = virtual_display::derive_identity("mac-virtual-display-test-mirror", "Sunshine Test");
  constexpr virtual_display::mode_t mode {1920, 1080, 60};
  constexpr virtual_display::options_t options {.hidpi = false, .make_main = false};
  const auto first = backend->create(identity, mode, options);
  ASSERT_TRUE(first);

  // Store mirroring for this identity, as macOS does when the user mirrors the display.
  CGDisplayConfigRef config {};
  ASSERT_EQ(CGBeginDisplayConfiguration(&config), kCGErrorSuccess);
  CGConfigureDisplayMirrorOfDisplay(config, static_cast<CGDirectDisplayID>(std::stoul(*first)), main_display);
  ASSERT_EQ(CGCompleteDisplayConfiguration(config, kCGConfigurePermanently), kCGErrorSuccess);
  backend->destroy();

  const auto display = backend->create(identity, mode, options);
  ASSERT_TRUE(display);
  const auto display_id = static_cast<CGDirectDisplayID>(std::stoul(*display));
  EXPECT_FALSE(CGDisplayIsInMirrorSet(display_id));

  int pixel_width {}, pixel_height {}, point_width {};
  double refresh_rate {};
  read_mode(*display, pixel_width, pixel_height, point_width, refresh_rate);
  EXPECT_EQ(pixel_width, 1920);
  EXPECT_EQ(point_width, 1920);
  EXPECT_DOUBLE_EQ(refresh_rate, 60.0);
}

TEST_F(MacVirtualDisplayTest, WakingAwakeDisplaysSucceeds) {
  EXPECT_TRUE(virtual_display::wake_displays());
}

TEST_F(MacVirtualDisplayTest, CapturesVirtualDisplayWithScreenCaptureKit) {
  const auto identity = virtual_display::derive_identity("mac-virtual-display-test-capture", "Sunshine Test");
  const auto display = backend->create(identity, {1920, 1080, 60}, {.hidpi = false, .make_main = false});
  ASSERT_TRUE(display);

  SCKVideo *capture = [[SCKVideo alloc] initWithDisplay:static_cast<CGDirectDisplayID>(std::stoul(*display)) frameRate:60];
  ASSERT_NE(capture, nil);
  EXPECT_EQ(capture.frameWidth, 1920);
  EXPECT_EQ(capture.frameHeight, 1080);

  [capture setFrameWidth:1280 frameHeight:720];
  capture.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;

  __block std::size_t frame_width {};
  __block std::size_t frame_height {};
  dispatch_semaphore_t stopped = [capture capture:^bool(CMSampleBufferRef sample_buffer) {
    const auto image = CMSampleBufferGetImageBuffer(sample_buffer);
    frame_width = CVPixelBufferGetWidth(image);
    frame_height = CVPixelBufferGetHeight(image);
    return false;
  }];
  ASSERT_NE(stopped, nil);
  EXPECT_EQ(dispatch_semaphore_wait(stopped, dispatch_time(DISPATCH_TIME_NOW, 10LL * NSEC_PER_SEC)), 0);
  EXPECT_EQ(frame_width, 1280U);
  EXPECT_EQ(frame_height, 720U);

  [capture release];
}

#endif
