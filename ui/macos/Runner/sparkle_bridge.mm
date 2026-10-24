#import <Cocoa/Cocoa.h>
#import <objc/message.h>
#import <objc/runtime.h>

#include <cstdio>
#include <cstring>

#include "sparkle_bridge.h"

namespace {

id g_updater_controller = nil;

void write_error(
    const char* message,
    char* error_buffer,
    size_t error_buffer_size) {
  if (error_buffer == nullptr || error_buffer_size == 0) {
    return;
  }
  std::snprintf(error_buffer, error_buffer_size, "%s", message);
}

bool configure_and_check(NSString** failure) {
  Class controller_class = NSClassFromString(@"SPUStandardUpdaterController");
  if (controller_class == Nil) {
    *failure = @"Sparkle could not be loaded from this application bundle.";
    return false;
  }

  if (g_updater_controller == nil) {
    using Allocate = id (*)(id, SEL);
    using Initialize = id (*)(id, SEL, BOOL, id, id);
    const auto allocate = reinterpret_cast<Allocate>(objc_msgSend);
    const auto initialize = reinterpret_cast<Initialize>(objc_msgSend);
    id allocated = allocate(controller_class, sel_registerName("alloc"));
    g_updater_controller = initialize(
        allocated,
        sel_registerName(
            "initWithStartingUpdater:updaterDelegate:userDriverDelegate:"),
        YES,
        nil,
        nil);
    if (g_updater_controller == nil) {
      *failure = @"Sparkle could not initialize the update service.";
      return false;
    }
  }

  using CheckForUpdates = void (*)(id, SEL, id);
  const auto check_for_updates =
      reinterpret_cast<CheckForUpdates>(objc_msgSend);
  check_for_updates(
      g_updater_controller,
      sel_registerName("checkForUpdates:"),
      nil);
  return true;
}

}  // namespace

int deploydash_sparkle_check_for_updates(
    const char* expected_feed_url,
    char* error_buffer,
    size_t error_buffer_size) {
  @autoreleasepool {
    if (expected_feed_url == nullptr || std::strlen(expected_feed_url) == 0) {
      write_error(
          "The signed update response did not provide a Sparkle feed URL.",
          error_buffer,
          error_buffer_size);
      return 0;
    }

    NSString* configured_feed =
        [[NSBundle mainBundle] objectForInfoDictionaryKey:@"SUFeedURL"];
    NSString* expected_feed = [NSString stringWithUTF8String:expected_feed_url];
    if (configured_feed == nil || ![configured_feed isEqualToString:expected_feed]) {
      write_error(
          "The signed update response does not match the bundled Sparkle feed.",
          error_buffer,
          error_buffer_size);
      return 0;
    }

    NSString* framework_path = [[NSBundle mainBundle].privateFrameworksPath
        stringByAppendingPathComponent:@"Sparkle.framework"];
    NSBundle* framework_bundle = [NSBundle bundleWithPath:framework_path];
    NSError* load_error = nil;
    if (framework_bundle == nil ||
        ![framework_bundle loadAndReturnError:&load_error]) {
      NSString* message = load_error.localizedDescription ?: @"unknown error";
      NSString* failure = [NSString stringWithFormat:
          @"Sparkle is unavailable in this Deploy Dash distribution: %@",
          message];
      write_error(failure.UTF8String, error_buffer, error_buffer_size);
      return 0;
    }

    __block bool succeeded = false;
    __block NSString* failure = nil;
    void (^check_block)(void) = ^{
      succeeded = configure_and_check(&failure);
    };
    if ([NSThread isMainThread]) {
      check_block();
    } else {
      dispatch_sync(dispatch_get_main_queue(), check_block);
    }
    if (!succeeded) {
      write_error(
          (failure ?: @"Sparkle could not start the update check.").UTF8String,
          error_buffer,
          error_buffer_size);
      return 0;
    }
    return 1;
  }
}
