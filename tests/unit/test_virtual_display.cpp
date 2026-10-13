/**
 * @file tests/unit/test_virtual_display.cpp
 * @brief Tests for the platform-neutral virtual display logic.
 */

// test includes
#include "../tests_common.h"
#include "../virtual_display_test_utils.h"

// standard includes
#include <cstdlib>
#include <memory>
#include <set>
#include <string>

// local includes
#include <src/virtual_display.h>

using namespace std::literals;

namespace {
  using test_utils::virtual_display::backend_log_t;
  using test_utils::virtual_display::fake_backend_t;

  /**
   * @brief Fixture that installs a fake backend for each test.
   */
  class VirtualDisplaySessionTest: public testing::Test {
  protected:
    void SetUp() override {
      log = std::make_shared<backend_log_t>();
      auto fake {std::make_unique<fake_backend_t>(log)};
      backend = fake.get();
      virtual_display::set_backend(std::move(fake));
    }

    void TearDown() override {
      virtual_display::set_backend(nullptr);
      unsetenv("SUNSHINE_DISABLE_VIRTUAL_DISPLAY");
    }

    /**
     * @brief Build a session request.
     *
     * @param app_requests Whether the app asks for a virtual display.
     * @param mode Requested mode.
     * @return Session request.
     */
    static virtual_display::session_request_t request(bool app_requests, virtual_display::mode_t mode = {2560, 1600, 120}) {
      return {
        .app_requests_virtual_display = app_requests,
        .headless_mode = false,
        .options = {.hidpi = false, .make_main = true},
        .client_id = "client-cert",
        .client_name = "Tablet",
        .mode = mode,
      };
    }

    std::shared_ptr<backend_log_t> log;  ///< Calls recorded by the fake backend.
    fake_backend_t *backend {};  ///< Fake backend owned by the session state.
  };
}  // namespace

TEST(VirtualDisplayDecisionTest, StreamsPhysicalDisplayWhenNothingRequestsVirtualDisplay) {
  EXPECT_EQ(virtual_display::decide({false, false, true}), virtual_display::decision_e::not_needed);
}

TEST(VirtualDisplayDecisionTest, UsesVirtualDisplayForAppOption) {
  EXPECT_EQ(virtual_display::decide({true, false, true}), virtual_display::decision_e::app_option);
  EXPECT_EQ(virtual_display::decide({true, true, false}), virtual_display::decision_e::app_option);
}

TEST(VirtualDisplayDecisionTest, UsesVirtualDisplayInHeadlessMode) {
  EXPECT_EQ(virtual_display::decide({false, true, true}), virtual_display::decision_e::headless_mode);
  EXPECT_EQ(virtual_display::decide({false, true, false}), virtual_display::decision_e::headless_mode);
}

TEST(VirtualDisplayDecisionTest, FallsBackToVirtualDisplayWithoutPhysicalDisplay) {
  EXPECT_EQ(virtual_display::decide({false, false, false}), virtual_display::decision_e::no_physical_display);
}

TEST(VirtualDisplayDecisionTest, DescribesEveryDecision) {
  const std::set<std::string_view> descriptions {
    virtual_display::to_string(virtual_display::decision_e::not_needed),
    virtual_display::to_string(virtual_display::decision_e::app_option),
    virtual_display::to_string(virtual_display::decision_e::headless_mode),
    virtual_display::to_string(virtual_display::decision_e::no_physical_display),
  };
  EXPECT_EQ(descriptions.size(), 4U);
  EXPECT_FALSE(descriptions.contains(""sv));
}

TEST(VirtualDisplayIdentityTest, SameClientAlwaysGetsSameIdentity) {
  const auto first {virtual_display::derive_identity("client-a", "Tablet")};
  const auto second {virtual_display::derive_identity("client-a", "Renamed Tablet")};

  EXPECT_EQ(first.vendor_id, second.vendor_id);
  EXPECT_EQ(first.product_id, second.product_id);
  EXPECT_EQ(first.serial_number, second.serial_number);
}

TEST(VirtualDisplayIdentityTest, DifferentClientsGetDifferentIdentities) {
  const auto first {virtual_display::derive_identity("client-a", "Tablet")};
  const auto second {virtual_display::derive_identity("client-b", "Tablet")};

  EXPECT_EQ(first.vendor_id, second.vendor_id);
  EXPECT_TRUE(first.product_id != second.product_id || first.serial_number != second.serial_number);
}

TEST(VirtualDisplayIdentityTest, IdentityIsStableAcrossBuilds) {
  // FNV-1a of an empty string is 0xcbf29ce484222325. Pinning it guards against an unstable hash.
  const auto identity {virtual_display::derive_identity("", "")};

  EXPECT_EQ(identity.vendor_id, virtual_display::VENDOR_ID);
  EXPECT_EQ(identity.product_id, 0x2325U);
  EXPECT_EQ(identity.serial_number, 0xcbf29ce4U);
}

TEST(VirtualDisplayIdentityTest, UsesClientNameForDisplayName) {
  EXPECT_EQ(virtual_display::derive_identity("client-a", "Living Room Tablet").name, "Living Room Tablet");
  EXPECT_EQ(virtual_display::derive_identity("client-a", "").name, virtual_display::DEFAULT_DISPLAY_NAME);
}

TEST(VirtualDisplayIdentityTest, ProductAndSerialAreNeverZero) {
  for (int index = 0; index < 2000; ++index) {
    const auto identity {virtual_display::derive_identity(std::to_string(index), "")};
    EXPECT_NE(identity.product_id, 0U);
    EXPECT_LE(identity.product_id, 0xFFFFU);
    EXPECT_NE(identity.serial_number, 0U);
  }
}

TEST(VirtualDisplayIdentityTest, ModeIdentityKeepsClientNumbersAndName) {
  const auto client {virtual_display::derive_identity("client-a", "Tablet")};
  const auto identity {virtual_display::identity_for_mode(client, {2560, 1600, 120}, {.hidpi = false, .make_main = true})};

  EXPECT_EQ(identity.vendor_id, client.vendor_id);
  EXPECT_EQ(identity.product_id, client.product_id);
  EXPECT_EQ(identity.name, client.name);
  EXPECT_NE(identity.serial_number, 0U);
}

TEST(VirtualDisplayIdentityTest, ModeIdentityIsStableForTheSameMode) {
  const auto client {virtual_display::derive_identity("client-a", "Tablet")};
  constexpr virtual_display::options_t options {.hidpi = false, .make_main = true};

  EXPECT_EQ(virtual_display::identity_for_mode(client, {2560, 1600, 120}, options).serial_number, virtual_display::identity_for_mode(client, {2560, 1600, 120}, options).serial_number);
}

TEST(VirtualDisplayIdentityTest, ModeIdentityDiffersPerModeAndOptions) {
  const auto client {virtual_display::derive_identity("client-a", "Tablet")};
  constexpr virtual_display::options_t options {.hidpi = false, .make_main = true};
  const auto base {virtual_display::identity_for_mode(client, {3840, 2160, 100}, options).serial_number};

  EXPECT_NE(virtual_display::identity_for_mode(client, {2560, 1440, 100}, options).serial_number, base);
  EXPECT_NE(virtual_display::identity_for_mode(client, {3840, 2160, 60}, options).serial_number, base);
  EXPECT_NE(virtual_display::identity_for_mode(client, {3840, 2160, 100}, {.hidpi = true, .make_main = true}).serial_number, base);
  EXPECT_NE(virtual_display::identity_for_mode(client, {3840, 2160, 100}, {.hidpi = false, .make_main = false}).serial_number, base);
  EXPECT_NE(virtual_display::identity_for_mode(virtual_display::derive_identity("client-b", "Tablet"), {3840, 2160, 100}, options).serial_number, base);
}

TEST(VirtualDisplayIdentityTest, ModeIdentitySerialIsNeverZero) {
  const auto client {virtual_display::derive_identity("client-a", "Tablet")};
  for (int width = 640; width < 2640; ++width) {
    EXPECT_NE(virtual_display::identity_for_mode(client, {width, 1080, 60}, {.hidpi = false, .make_main = true}).serial_number, 0U);
  }
}

TEST(VirtualDisplayModeTest, KeepsValidMode) {
  constexpr virtual_display::mode_t mode {2560, 1600, 120};
  EXPECT_EQ(virtual_display::sanitize_mode(mode), mode);
}

TEST(VirtualDisplayModeTest, UsesDefaultModeForMissingValues) {
  EXPECT_EQ(virtual_display::sanitize_mode({0, 0, 0}), virtual_display::DEFAULT_MODE);
  EXPECT_EQ(virtual_display::sanitize_mode({-1, 1080, 60}), virtual_display::DEFAULT_MODE);
  EXPECT_EQ(virtual_display::sanitize_mode({1920, 1080, -5}), virtual_display::DEFAULT_MODE);
}

TEST(VirtualDisplayModeTest, ConvertsMillihertzRefreshRates) {
  EXPECT_EQ(virtual_display::sanitize_mode({1920, 1080, 59940}).refresh_rate, 60);
  EXPECT_EQ(virtual_display::sanitize_mode({1920, 1080, 120000}).refresh_rate, 120);
}

TEST(VirtualDisplayModeTest, ClampsRefreshRate) {
  EXPECT_EQ(virtual_display::sanitize_mode({1920, 1080, 10}).refresh_rate, virtual_display::DEFAULT_LIMITS.min_refresh_rate);
  EXPECT_EQ(virtual_display::sanitize_mode({1920, 1080, 999}).refresh_rate, virtual_display::DEFAULT_LIMITS.max_refresh_rate);
}

TEST(VirtualDisplayModeTest, ScalesOversizedModeKeepingAspectRatio) {
  const auto mode {virtual_display::sanitize_mode({15360, 8640, 60})};
  EXPECT_EQ(mode.width, 7680);
  EXPECT_EQ(mode.height, 4320);
}

TEST(VirtualDisplayModeTest, ScalesUndersizedModeKeepingAspectRatio) {
  const auto mode {virtual_display::sanitize_mode({320, 240, 60})};
  EXPECT_EQ(mode.width, 640);
  EXPECT_EQ(mode.height, 480);
}

TEST(VirtualDisplayModeTest, ClampsExtremeAspectRatios) {
  const auto mode {virtual_display::sanitize_mode({20000, 100, 60})};
  EXPECT_EQ(mode.width, virtual_display::DEFAULT_LIMITS.max_width);
  EXPECT_EQ(mode.height, virtual_display::DEFAULT_LIMITS.min_height);
}

TEST(VirtualDisplayModeTest, RoundsOddDimensionsDown) {
  EXPECT_EQ(virtual_display::sanitize_mode({1921, 1081, 60}), (virtual_display::mode_t {1920, 1080, 60}));
}

TEST(VirtualDisplayModeTest, AllowsHiDpiOnlyAboveMacOsMinimum) {
  EXPECT_TRUE(virtual_display::supports_hidpi({2560, 1600, 60}));
  EXPECT_TRUE(virtual_display::supports_hidpi({1920, 1080, 60}));
  EXPECT_TRUE(virtual_display::supports_hidpi({1680, 1050, 60}));
  EXPECT_TRUE(virtual_display::supports_hidpi({1600, 1200, 60}));
  EXPECT_TRUE(virtual_display::supports_hidpi({1200, 1920, 60})) << "Portrait modes compare the long and short sides";

  EXPECT_FALSE(virtual_display::supports_hidpi({1600, 1000, 60}));
  EXPECT_FALSE(virtual_display::supports_hidpi({1440, 1080, 60}));
  EXPECT_FALSE(virtual_display::supports_hidpi({1600, 900, 60}));
  EXPECT_FALSE(virtual_display::supports_hidpi({1280, 720, 60}));
}

TEST(VirtualDisplayModeTest, HonorsCustomLimits) {
  constexpr virtual_display::limits_t limits {800, 600, 1920, 1080, 30, 60};
  EXPECT_EQ(virtual_display::sanitize_mode({3840, 2160, 120}, limits), (virtual_display::mode_t {1920, 1080, 60}));
}

TEST_F(VirtualDisplaySessionTest, DoesNotCreateDisplayWhenNotNeeded) {
  EXPECT_EQ(virtual_display::prepare_session(request(false)), virtual_display::status_e::not_used);
  EXPECT_EQ(log->create_calls, 0);
  EXPECT_FALSE(virtual_display::is_active());
  EXPECT_TRUE(virtual_display::active_display_name().empty());
}

TEST_F(VirtualDisplaySessionTest, CreatesDisplayForAppRequest) {
  EXPECT_EQ(virtual_display::prepare_session(request(true)), virtual_display::status_e::active);

  EXPECT_EQ(log->create_calls, 1);
  EXPECT_EQ(log->last_mode, (virtual_display::mode_t {2560, 1600, 120}));
  EXPECT_EQ(log->last_identity.name, "Tablet");
  const auto expected {virtual_display::identity_for_mode(virtual_display::derive_identity("client-cert", "Tablet"), {2560, 1600, 120}, log->last_options)};
  EXPECT_EQ(log->last_identity.product_id, expected.product_id);
  EXPECT_EQ(log->last_identity.serial_number, expected.serial_number);
  EXPECT_TRUE(log->last_options.make_main);
  EXPECT_EQ(log->wake_calls, 1);
  EXPECT_TRUE(virtual_display::is_active());
  EXPECT_EQ(virtual_display::active_display_name(), "100");
}

TEST_F(VirtualDisplaySessionTest, CreatesDisplayInHeadlessMode) {
  auto headless {request(false)};
  headless.headless_mode = true;
  EXPECT_EQ(virtual_display::prepare_session(headless), virtual_display::status_e::active);
  EXPECT_EQ(log->create_calls, 1);
}

TEST_F(VirtualDisplaySessionTest, CreatesDisplayWhenNoPhysicalDisplayExists) {
  backend->physical_display = false;
  EXPECT_EQ(virtual_display::prepare_session(request(false)), virtual_display::status_e::active);
  EXPECT_EQ(log->create_calls, 1);
}

TEST_F(VirtualDisplaySessionTest, CreatesSanitizedMode) {
  EXPECT_EQ(virtual_display::prepare_session(request(true, {1921, 1081, 59940})), virtual_display::status_e::active);
  EXPECT_EQ(log->last_mode, (virtual_display::mode_t {1920, 1080, 60}));
}

TEST_F(VirtualDisplaySessionTest, CreatesSmallHiDpiRequestAsStandardDisplay) {
  auto small {request(true, {1280, 720, 60})};
  small.options.hidpi = true;
  EXPECT_EQ(virtual_display::prepare_session(small), virtual_display::status_e::active);
  EXPECT_FALSE(log->last_options.hidpi);

  // The effective options are remembered, so resuming with the same request shares the display.
  EXPECT_EQ(virtual_display::prepare_session(small), virtual_display::status_e::active);
  EXPECT_EQ(log->create_calls, 1);
}

TEST_F(VirtualDisplaySessionTest, SharesDisplayWhenModeIsUnchanged) {
  ASSERT_EQ(virtual_display::prepare_session(request(true)), virtual_display::status_e::active);
  EXPECT_EQ(virtual_display::prepare_session(request(false)), virtual_display::status_e::active);

  EXPECT_EQ(log->create_calls, 1);
  EXPECT_EQ(log->destroy_calls, 0);
}

TEST_F(VirtualDisplaySessionTest, RecreatesDisplayWithNewIdentityWhenModeChanges) {
  ASSERT_EQ(virtual_display::prepare_session(request(true)), virtual_display::status_e::active);
  const auto first_serial {log->last_identity.serial_number};
  EXPECT_EQ(virtual_display::prepare_session(request(true, {1920, 1080, 60})), virtual_display::status_e::active);

  EXPECT_EQ(log->destroy_calls, 1);
  EXPECT_EQ(log->create_calls, 2);
  EXPECT_EQ(log->last_mode, (virtual_display::mode_t {1920, 1080, 60}));
  EXPECT_NE(log->last_identity.serial_number, first_serial);
  EXPECT_EQ(virtual_display::active_display_name(), "101");
}

TEST_F(VirtualDisplaySessionTest, RecreatesDisplayWhenOptionsChange) {
  ASSERT_EQ(virtual_display::prepare_session(request(true)), virtual_display::status_e::active);
  auto hidpi {request(true)};
  hidpi.options.hidpi = true;
  EXPECT_EQ(virtual_display::prepare_session(hidpi), virtual_display::status_e::active);

  EXPECT_EQ(log->destroy_calls, 1);
  EXPECT_EQ(log->create_calls, 2);
  EXPECT_TRUE(log->last_options.hidpi);
}

TEST_F(VirtualDisplaySessionTest, FallsBackToPhysicalDisplayWhenRecreationFails) {
  ASSERT_EQ(virtual_display::prepare_session(request(true)), virtual_display::status_e::active);
  backend->create_succeeds = false;

  EXPECT_EQ(virtual_display::prepare_session(request(true, {3840, 2160, 60})), virtual_display::status_e::fallback_physical);
  EXPECT_EQ(log->destroy_calls, 1);
  EXPECT_FALSE(virtual_display::is_active());
}

TEST_F(VirtualDisplaySessionTest, DoesNotWakeDisplaysWhenUnavailable) {
  backend->available = false;
  EXPECT_EQ(virtual_display::prepare_session(request(true)), virtual_display::status_e::fallback_physical);
  EXPECT_EQ(log->wake_calls, 0);
}

TEST_F(VirtualDisplaySessionTest, FallsBackToPhysicalDisplayAfterCaptureFailure) {
  ASSERT_EQ(virtual_display::prepare_session(request(true)), virtual_display::status_e::active);

  EXPECT_TRUE(virtual_display::fall_back_to_physical());
  EXPECT_EQ(log->destroy_calls, 1);
  EXPECT_FALSE(virtual_display::is_active());
  EXPECT_TRUE(virtual_display::active_display_name().empty());

  EXPECT_FALSE(virtual_display::fall_back_to_physical()) << "Nothing is removed when no display is active";
  EXPECT_EQ(log->destroy_calls, 1);
}

TEST_F(VirtualDisplaySessionTest, KeepsVirtualDisplayAfterCaptureFailureWithoutPhysicalDisplay) {
  backend->physical_display = false;
  ASSERT_EQ(virtual_display::prepare_session(request(true)), virtual_display::status_e::active);

  EXPECT_FALSE(virtual_display::fall_back_to_physical());
  EXPECT_EQ(log->destroy_calls, 0);
  EXPECT_TRUE(virtual_display::is_active());
}

TEST_F(VirtualDisplaySessionTest, FallsBackToPhysicalDisplayWhenUnavailable) {
  backend->available = false;
  EXPECT_FALSE(virtual_display::is_available());
  EXPECT_EQ(virtual_display::prepare_session(request(true)), virtual_display::status_e::fallback_physical);
  EXPECT_EQ(log->create_calls, 0);
}

TEST_F(VirtualDisplaySessionTest, FailsWhenUnavailableWithoutPhysicalDisplay) {
  backend->available = false;
  backend->physical_display = false;
  EXPECT_EQ(virtual_display::prepare_session(request(false)), virtual_display::status_e::failed);
}

TEST_F(VirtualDisplaySessionTest, FallsBackToPhysicalDisplayWhenCreationFails) {
  backend->create_succeeds = false;
  EXPECT_EQ(virtual_display::prepare_session(request(true)), virtual_display::status_e::fallback_physical);
  EXPECT_FALSE(virtual_display::is_active());
}

TEST_F(VirtualDisplaySessionTest, FailsWhenCreationFailsWithoutPhysicalDisplay) {
  backend->create_succeeds = false;
  backend->physical_display = false;
  EXPECT_EQ(virtual_display::prepare_session(request(true)), virtual_display::status_e::failed);
  EXPECT_FALSE(virtual_display::is_active());
}

TEST_F(VirtualDisplaySessionTest, EnvironmentVariableDisablesFeature) {
  setenv("SUNSHINE_DISABLE_VIRTUAL_DISPLAY", "1", 1);
  EXPECT_FALSE(virtual_display::is_available());
  EXPECT_EQ(virtual_display::prepare_session(request(true)), virtual_display::status_e::fallback_physical);

  setenv("SUNSHINE_DISABLE_VIRTUAL_DISPLAY", "0", 1);
  EXPECT_TRUE(virtual_display::is_available());
}

TEST_F(VirtualDisplaySessionTest, EndSessionRemovesDisplay) {
  ASSERT_EQ(virtual_display::prepare_session(request(true)), virtual_display::status_e::active);
  virtual_display::end_session();

  EXPECT_EQ(log->destroy_calls, 1);
  EXPECT_FALSE(virtual_display::is_active());
  EXPECT_TRUE(virtual_display::active_display_name().empty());

  virtual_display::end_session();
  EXPECT_EQ(log->destroy_calls, 1);
}

TEST_F(VirtualDisplaySessionTest, CreatesProbeDisplay) {
  backend->physical_display = false;
  EXPECT_TRUE(virtual_display::create_probe_display());
  EXPECT_EQ(log->last_mode, virtual_display::DEFAULT_MODE);
  EXPECT_FALSE(log->last_options.make_main);
  EXPECT_TRUE(virtual_display::is_active());

  EXPECT_FALSE(virtual_display::create_probe_display());
  EXPECT_EQ(log->create_calls, 1);

  virtual_display::end_session();
  EXPECT_FALSE(virtual_display::is_active());
}

TEST_F(VirtualDisplaySessionTest, SkipsProbeDisplayWhenPhysicalDisplayExists) {
  EXPECT_FALSE(virtual_display::create_probe_display());
  EXPECT_EQ(log->wake_calls, 1) << "A sleeping physical display must be woken before it is counted";
  EXPECT_EQ(log->create_calls, 0);
  EXPECT_FALSE(virtual_display::is_active());
}

TEST_F(VirtualDisplaySessionTest, ProbeDisplayRequiresAvailableBackend) {
  backend->physical_display = false;
  backend->available = false;
  EXPECT_FALSE(virtual_display::create_probe_display());

  backend->available = true;
  backend->create_succeeds = false;
  EXPECT_FALSE(virtual_display::create_probe_display());
  EXPECT_FALSE(virtual_display::is_active());
}

TEST_F(VirtualDisplaySessionTest, ReplacingBackendRemovesActiveDisplay) {
  ASSERT_EQ(virtual_display::prepare_session(request(true)), virtual_display::status_e::active);
  virtual_display::set_backend(nullptr);

  EXPECT_EQ(log->destroy_calls, 1);
  EXPECT_FALSE(virtual_display::is_active());
  EXPECT_FALSE(virtual_display::is_available());
}

TEST_F(VirtualDisplaySessionTest, MissingBackendAssumesPhysicalDisplay) {
  virtual_display::set_backend(nullptr);
  EXPECT_EQ(virtual_display::prepare_session(request(false)), virtual_display::status_e::not_used);
  EXPECT_EQ(virtual_display::prepare_session(request(true)), virtual_display::status_e::fallback_physical);
}
