#include "process_security.h"

#include <cstdlib>
#include <sstream>
#include <string>
#include <vector>

#if defined(_WIN32)
#include <windows.h>
#elif defined(__linux__)
#include <sys/prctl.h>
#include <sys/resource.h>
#endif

namespace deploydash {
namespace {

bool g_hardening_attempted = false;
std::vector<std::string> g_errors;

#if defined(_WIN32)
bool g_dll_search_hardened = false;
std::vector<DLL_DIRECTORY_COOKIE> g_dll_directory_cookies;
#elif defined(__linux__)
int SetLinuxCoreLimit() {
  const rlimit core_limit{0, 0};
  return setrlimit(RLIMIT_CORE, &core_limit);
}

int SetLinuxDumpable(int value) {
  return prctl(PR_SET_DUMPABLE, static_cast<unsigned long>(value));
}

int ReadLinuxCoreLimits(std::uint64_t* soft_limit,
                        std::uint64_t* hard_limit) {
  rlimit core_limit{};
  const int result = getrlimit(RLIMIT_CORE, &core_limit);
  *soft_limit = static_cast<std::uint64_t>(core_limit.rlim_cur);
  *hard_limit = static_cast<std::uint64_t>(core_limit.rlim_max);
  return result;
}

int ReadLinuxDumpable() {
  return prctl(PR_GET_DUMPABLE);
}

LinuxProcessSecurityTestHooks g_linux_hooks{
    SetLinuxCoreLimit,
    SetLinuxDumpable,
    ReadLinuxCoreLimits,
    ReadLinuxDumpable,
};
#endif

std::string JsonEscape(const std::string& value) {
  std::ostringstream escaped;
  for (const char ch : value) {
    switch (ch) {
      case '\\':
        escaped << "\\\\";
        break;
      case '"':
        escaped << "\\\"";
        break;
      case '\n':
        escaped << "\\n";
        break;
      case '\r':
        escaped << "\\r";
        break;
      case '\t':
        escaped << "\\t";
        break;
      default:
        escaped << ch;
        break;
    }
  }
  return escaped.str();
}

std::string PlatformName() {
#if defined(_WIN32)
  return "windows";
#elif defined(__APPLE__)
  return "macos";
#elif defined(__linux__)
  return "linux";
#else
  return "unknown";
#endif
}

void AddError(const std::string& message) {
  g_errors.push_back(message);
}

#if defined(_WIN32)
std::wstring ExecutableDirectory() {
  std::wstring path(MAX_PATH, L'\0');
  while (true) {
    const DWORD copied = GetModuleFileNameW(
        nullptr, path.data(), static_cast<DWORD>(path.size()));
    if (copied == 0) {
      return {};
    }
    if (copied < path.size() - 1) {
      path.resize(copied);
      const size_t separator = path.find_last_of(L"/\\");
      return separator == std::wstring::npos ? std::wstring()
                                              : path.substr(0, separator);
    }
    path.resize(path.size() * 2);
  }
}

bool DirectoryExists(const std::wstring& path) {
  const DWORD attributes = GetFileAttributesW(path.c_str());
  return attributes != INVALID_FILE_ATTRIBUTES &&
         (attributes & FILE_ATTRIBUTE_DIRECTORY) != 0;
}

bool ConfigureWindowsDllSearch() {
  const DWORD flags = LOAD_LIBRARY_SEARCH_APPLICATION_DIR |
                      LOAD_LIBRARY_SEARCH_SYSTEM32 |
                      LOAD_LIBRARY_SEARCH_USER_DIRS;
  if (!SetDefaultDllDirectories(flags)) {
    AddError("SetDefaultDllDirectories failed with error " +
             std::to_string(GetLastError()));
    return false;
  }

  const std::wstring executable_dir = ExecutableDirectory();
  if (executable_dir.empty()) {
    AddError("Unable to resolve the application directory.");
    return false;
  }

  for (const std::wstring& directory :
       {executable_dir, executable_dir + L"\\DLLs"}) {
    if (!DirectoryExists(directory)) {
      continue;
    }
    const DLL_DIRECTORY_COOKIE cookie = AddDllDirectory(directory.c_str());
    if (cookie == nullptr) {
      AddError("AddDllDirectory failed with error " +
               std::to_string(GetLastError()));
      return false;
    }
    g_dll_directory_cookies.push_back(cookie);
  }

  g_dll_search_hardened = true;
  return true;
}

bool ConfigureWindowsImagePolicy() {
  PROCESS_MITIGATION_IMAGE_LOAD_POLICY policy{};
  policy.NoRemoteImages = 1;
  policy.NoLowMandatoryLabelImages = 1;
  policy.PreferSystem32Images = 1;
  if (!SetProcessMitigationPolicy(ProcessImageLoadPolicy, &policy,
                                  sizeof(policy))) {
    AddError("SetProcessMitigationPolicy failed with error " +
             std::to_string(GetLastError()));
    return false;
  }
  return true;
}

PROCESS_MITIGATION_IMAGE_LOAD_POLICY ReadWindowsImagePolicy() {
  PROCESS_MITIGATION_IMAGE_LOAD_POLICY policy{};
  if (!GetProcessMitigationPolicy(GetCurrentProcess(), ProcessImageLoadPolicy,
                                  &policy, sizeof(policy))) {
    AddError("GetProcessMitigationPolicy failed with error " +
             std::to_string(GetLastError()));
  }
  return policy;
}
#endif

}  // namespace

bool IsProcessHardeningRequired() {
#if defined(DEPLOYDASH_RELEASE_HARDENING)
  return true;
#else
  const char* required = std::getenv("DEPLOYDASH_PROCESS_HARDENING_REQUIRED");
  return required != nullptr && std::string(required) == "1";
#endif
}

bool ApplyProcessHardening(std::string* error_message) {
  if (g_hardening_attempted) {
    if (error_message != nullptr && !g_errors.empty()) {
      *error_message = g_errors.front();
    }
    return g_errors.empty();
  }
  g_hardening_attempted = true;
  g_errors.clear();

  if (!IsProcessHardeningRequired()) {
    return true;
  }

#if defined(_WIN32)
  SetEnvironmentVariableW(L"DEPLOYDASH_PROCESS_HARDENING_REQUIRED", L"1");
  ConfigureWindowsDllSearch();
  ConfigureWindowsImagePolicy();
#elif defined(__linux__)
  setenv("DEPLOYDASH_PROCESS_HARDENING_REQUIRED", "1", 1);
  if (g_linux_hooks.set_core_limit() != 0) {
    AddError("Unable to disable process core dumps.");
  }
  if (g_linux_hooks.set_dumpable(0) != 0) {
    AddError("Unable to mark the process as non-dumpable.");
  }
#elif defined(__APPLE__)
  setenv("DEPLOYDASH_PROCESS_HARDENING_REQUIRED", "1", 1);
#else
  AddError("Process hardening is unsupported on this platform.");
#endif

  if (error_message != nullptr && !g_errors.empty()) {
    *error_message = g_errors.front();
  }
  return g_errors.empty();
}

std::string ProcessSecurityDiagnosticsJson() {
  const bool required = IsProcessHardeningRequired();
  bool effective = !required;
  std::ostringstream controls;

#if defined(_WIN32)
  const PROCESS_MITIGATION_IMAGE_LOAD_POLICY policy = ReadWindowsImagePolicy();
  effective = !required ||
              (g_dll_search_hardened && policy.NoRemoteImages != 0 &&
               policy.NoLowMandatoryLabelImages != 0 &&
               policy.PreferSystem32Images != 0);
  controls << "{\"dll_search_hardened\":"
           << (g_dll_search_hardened ? "true" : "false")
           << ",\"no_remote_images\":"
           << (policy.NoRemoteImages != 0 ? "true" : "false")
           << ",\"no_low_integrity_images\":"
           << (policy.NoLowMandatoryLabelImages != 0 ? "true" : "false")
           << ",\"prefer_system32_images\":"
           << (policy.PreferSystem32Images != 0 ? "true" : "false") << "}";
#elif defined(__linux__)
  std::uint64_t soft_limit = 1;
  std::uint64_t hard_limit = 1;
  const bool core_limit_read =
      g_linux_hooks.read_core_limits(&soft_limit, &hard_limit) == 0;
  const int dumpable = g_linux_hooks.read_dumpable();
  const bool core_disabled =
      core_limit_read && soft_limit == 0 && hard_limit == 0;
  effective = !required || (dumpable == 0 && core_disabled);
  controls << "{\"dumpable\":" << dumpable
           << ",\"core_dumps_disabled\":"
           << (core_disabled ? "true" : "false") << "}";
#elif defined(__APPLE__)
  effective = true;
  controls << "{\"hardened_runtime_artifact_verification\":"
           << (required ? "true" : "false") << "}";
#else
  controls << "{}";
#endif

  std::ostringstream json;
  json << "{\"required\":" << (required ? "true" : "false")
       << ",\"effective\":" << (effective ? "true" : "false")
       << ",\"platform\":\"" << JsonEscape(PlatformName()) << "\""
       << ",\"controls\":" << controls.str() << ",\"errors\":[";
  for (size_t index = 0; index < g_errors.size(); ++index) {
    if (index > 0) {
      json << ",";
    }
    json << "\"" << JsonEscape(g_errors[index]) << "\"";
  }
  json << "]}";
  return json.str();
}

#if defined(DEPLOYDASH_PROCESS_SECURITY_TESTING) && defined(__linux__)
void SetLinuxProcessSecurityTestHooks(
    const LinuxProcessSecurityTestHooks& hooks) {
  g_linux_hooks = hooks;
}

void ResetProcessSecurityForTesting() {
  g_hardening_attempted = false;
  g_errors.clear();
  g_linux_hooks = {
      SetLinuxCoreLimit,
      SetLinuxDumpable,
      ReadLinuxCoreLimits,
      ReadLinuxDumpable,
  };
}

std::string ProcessSecurityJsonEscapeForTesting(const std::string& value) {
  return JsonEscape(value);
}
#endif

}  // namespace deploydash
