/**
 * @file tests/unit/test_nvhttp_virtual_display.cpp
 * @brief Tests for how GameStream launches prepare virtual displays.
 */

// test includes
#include "../tests_common.h"
#include "../virtual_display_test_utils.h"

// standard includes
#include <memory>
#include <vector>

// lib includes
#include <boost/process/v1.hpp>

// local includes
#include <src/config.h>
#include <src/display_device.h>
#include <src/nvhttp.h>
#include <src/process.h>
#include <src/virtual_display.h>

namespace {
  /**
   * @brief Fixture with one app that requests a virtual display and one that does not.
   */
  class NvhttpVirtualDisplayTest: public testing::Test {
  protected:
    void SetUp() override {
      saved_proc = std::move(proc::proc);
      saved_video = config::video;

      std::vector<proc::ctx_t> apps;
      proc::ctx_t virtual_app;
      virtual_app.name = "Virtual Display";
      virtual_app.id = "11";
      virtual_app.virtual_display = true;
      apps.push_back(std::move(virtual_app));
      proc::ctx_t desktop;
      desktop.name = "Desktop";
      desktop.id = "12";
      apps.push_back(std::move(desktop));
      proc::proc = proc::proc_t(boost::this_process::environment(), std::move(apps));

      log = std::make_shared<test_utils::virtual_display::backend_log_t>();
      auto fake = std::make_unique<test_utils::virtual_display::fake_backend_t>(log);
      backend = fake.get();
      virtual_display::set_backend(std::move(fake));

      session.width = 2560;
      session.height = 1600;
      session.fps = 120;
      session.unique_id = "0123456789ABCDEF";
      session.client_cert = "client certificate";
      session.client_name = "Tablet";
    }

    void TearDown() override {
      virtual_display::set_backend(nullptr);
      config::video = saved_video;
      proc::proc = std::move(saved_proc);
    }

    proc::proc_t saved_proc;  ///< Global process state restored after each test.
    config::video_t saved_video;  ///< Video configuration restored after each test.
    std::shared_ptr<test_utils::virtual_display::backend_log_t> log;  ///< Calls recorded by the fake backend.
    test_utils::virtual_display::fake_backend_t *backend {};  ///< Fake backend owned by the session state.
    rtsp_stream::launch_session_t session {};  ///< Launch request used by the tests.
  };
}  // namespace

TEST_F(NvhttpVirtualDisplayTest, CreatesDisplayForAppWithVirtualDisplayOption) {
  config::video.virtual_display_hidpi = true;
  config::video.virtual_display_make_main = false;

  EXPECT_EQ(nvhttp::test_support::prepare_virtual_display(11, session), virtual_display::status_e::active);

  EXPECT_EQ(log->create_calls, 1);
  EXPECT_EQ(log->last_mode, (virtual_display::mode_t {2560, 1600, 120}));
  EXPECT_TRUE(log->last_options.hidpi);
  EXPECT_FALSE(log->last_options.make_main);
  EXPECT_EQ(log->last_identity.name, "Tablet");
}

TEST_F(NvhttpVirtualDisplayTest, DerivesIdentityFromPairedCertificate) {
  ASSERT_EQ(nvhttp::test_support::prepare_virtual_display(11, session), virtual_display::status_e::active);

  const auto expected = virtual_display::identity_for_mode(virtual_display::derive_identity("client certificate", "Tablet"), log->last_mode, log->last_options);
  EXPECT_EQ(log->last_identity.product_id, expected.product_id);
  EXPECT_EQ(log->last_identity.serial_number, expected.serial_number);
}

TEST_F(NvhttpVirtualDisplayTest, FallsBackToUniqueIdWithoutCertificate) {
  session.client_cert.clear();
  ASSERT_EQ(nvhttp::test_support::prepare_virtual_display(11, session), virtual_display::status_e::active);

  const auto expected = virtual_display::identity_for_mode(virtual_display::derive_identity("0123456789ABCDEF", "Tablet"), log->last_mode, log->last_options);
  EXPECT_EQ(log->last_identity.product_id, expected.product_id);
  EXPECT_EQ(log->last_identity.serial_number, expected.serial_number);
}

TEST_F(NvhttpVirtualDisplayTest, StreamsPhysicalDisplayForRegularApp) {
  EXPECT_EQ(nvhttp::test_support::prepare_virtual_display(12, session), virtual_display::status_e::not_used);
  EXPECT_EQ(nvhttp::test_support::prepare_virtual_display(999, session), virtual_display::status_e::not_used);
  EXPECT_EQ(log->create_calls, 0);
}

TEST_F(NvhttpVirtualDisplayTest, HeadlessModeUsesVirtualDisplayForRegularApp) {
  config::video.headless_mode = true;
  EXPECT_EQ(nvhttp::test_support::prepare_virtual_display(12, session), virtual_display::status_e::active);
}

TEST_F(NvhttpVirtualDisplayTest, CaptureTargetsActiveVirtualDisplay) {
  ASSERT_EQ(nvhttp::test_support::prepare_virtual_display(11, session), virtual_display::status_e::active);

  EXPECT_EQ(display_device::map_output_name("configured-display"), virtual_display::active_display_name());
#ifdef __APPLE__
  const auto names = platf::display_names(platf::mem_type_e::system);
  EXPECT_NE(std::ranges::find(names, virtual_display::active_display_name()), names.end());
#endif
}
