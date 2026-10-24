#ifndef DEPLOYDASH_PROCESS_SECURITY_H_
#define DEPLOYDASH_PROCESS_SECURITY_H_

#include <cstdint>
#include <string>

namespace deploydash {

bool IsProcessHardeningRequired();

bool ApplyProcessHardening(std::string* error_message);

std::string ProcessSecurityDiagnosticsJson();

#if defined(__linux__)
struct LinuxProcessSecurityTestHooks {
  int (*set_core_limit)();
  int (*set_dumpable)(int value);
  int (*read_core_limits)(std::uint64_t* soft_limit,
                          std::uint64_t* hard_limit);
  int (*read_dumpable)();
};

#if defined(DEPLOYDASH_PROCESS_SECURITY_TESTING)
void SetLinuxProcessSecurityTestHooks(
    const LinuxProcessSecurityTestHooks& hooks);
void ResetProcessSecurityForTesting();
std::string ProcessSecurityJsonEscapeForTesting(const std::string& value);
#endif
#endif

}  // namespace deploydash

#endif  // DEPLOYDASH_PROCESS_SECURITY_H_
