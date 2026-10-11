/**
 * @file src/platform/macos/sck_video.m
 * @brief Definitions for ScreenCaptureKit display capture on macOS.
 */
// platform includes
#import <ScreenCaptureKit/ScreenCaptureKit.h>

// local includes
#import "sck_video.h"

/**
 * @brief Time to wait for ScreenCaptureKit to answer a request.
 */
static const int64_t SCK_REQUEST_TIMEOUT_NS = 5 * NSEC_PER_SEC;

/**
 * @brief Number of attempts to find a display that was just added.
 */
static const int SCK_DISPLAY_LOOKUP_ATTEMPTS = 10;

/**
 * @brief Stream output that forwards complete frames to a capture callback.
 */
@interface SCKStreamOutput: NSObject <SCStreamOutput, SCStreamDelegate>
/**
 * @brief Block called for each complete frame.
 */
@property (nonatomic, copy) FrameCallbackBlock callback;
/**
 * @brief Semaphore signaled when the stream stops.
 */
@property (nonatomic, retain) dispatch_semaphore_t stopped;
/**
 * @brief Stream that delivers frames to this output.
 */
@property (nonatomic, retain) SCStream *stream;
/**
 * @brief Whether the stream was stopped.
 */
@property (atomic, assign) BOOL finished;

/**
 * @brief Stop the stream and signal the waiting caller once.
 */
- (void)finish;
@end

@implementation SCKStreamOutput

- (void)finish {
  @synchronized(self) {
    if (self.finished) {
      return;
    }
    self.finished = YES;
  }

  [self.stream stopCaptureWithCompletionHandler:^(NSError *error) {}];
  dispatch_semaphore_signal(self.stopped);
}

- (void)stream:(SCStream *)stream didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer ofType:(SCStreamOutputType)type {
  if (type != SCStreamOutputTypeScreen || self.finished) {
    return;
  }

  // ScreenCaptureKit also reports idle frames, which carry no image when nothing changed.
  CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, false);
  if (attachments && CFArrayGetCount(attachments) > 0) {
    NSDictionary *info = (NSDictionary *) CFArrayGetValueAtIndex(attachments, 0);
    NSNumber *status = info[SCStreamFrameInfoStatus];
    if (status && status.integerValue != SCFrameStatusComplete) {
      return;
    }
  }
  if (!CMSampleBufferGetImageBuffer(sampleBuffer)) {
    return;
  }

  if (!self.callback(sampleBuffer)) {
    [self finish];
  }
}

- (void)stream:(SCStream *)stream didStopWithError:(NSError *)error {
  NSLog(@"Screen capture stream stopped: %@", error);
  [self finish];
}

- (void)dealloc {
  [_callback release];
  [_stopped release];
  [_stream release];
  [super dealloc];
}

@end

@implementation SCKVideo {
  SCDisplay *_display;  ///< ScreenCaptureKit display to capture.
  NSMutableArray<SCKStreamOutput *> *_outputs;  ///< Outputs of the streams started by this object.
}

/**
 * @brief Find the ScreenCaptureKit display for a display identifier.
 *
 * @param displayID Display ID.
 * @return Retained display, or nil when it is not available.
 */
+ (SCDisplay *)copyDisplay:(CGDirectDisplayID)displayID {
  for (int attempt = 0; attempt < SCK_DISPLAY_LOOKUP_ATTEMPTS; ++attempt) {
    __block SCDisplay *found = nil;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    [SCShareableContent getShareableContentWithCompletionHandler:^(SCShareableContent *content, NSError *error) {
      for (SCDisplay *display in content.displays) {
        if (display.displayID == displayID) {
          found = [display retain];
        }
      }
      dispatch_semaphore_signal(done);
    }];
    const long timed_out = dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, SCK_REQUEST_TIMEOUT_NS));
    [done release];

    if (timed_out == 0 && found) {
      return found;
    }
    [NSThread sleepForTimeInterval:0.2];
  }
  return nil;
}

- (id)initWithDisplay:(CGDirectDisplayID)displayID frameRate:(int)frameRate {
  self = [super init];
  if (!self) {
    return nil;
  }

  _display = [SCKVideo copyDisplay:displayID];
  if (!_display) {
    NSLog(@"ScreenCaptureKit cannot find display %u", displayID);
    [self release];
    return nil;
  }

  self.displayID = displayID;
  self.pixelFormat = kCVPixelFormatType_32BGRA;
  self.minFrameDuration = CMTimeMake(1, frameRate);

  CGDisplayModeRef mode = CGDisplayCopyDisplayMode(displayID);
  if (mode) {
    self.frameWidth = (int) CGDisplayModeGetPixelWidth(mode);
    self.frameHeight = (int) CGDisplayModeGetPixelHeight(mode);
    CFRelease(mode);
  } else {
    self.frameWidth = (int) _display.width;
    self.frameHeight = (int) _display.height;
  }

  _outputs = [[NSMutableArray alloc] init];
  return self;
}

- (void)dealloc {
  NSArray<SCKStreamOutput *> *outputs = nil;
  @synchronized(self) {
    outputs = [[_outputs copy] autorelease];
  }

  // Stop every stream before the callbacks, which reference the caller's state, go away.
  for (SCKStreamOutput *output in outputs) {
    output.finished = YES;
    dispatch_semaphore_t stopped = dispatch_semaphore_create(0);
    [output.stream stopCaptureWithCompletionHandler:^(NSError *error) {
      dispatch_semaphore_signal(stopped);
    }];
    dispatch_semaphore_wait(stopped, dispatch_time(DISPATCH_TIME_NOW, SCK_REQUEST_TIMEOUT_NS));
    [stopped release];
  }

  [_outputs release];
  [_display release];
  [super dealloc];
}

- (dispatch_semaphore_t)capture:(FrameCallbackBlock)frameCallback {
  SCContentFilter *filter = [[SCContentFilter alloc] initWithDisplay:_display excludingWindows:@[]];

  SCStreamConfiguration *configuration = [[SCStreamConfiguration alloc] init];
  configuration.width = (size_t) self.frameWidth;
  configuration.height = (size_t) self.frameHeight;
  configuration.pixelFormat = self.pixelFormat;
  configuration.minimumFrameInterval = self.minFrameDuration;
  configuration.showsCursor = YES;
  // Sunshine keeps several captured frames alive while encoding.
  configuration.queueDepth = 8;

  SCKStreamOutput *output = [[[SCKStreamOutput alloc] init] autorelease];
  output.callback = frameCallback;
  dispatch_semaphore_t stopped = dispatch_semaphore_create(0);
  output.stopped = stopped;
  [stopped release];

  SCStream *stream = [[SCStream alloc] initWithFilter:filter configuration:configuration delegate:output];
  output.stream = stream;
  [stream release];
  [filter release];
  [configuration release];

  dispatch_queue_attr_t qos = dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INITIATED, DISPATCH_QUEUE_PRIORITY_HIGH);
  dispatch_queue_t queue = dispatch_queue_create("sckCaptureQueue", qos);
  NSError *error = nil;
  const BOOL added = [stream addStreamOutput:output type:SCStreamOutputTypeScreen sampleHandlerQueue:queue error:&error];
  [queue release];
  if (!added) {
    NSLog(@"ScreenCaptureKit cannot add a stream output: %@", error);
    return nil;
  }

  __block NSError *start_error = nil;
  dispatch_semaphore_t started = dispatch_semaphore_create(0);
  [stream startCaptureWithCompletionHandler:^(NSError *startError) {
    start_error = [startError retain];
    dispatch_semaphore_signal(started);
  }];
  const long timed_out = dispatch_semaphore_wait(started, dispatch_time(DISPATCH_TIME_NOW, SCK_REQUEST_TIMEOUT_NS));
  [started release];
  if (timed_out != 0 || start_error) {
    NSLog(@"ScreenCaptureKit cannot start capturing display %u: %@", self.displayID, start_error);
    [start_error release];
    output.finished = YES;
    return nil;
  }

  @synchronized(self) {
    [_outputs addObject:output];
  }
  return output.stopped;
}

@end
