/**
 * @file src/platform/macos/sck_video.h
 * @brief Declarations for ScreenCaptureKit display capture on macOS.
 */
#pragma once

// local includes
#import "av_video.h"

/**
 * @brief ScreenCaptureKit capture controller with the same interface as AVVideo.
 *
 * AVFoundation screen capture cannot capture a display that was added after the process first
 * used it, which is always the case for virtual displays created during a session. ScreenCaptureKit
 * looks up the current displays for every stream, so it is used for virtual displays.
 */
@interface SCKVideo: AVVideo

/**
 * @brief Initialize ScreenCaptureKit capture for a display and frame rate.
 *
 * @param displayID Display ID.
 * @param frameRate Frame rate.
 * @return Initialized SCKVideo instance, or nil when the display cannot be captured.
 */
- (id)initWithDisplay:(CGDirectDisplayID)displayID frameRate:(int)frameRate;

/**
 * @brief Start a capture stream that calls a block for each frame.
 *
 * @param frameCallback Block called with each complete frame; returning false stops the stream.
 * @return Semaphore signaled when the stream stops, or nil when the stream cannot start.
 */
- (dispatch_semaphore_t)capture:(FrameCallbackBlock)frameCallback;

@end
