/**
 * @file tests/tests_environment.h
 * @brief Declarations for SunshineEnvironment.
 */
#pragma once

// test includes
#include "tests_common.h"

// local includes
#include <src/virtual_display.h>

struct SunshineEnvironment: testing::Environment {
  void SetUp() override {
    mail::man = std::make_shared<safe::mail_raw_t>();
    deinit_log = logging::init(0, "test_sunshine.log");
    // Tests must never create real displays. Tests that need a backend install a fake one.
    virtual_display::set_backend(nullptr);
  }

  void TearDown() override {
    deinit_log = {};
    mail::man = {};
  }

  std::unique_ptr<logging::deinit_t> deinit_log;
};
