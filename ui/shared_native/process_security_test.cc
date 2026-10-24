#include "process_security.h"

#include <cstdlib>
#include <iostream>
#include <string>

namespace {

int g_set_core_result = 0;
int g_set_dumpable_result = 0;
int g_read_core_result = 0;
std::uint64_t g_soft_limit = 0;
std::uint64_t g_hard_limit = 0;
int g_dumpable = 0;
int g_set_dumpable_value = -1;

int SetCoreLimit() {
  return g_set_core_result;
}

int SetDumpable(int value) {
  g_set_dumpable_value = value;
  return g_set_dumpable_result;
}

int ReadCoreLimits(std::uint64_t* soft_limit, std::uint64_t* hard_limit) {
  *soft_limit = g_soft_limit;
  *hard_limit = g_hard_limit;
  return g_read_core_result;
}

int ReadDumpable() {
  return g_dumpable;
}

void Expect(bool condition, const std::string& message) {
  if (!condition) {
    std::cerr << message << std::endl;
    std::exit(1);
  }
}

void Reset(bool required) {
  deploydash::ResetProcessSecurityForTesting();
  g_set_core_result = 0;
  g_set_dumpable_result = 0;
  g_read_core_result = 0;
  g_soft_limit = 0;
  g_hard_limit = 0;
  g_dumpable = 0;
  g_set_dumpable_value = -1;
  deploydash::SetLinuxProcessSecurityTestHooks({
      SetCoreLimit,
      SetDumpable,
      ReadCoreLimits,
      ReadDumpable,
  });
  if (required) {
    setenv("DEPLOYDASH_PROCESS_HARDENING_REQUIRED", "1", 1);
  } else {
    unsetenv("DEPLOYDASH_PROCESS_HARDENING_REQUIRED");
  }
}

}  // namespace

int main() {
  Reset(false);
  Expect(!deploydash::IsProcessHardeningRequired(),
         "Debug hardening should be optional.");
  setenv("DEPLOYDASH_PROCESS_HARDENING_REQUIRED", "unexpected", 1);
  Expect(!deploydash::IsProcessHardeningRequired(),
         "Only an explicit value of 1 should require hardening.");
  unsetenv("DEPLOYDASH_PROCESS_HARDENING_REQUIRED");
  Expect(deploydash::ApplyProcessHardening(nullptr),
         "Optional hardening should not fail.");
  Expect(deploydash::ApplyProcessHardening(nullptr),
         "A successful repeated hardening call should remain successful.");
  const std::string optional_diagnostics =
      deploydash::ProcessSecurityDiagnosticsJson();
  Expect(optional_diagnostics.find("\"required\":false") != std::string::npos,
         "Optional diagnostics should report required=false.");
  Expect(optional_diagnostics.find("\"effective\":true") != std::string::npos,
         "Optional diagnostics should remain effective.");

  Reset(true);
  std::string error;
  Expect(deploydash::ApplyProcessHardening(&error),
         "Configured hardening should succeed.");
  Expect(error.empty(), "Successful hardening should not report an error.");
  Expect(deploydash::ApplyProcessHardening(&error),
         "A repeated successful call should remain successful.");
  Expect(g_set_dumpable_value == 0,
         "Hardening should clear the Linux dumpable flag.");
  const std::string hardened_diagnostics =
      deploydash::ProcessSecurityDiagnosticsJson();
  Expect(hardened_diagnostics.find("\"platform\":\"linux\"") !=
             std::string::npos,
         "Diagnostics should identify Linux.");
  Expect(hardened_diagnostics.find("\"core_dumps_disabled\":true") !=
             std::string::npos,
         "Diagnostics should confirm disabled core dumps.");

  Reset(true);
  g_set_core_result = -1;
  g_set_dumpable_result = -1;
  Expect(!deploydash::ApplyProcessHardening(&error),
         "Rejected Linux controls should fail closed.");
  Expect(!deploydash::ApplyProcessHardening(&error),
         "A repeated failure should remain visible.");
  Expect(!deploydash::ApplyProcessHardening(nullptr),
         "Repeated failures should also support callers without error output.");
  Expect(error == "Unable to disable process core dumps.",
         "The first hardening failure should be returned.");
  const std::string failed_diagnostics =
      deploydash::ProcessSecurityDiagnosticsJson();
  Expect(failed_diagnostics.find("Unable to mark the process as non-dumpable.") !=
             std::string::npos,
         "Diagnostics should preserve every hardening failure.");

  Reset(true);
  g_read_core_result = -1;
  g_dumpable = 1;
  Expect(deploydash::ApplyProcessHardening(nullptr),
         "Apply success should be independent from diagnostic test hooks.");
  const std::string ineffective_diagnostics =
      deploydash::ProcessSecurityDiagnosticsJson();
  Expect(ineffective_diagnostics.find("\"effective\":false") !=
             std::string::npos,
         "Failed verification should report ineffective hardening.");
  Expect(ineffective_diagnostics.find("\"core_dumps_disabled\":false") !=
             std::string::npos,
         "Unreadable limits should not be reported as disabled.");

  Reset(true);
  g_soft_limit = 1;
  g_hard_limit = 0;
  Expect(deploydash::ApplyProcessHardening(nullptr),
         "Apply should still succeed with injected diagnostic state.");
  Expect(deploydash::ProcessSecurityDiagnosticsJson().find(
             "\"effective\":false") != std::string::npos,
         "A non-zero soft core limit must fail verification.");

  Reset(true);
  g_soft_limit = 0;
  g_hard_limit = 1;
  Expect(deploydash::ApplyProcessHardening(nullptr),
         "Apply should still succeed with injected diagnostic state.");
  Expect(deploydash::ProcessSecurityDiagnosticsJson().find(
             "\"effective\":false") != std::string::npos,
         "Both the soft and hard core limits must be zero.");

  Expect(deploydash::ProcessSecurityJsonEscapeForTesting(
             "\\\"\n\r\tplain") == "\\\\\\\"\\n\\r\\tplain",
         "Security diagnostics must JSON-escape control characters.");

  deploydash::ResetProcessSecurityForTesting();
  setenv("DEPLOYDASH_PROCESS_HARDENING_REQUIRED", "1", 1);
  Expect(deploydash::ApplyProcessHardening(nullptr),
         "The real Linux process controls should succeed.");
  Expect(deploydash::ProcessSecurityDiagnosticsJson().find(
             "\"effective\":true") != std::string::npos,
         "The real Linux controls should verify successfully.");
  unsetenv("DEPLOYDASH_PROCESS_HARDENING_REQUIRED");
  return 0;
}
