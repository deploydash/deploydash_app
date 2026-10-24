#ifndef DEPLOYDASH_SPARKLE_BRIDGE_H_
#define DEPLOYDASH_SPARKLE_BRIDGE_H_

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

int deploydash_sparkle_check_for_updates(
    const char* expected_feed_url,
    char* error_buffer,
    size_t error_buffer_size);

#ifdef __cplusplus
}
#endif

#endif  // DEPLOYDASH_SPARKLE_BRIDGE_H_
