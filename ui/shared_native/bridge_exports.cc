#include <mutex>
#include <string>
#include <vector>
#include <sstream>
#include <cstdlib>
#include <cstring>
#include <iostream>

#include "process_security.h"

#if defined(_WIN32)
#include <windows.h>
#else
#include <dlfcn.h>
#include <limits.h>
#include <sys/stat.h>
#include <unistd.h>
#if defined(__APPLE__)
#include <mach-o/dyld.h>
#endif
#endif

struct PyObject;
typedef int PyGILState_STATE;

typedef void (*Py_SetPythonHomeFn)(const wchar_t*);
typedef void (*Py_InitializeFn)(void);
typedef int (*Py_IsInitializedFn)(void);
typedef PyGILState_STATE (*PyGILState_EnsureFn)(void);
typedef void (*PyGILState_ReleaseFn)(PyGILState_STATE);
typedef PyObject* (*PySys_GetObjectFn)(const char*);
typedef PyObject* (*PyUnicode_FromStringFn)(const char*);
typedef int (*PyList_InsertFn)(PyObject*, long, PyObject*);
typedef int (*PyRun_SimpleStringFn)(const char*);
typedef PyObject* (*PyImport_ImportModuleFn)(const char*);
typedef PyObject* (*PyObject_GetAttrStringFn)(PyObject*, const char*);
typedef int (*PyCallable_CheckFn)(PyObject*);
typedef PyObject* (*PyObject_CallFunctionObjArgsFn)(PyObject*, ...);
typedef PyObject* (*PyObject_StrFn)(PyObject*);
typedef const char* (*PyUnicode_AsUTF8Fn)(PyObject*);
typedef PyObject* (*PyObject_CallFunctionFn)(PyObject*, const char*, ...);
typedef void (*PyErr_ClearFn)(void);
typedef void (*PyErr_FetchFn)(PyObject**, PyObject**, PyObject**);
typedef void (*PyErr_NormalizeExceptionFn)(PyObject**, PyObject**, PyObject**);
typedef void (*Py_DecRefFn)(PyObject*);

#if defined(_WIN32)
#define BRIDGE_EXPORT extern "C" __declspec(dllexport)
#define BRIDGE_USED
#else
#define BRIDGE_EXPORT extern "C" __attribute__((visibility("default")))
#define BRIDGE_USED __attribute__((used))
#endif

namespace {

struct PythonApi {
  Py_SetPythonHomeFn Py_SetPythonHome = nullptr;
  Py_InitializeFn Py_Initialize = nullptr;
  Py_IsInitializedFn Py_IsInitialized = nullptr;
  PyGILState_EnsureFn PyGILState_Ensure = nullptr;
  PyGILState_ReleaseFn PyGILState_Release = nullptr;
  PySys_GetObjectFn PySys_GetObject = nullptr;
  PyUnicode_FromStringFn PyUnicode_FromString = nullptr;
  PyList_InsertFn PyList_Insert = nullptr;
  PyRun_SimpleStringFn PyRun_SimpleString = nullptr;
  PyImport_ImportModuleFn PyImport_ImportModule = nullptr;
  PyObject_GetAttrStringFn PyObject_GetAttrString = nullptr;
  PyCallable_CheckFn PyCallable_Check = nullptr;
  PyObject_CallFunctionObjArgsFn PyObject_CallFunctionObjArgs = nullptr;
  PyObject_StrFn PyObject_Str = nullptr;
  PyUnicode_AsUTF8Fn PyUnicode_AsUTF8 = nullptr;
  PyObject_CallFunctionFn PyObject_CallFunction = nullptr;
  PyErr_ClearFn PyErr_Clear = nullptr;
  PyErr_FetchFn PyErr_Fetch = nullptr;
  PyErr_NormalizeExceptionFn PyErr_NormalizeException = nullptr;
  Py_DecRefFn Py_DecRef = nullptr;
};

struct RuntimeLayout {
  std::string exe_dir;
  std::string libpython_path;
  std::string python_home;
  std::vector<std::string> search_paths;
};

PythonApi g_python_api;
std::mutex g_python_mutex;
bool g_python_initialized = false;
bool g_python_loaded = false;
std::wstring g_python_home_storage;
std::string g_runtime_status = "uninitialized";
std::string g_runtime_message = "Embedded Python runtime not initialized yet.";
RuntimeLayout g_last_runtime_layout;

#if defined(_WIN32)
HMODULE g_python_library = nullptr;
#else
void* g_python_library = nullptr;
#endif

std::string path_separator() {
#if defined(_WIN32)
  return "\\";
#else
  return "/";
#endif
}

std::string join_path(const std::string& left, const std::string& right) {
  if (left.empty()) {
    return right;
  }
  if (right.empty()) {
    return left;
  }
  const std::string separator = path_separator();
  if (left.back() == separator[0]) {
    return left + right;
  }
  return left + separator + right;
}

bool file_exists(const std::string& path) {
#if defined(_WIN32)
  const DWORD attributes = GetFileAttributesA(path.c_str());
  return attributes != INVALID_FILE_ATTRIBUTES;
#else
  struct stat buffer;
  return stat(path.c_str(), &buffer) == 0;
#endif
}

std::string json_escape(const std::string& value) {
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

char* dup_bridge_string(const std::string& value) {
  const size_t byte_count = value.size() + 1;
  char* copy = static_cast<char*>(std::malloc(byte_count));
  if (copy == nullptr) {
    return nullptr;
  }
  std::memcpy(copy, value.c_str(), byte_count);
  return copy;
}

char* dup_error_json(const std::string& message) {
  const std::string payload =
      std::string("{\"status\":\"error\",\"msg\":\"") +
      json_escape(message) + "\"}";
  return dup_bridge_string(payload);
}

const char* platform_name() {
#if defined(_WIN32)
  return "windows";
#elif defined(__APPLE__)
  return "macos";
#else
  return "linux";
#endif
}

#if defined(_WIN32)
std::string utf8_from_wide(const std::wstring& value) {
  if (value.empty()) {
    return {};
  }
  const int size_needed = WideCharToMultiByte(
      CP_UTF8,
      0,
      value.c_str(),
      static_cast<int>(value.size()),
      nullptr,
      0,
      nullptr,
      nullptr);
  if (size_needed <= 0) {
    return {};
  }
  std::string result(static_cast<size_t>(size_needed), '\0');
  WideCharToMultiByte(
      CP_UTF8,
      0,
      value.c_str(),
      static_cast<int>(value.size()),
      &result[0],
      size_needed,
      nullptr,
      nullptr);
  return result;
}

std::wstring wide_from_utf8(const std::string& value) {
  if (value.empty()) {
    return {};
  }
  const int size_needed = MultiByteToWideChar(
      CP_UTF8,
      0,
      value.c_str(),
      static_cast<int>(value.size()),
      nullptr,
      0);
  if (size_needed <= 0) {
    return {};
  }
  std::wstring result(static_cast<size_t>(size_needed), L'\0');
  MultiByteToWideChar(
      CP_UTF8,
      0,
      value.c_str(),
      static_cast<int>(value.size()),
      &result[0],
      size_needed);
  return result;
}
#endif

std::string get_executable_path() {
#if defined(_WIN32)
  std::wstring buffer(MAX_PATH, L'\0');
  DWORD copied = 0;
  while (true) {
    copied = GetModuleFileNameW(nullptr, &buffer[0], static_cast<DWORD>(buffer.size()));
    if (copied == 0) {
      return {};
    }
    if (copied < buffer.size() - 1) {
      buffer.resize(copied);
      return utf8_from_wide(buffer);
    }
    buffer.resize(buffer.size() * 2);
  }
#elif defined(__APPLE__)
  uint32_t size = 0;
  _NSGetExecutablePath(nullptr, &size);
  std::string buffer(static_cast<size_t>(size), '\0');
  if (_NSGetExecutablePath(&buffer[0], &size) != 0) {
    return {};
  }
  buffer.resize(std::strlen(buffer.c_str()));
  return buffer;
#else
  char buffer[PATH_MAX];
  const ssize_t count = readlink("/proc/self/exe", buffer, PATH_MAX);
  if (count <= 0) {
    return {};
  }
  return std::string(buffer, static_cast<size_t>(count));
#endif
}

std::string dirname(const std::string& path) {
  const auto pos = path.find_last_of("/\\");
  if (pos == std::string::npos) {
    return {};
  }
  return path.substr(0, pos);
}

template <typename T>
bool resolve_symbol(T& target, const char* name) {
#if defined(_WIN32)
  FARPROC symbol = GetProcAddress(g_python_library, name);
  if (!symbol) {
    std::cerr << "Missing Python symbol: " << name << std::endl;
    return false;
  }
  target = reinterpret_cast<T>(symbol);
#else
  void* symbol = dlsym(g_python_library, name);
  if (!symbol) {
    std::cerr << "Missing Python symbol: " << name << std::endl;
    return false;
  }
  target = reinterpret_cast<T>(symbol);
#endif
  return true;
}

std::vector<std::string> candidate_site_packages(const std::string& exe_dir) {
  return {
      join_path(join_path(exe_dir, "data"), "py/site-packages"),
      join_path(dirname(exe_dir), "data/py/site-packages"),
      join_path(dirname(dirname(exe_dir)), "Resources/data/py/site-packages"),
      join_path(dirname(exe_dir), "Resources/data/py/site-packages"),
      "./data/py/site-packages",
      "./orchestrator/runtime_bundle/py/site-packages",
  };
}

bool backend_runtime_present(const std::vector<std::string>& search_paths) {
  for (const auto& search_path : search_paths) {
    if (file_exists(join_path(search_path, "orchestrator/__init__.py")) &&
        file_exists(join_path(search_path, "orchestrator/task_runtime.py"))) {
      return true;
    }
  }
  return false;
}

std::string runtime_diagnostics_json_locked() {
  std::ostringstream json;
  json << "{";
  json << "\"status\":\"" << json_escape(g_runtime_status) << "\",";
  json << "\"msg\":\"" << json_escape(g_runtime_message) << "\",";
  json << "\"platform\":\"" << json_escape(platform_name()) << "\",";
  json << "\"exe_dir\":\"" << json_escape(g_last_runtime_layout.exe_dir) << "\",";
  json << "\"libpython_path\":\""
       << json_escape(g_last_runtime_layout.libpython_path) << "\",";
  json << "\"python_home\":\"" << json_escape(g_last_runtime_layout.python_home)
       << "\",";
  json << "\"backend_runtime_present\":"
       << (backend_runtime_present(g_last_runtime_layout.search_paths) ? "true"
                                                                       : "false")
       << ",";
  json << "\"search_paths\":[";
  for (size_t index = 0; index < g_last_runtime_layout.search_paths.size();
       ++index) {
    if (index > 0) {
      json << ",";
    }
    json << "\"" << json_escape(g_last_runtime_layout.search_paths[index]) << "\"";
  }
  json << "],\"process_security\":"
       << deploydash::ProcessSecurityDiagnosticsJson() << "}";
  return json.str();
}

void decref(PyObject* value);

std::string consume_python_exception() {
  if (g_python_api.PyErr_Fetch == nullptr ||
      g_python_api.PyErr_NormalizeException == nullptr ||
      g_python_api.PyObject_Str == nullptr ||
      g_python_api.PyUnicode_AsUTF8 == nullptr) {
    return {};
  }

  PyObject* type = nullptr;
  PyObject* value = nullptr;
  PyObject* traceback = nullptr;
  g_python_api.PyErr_Fetch(&type, &value, &traceback);
  if (type == nullptr && value == nullptr && traceback == nullptr) {
    return {};
  }

  g_python_api.PyErr_NormalizeException(&type, &value, &traceback);

  auto to_string = [](PyObject* object) -> std::string {
    if (object == nullptr || g_python_api.PyObject_Str == nullptr ||
        g_python_api.PyUnicode_AsUTF8 == nullptr) {
      return {};
    }
    PyObject* as_string = g_python_api.PyObject_Str(object);
    if (as_string == nullptr) {
      return {};
    }
    const char* utf8 = g_python_api.PyUnicode_AsUTF8(as_string);
    const std::string result = utf8 != nullptr ? utf8 : "";
    decref(as_string);
    return result;
  };

  const std::string type_text = to_string(type);
  const std::string value_text = to_string(value);

  decref(type);
  decref(value);
  decref(traceback);
  if (g_python_api.PyErr_Clear != nullptr) {
    g_python_api.PyErr_Clear();
  }

  if (!type_text.empty() && !value_text.empty()) {
    return type_text + ": " + value_text;
  }
  if (!value_text.empty()) {
    return value_text;
  }
  return type_text;
}

void set_runtime_status_locked(
    const std::string& status,
    const std::string& message) {
  g_runtime_status = status;
  g_runtime_message = message;
}

void log_runtime_layout(const RuntimeLayout& layout) {
  std::cerr << "Deploy Dash bridge runtime layout: "
            << "platform=" << platform_name()
            << ", exe_dir=" << layout.exe_dir
            << ", libpython=" << layout.libpython_path
            << ", python_home=" << layout.python_home
            << ", backend_runtime_present="
            << (backend_runtime_present(layout.search_paths) ? "true" : "false")
            << std::endl;
}

RuntimeLayout resolve_runtime_layout() {
  RuntimeLayout layout;
  layout.exe_dir = dirname(get_executable_path());

#if defined(_WIN32)
  const std::vector<std::pair<std::string, std::string>> candidates = {
      {join_path(layout.exe_dir, "python313.dll"), layout.exe_dir},
      {join_path(join_path(layout.exe_dir, "python"), "python313.dll"),
       join_path(layout.exe_dir, "python")},
  };
#elif defined(__APPLE__)
  const std::string frameworks_dir = join_path(dirname(layout.exe_dir), "Frameworks");
  const std::string resources_dir = join_path(dirname(layout.exe_dir), "Resources");
  const std::vector<std::pair<std::string, std::string>> candidates = {
      {join_path(frameworks_dir, "Python.framework/Versions/Current/Python"),
       join_path(frameworks_dir, "Python.framework/Versions/Current")},
      {join_path(frameworks_dir, "Python.framework/Versions/3.13/Python"),
       join_path(frameworks_dir, "Python.framework/Versions/3.13")},
      {join_path(frameworks_dir, "libpython3.13.dylib"), frameworks_dir},
      {join_path(resources_dir, "python/lib/libpython3.13.dylib"),
       join_path(resources_dir, "python")},
      {"libpython3.13.dylib", layout.exe_dir},
  };
#else
  const std::vector<std::pair<std::string, std::string>> candidates = {
      {join_path(layout.exe_dir, "libpython3.13.so.1.0"), layout.exe_dir},
      {join_path(join_path(layout.exe_dir, "lib"), "libpython3.13.so.1.0"),
       layout.exe_dir},
      {"libpython3.13.so.1.0", layout.exe_dir},
      {"libpython3.13.so", layout.exe_dir},
  };
#endif

  for (const auto& candidate : candidates) {
    if (candidate.first.find("libpython") != std::string::npos ||
        candidate.first.find("python313") != std::string::npos ||
        candidate.first.find("Python.framework") != std::string::npos) {
      if (!candidate.first.empty() && !file_exists(candidate.first) &&
          candidate.first.find(path_separator()) != std::string::npos) {
        continue;
      }
    }
    layout.libpython_path = candidate.first;
    layout.python_home = candidate.second;
    break;
  }

  layout.search_paths = candidate_site_packages(layout.exe_dir);
  if (!layout.python_home.empty()) {
#if defined(_WIN32)
    layout.search_paths.push_back(join_path(layout.python_home, "Lib"));
    layout.search_paths.push_back(join_path(layout.python_home, "DLLs"));
    layout.search_paths.push_back(join_path(layout.python_home, "Lib/site-packages"));
#else
    layout.search_paths.push_back(join_path(layout.python_home, "lib/python3.13"));
    layout.search_paths.push_back(join_path(layout.python_home, "lib/python3.13/lib-dynload"));
    layout.search_paths.push_back(join_path(layout.python_home, "lib/python3.13/site-packages"));
#endif
  }
  return layout;
}

bool load_python_library_locked(const RuntimeLayout& layout) {
  if (g_python_loaded) {
    return true;
  }

#if defined(_WIN32)
  if (!layout.libpython_path.empty()) {
    const std::wstring wide_path = wide_from_utf8(layout.libpython_path);
    if (!wide_path.empty()) {
      g_python_library = LoadLibraryExW(
          wide_path.c_str(), nullptr,
          LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR |
              LOAD_LIBRARY_SEARCH_APPLICATION_DIR |
              LOAD_LIBRARY_SEARCH_SYSTEM32 |
              LOAD_LIBRARY_SEARCH_USER_DIRS);
    }
  }
#else
  if (!layout.libpython_path.empty()) {
    g_python_library = dlopen(layout.libpython_path.c_str(), RTLD_LAZY | RTLD_GLOBAL);
  }
  if (!g_python_library && !layout.libpython_path.empty() &&
      layout.libpython_path.find(path_separator()) == std::string::npos) {
    g_python_library = dlopen(layout.libpython_path.c_str(), RTLD_LAZY | RTLD_GLOBAL);
  }
#endif

  if (!g_python_library) {
    set_runtime_status_locked(
        "error",
        std::string("Failed to load embedded Python runtime from ") +
            (layout.libpython_path.empty() ? "<default loader path>"
                                           : layout.libpython_path));
    std::cerr << g_runtime_message << std::endl;
    return false;
  }

  const bool resolved =
      resolve_symbol(g_python_api.Py_SetPythonHome, "Py_SetPythonHome") &&
      resolve_symbol(g_python_api.Py_Initialize, "Py_Initialize") &&
      resolve_symbol(g_python_api.Py_IsInitialized, "Py_IsInitialized") &&
      resolve_symbol(g_python_api.PyGILState_Ensure, "PyGILState_Ensure") &&
      resolve_symbol(g_python_api.PyGILState_Release, "PyGILState_Release") &&
      resolve_symbol(g_python_api.PySys_GetObject, "PySys_GetObject") &&
      resolve_symbol(g_python_api.PyUnicode_FromString, "PyUnicode_FromString") &&
      resolve_symbol(g_python_api.PyList_Insert, "PyList_Insert") &&
      resolve_symbol(g_python_api.PyRun_SimpleString, "PyRun_SimpleString") &&
      resolve_symbol(g_python_api.PyImport_ImportModule, "PyImport_ImportModule") &&
      resolve_symbol(g_python_api.PyObject_GetAttrString, "PyObject_GetAttrString") &&
      resolve_symbol(g_python_api.PyCallable_Check, "PyCallable_Check") &&
      resolve_symbol(g_python_api.PyObject_CallFunctionObjArgs, "PyObject_CallFunctionObjArgs") &&
      resolve_symbol(g_python_api.PyObject_Str, "PyObject_Str") &&
      resolve_symbol(g_python_api.PyUnicode_AsUTF8, "PyUnicode_AsUTF8") &&
      resolve_symbol(g_python_api.PyObject_CallFunction, "PyObject_CallFunction") &&
      resolve_symbol(g_python_api.PyErr_Clear, "PyErr_Clear") &&
      resolve_symbol(g_python_api.PyErr_Fetch, "PyErr_Fetch") &&
      resolve_symbol(g_python_api.PyErr_NormalizeException, "PyErr_NormalizeException") &&
      resolve_symbol(g_python_api.Py_DecRef, "Py_DecRef");

  g_python_loaded = resolved;
  if (!resolved) {
    set_runtime_status_locked(
        "error", "Embedded Python runtime loaded but required symbols were missing.");
  }
  return resolved;
}

void decref(PyObject* value) {
  if (value != nullptr && g_python_api.Py_DecRef != nullptr) {
    g_python_api.Py_DecRef(value);
  }
}

void add_search_path(PyObject* sys_path, const std::string& path) {
  if (!file_exists(path)) {
    return;
  }
  PyObject* py_path = g_python_api.PyUnicode_FromString(path.c_str());
  if (py_path == nullptr) {
    return;
  }
  g_python_api.PyList_Insert(sys_path, 0, py_path);
  decref(py_path);
}

void ensure_python_initialized() {
  std::lock_guard<std::mutex> lock(g_python_mutex);
  if (g_python_initialized) {
    return;
  }

  std::string hardening_error;
  if (!deploydash::ApplyProcessHardening(&hardening_error)) {
    set_runtime_status_locked(
        "error", "Required process security controls could not be applied: " +
                     hardening_error);
    return;
  }

  const RuntimeLayout layout = resolve_runtime_layout();
  g_last_runtime_layout = layout;
  set_runtime_status_locked("loading", "Initializing embedded Python runtime.");
  log_runtime_layout(layout);
  if (!load_python_library_locked(layout)) {
    return;
  }

  if (!layout.python_home.empty()) {
#if defined(_WIN32)
    g_python_home_storage = wide_from_utf8(layout.python_home);
#else
    g_python_home_storage = std::wstring(
        layout.python_home.begin(),
        layout.python_home.end());
#endif
    g_python_api.Py_SetPythonHome(g_python_home_storage.c_str());
  }

  g_python_api.Py_Initialize();
  if (!g_python_api.Py_IsInitialized()) {
    set_runtime_status_locked(
        "error", "Embedded Python failed to initialize.");
    std::cerr << g_runtime_message << std::endl;
    return;
  }
  g_python_initialized = true;

  PyObject* sys_path = g_python_api.PySys_GetObject("path");
  if (sys_path != nullptr) {
    for (const auto& candidate : layout.search_paths) {
      add_search_path(sys_path, candidate);
    }
  }

  PyObject* runtime_module =
      g_python_api.PyImport_ImportModule("orchestrator.task_runtime");
  if (runtime_module == nullptr) {
    const std::string import_error = consume_python_exception();
    std::string message =
        "Embedded Python initialized but orchestrator.task_runtime could not "
        "be imported from the bundled runtime.";
    if (!import_error.empty()) {
      message += " Python import error: " + import_error;
    }
    set_runtime_status_locked(
        "error", message);
    std::cerr << g_runtime_message << std::endl;
    return;
  }
  decref(runtime_module);

  set_runtime_status_locked(
      "ready",
      "Embedded Python runtime loaded and orchestrator.task_runtime imported successfully.");
}

char* call_python_string_arg_function(
    const char* module_name,
    const char* function_name,
    const char* string_arg) {
  ensure_python_initialized();
  if (g_runtime_status == "error") {
    return dup_error_json(g_runtime_message);
  }
  if (!g_python_initialized) {
    return dup_error_json("Python runtime unavailable");
  }

  const PyGILState_STATE gstate = g_python_api.PyGILState_Ensure();

  PyObject* py_input_str = g_python_api.PyUnicode_FromString(string_arg);
  if (!py_input_str) {
    g_python_api.PyGILState_Release(gstate);
    return dup_error_json("Failed to convert input string");
  }

  PyObject* py_module = g_python_api.PyImport_ImportModule(module_name);
  if (!py_module) {
    const std::string import_error = consume_python_exception();
    decref(py_input_str);
    g_python_api.PyGILState_Release(gstate);
    if (!import_error.empty()) {
      return dup_error_json("Failed to import Python module: " + import_error);
    }
    return dup_error_json("Failed to import Python module");
  }

  PyObject* handle_func = g_python_api.PyObject_GetAttrString(py_module, function_name);
  if (!handle_func || !g_python_api.PyCallable_Check(handle_func)) {
    decref(handle_func);
    decref(py_module);
    decref(py_input_str);
    g_python_api.PyGILState_Release(gstate);
    return dup_error_json("Python function not found");
  }

  PyObject* py_result_str =
      g_python_api.PyObject_CallFunctionObjArgs(handle_func, py_input_str, NULL);
  char* result_str = nullptr;
  if (py_result_str) {
    const char* temp_res = g_python_api.PyUnicode_AsUTF8(py_result_str);
    result_str = dup_bridge_string(
        temp_res ? temp_res : "{\"status\":\"error\",\"msg\":\"Invalid Python return\"}");
    decref(py_result_str);
  } else {
    const std::string python_error = consume_python_exception();
    if (!python_error.empty()) {
      result_str = dup_error_json("Python execution failed: " + python_error);
    } else {
      result_str = dup_error_json("Python execution failed");
    }
  }

  decref(handle_func);
  decref(py_module);
  decref(py_input_str);
  g_python_api.PyGILState_Release(gstate);
  return result_str;
}

char* call_python_int_args_function(
    const char* module_name,
    const char* function_name,
    int arg1,
    int arg2) {
  ensure_python_initialized();
  if (g_runtime_status == "error") {
    return dup_error_json(g_runtime_message);
  }
  if (!g_python_initialized) {
    return dup_error_json("Python runtime unavailable");
  }

  const PyGILState_STATE gstate = g_python_api.PyGILState_Ensure();
  PyObject* py_module = g_python_api.PyImport_ImportModule(module_name);
  if (!py_module) {
    const std::string import_error = consume_python_exception();
    g_python_api.PyGILState_Release(gstate);
    if (!import_error.empty()) {
      return dup_error_json("Failed to import Python module: " + import_error);
    }
    return dup_error_json("Failed to import Python module");
  }

  PyObject* handle_func = g_python_api.PyObject_GetAttrString(py_module, function_name);
  if (!handle_func || !g_python_api.PyCallable_Check(handle_func)) {
    decref(handle_func);
    decref(py_module);
    g_python_api.PyGILState_Release(gstate);
    return dup_error_json("Python function not found");
  }

  PyObject* py_result_str = g_python_api.PyObject_CallFunction(handle_func, "ii", arg1, arg2);
  char* result_str = nullptr;
  if (py_result_str) {
    const char* temp_res = g_python_api.PyUnicode_AsUTF8(py_result_str);
    result_str = dup_bridge_string(
        temp_res ? temp_res : "{\"status\":\"error\",\"msg\":\"Invalid Python return\"}");
    decref(py_result_str);
  } else {
    const std::string python_error = consume_python_exception();
    if (!python_error.empty()) {
      result_str = dup_error_json("Python execution failed: " + python_error);
    } else {
      result_str = dup_error_json("Python execution failed");
    }
  }

  decref(handle_func);
  decref(py_module);
  g_python_api.PyGILState_Release(gstate);
  return result_str;
}

char* call_python_int_arg_function(
    const char* module_name,
    const char* function_name,
    int arg1) {
  ensure_python_initialized();
  if (g_runtime_status == "error") {
    return dup_error_json(g_runtime_message);
  }
  if (!g_python_initialized) {
    return dup_error_json("Python runtime unavailable");
  }

  const PyGILState_STATE gstate = g_python_api.PyGILState_Ensure();
  PyObject* py_module = g_python_api.PyImport_ImportModule(module_name);
  if (!py_module) {
    const std::string import_error = consume_python_exception();
    g_python_api.PyGILState_Release(gstate);
    if (!import_error.empty()) {
      return dup_error_json("Failed to import Python module: " + import_error);
    }
    return dup_error_json("Failed to import Python module");
  }

  PyObject* handle_func = g_python_api.PyObject_GetAttrString(py_module, function_name);
  if (!handle_func || !g_python_api.PyCallable_Check(handle_func)) {
    decref(handle_func);
    decref(py_module);
    g_python_api.PyGILState_Release(gstate);
    return dup_error_json("Python function not found");
  }

  PyObject* py_result_str = g_python_api.PyObject_CallFunction(handle_func, "i", arg1);
  char* result_str = nullptr;
  if (py_result_str) {
    const char* temp_res = g_python_api.PyUnicode_AsUTF8(py_result_str);
    result_str = dup_bridge_string(
        temp_res ? temp_res : "{\"status\":\"error\",\"msg\":\"Invalid Python return\"}");
    decref(py_result_str);
  } else {
    const std::string python_error = consume_python_exception();
    if (!python_error.empty()) {
      result_str = dup_error_json("Python execution failed: " + python_error);
    } else {
      result_str = dup_error_json("Python execution failed");
    }
  }

  decref(handle_func);
  decref(py_module);
  g_python_api.PyGILState_Release(gstate);
  return result_str;
}

int apply_deploydash_data_dir(const char* path) {
  if (path == nullptr || path[0] == '\0') {
    return 0;
  }
#if defined(_WIN32)
  const std::wstring wide_path = wide_from_utf8(path);
  if (wide_path.empty()) {
    return 0;
  }
  return SetEnvironmentVariableW(L"DEPLOYDASH_DATA_DIR", wide_path.c_str())
             ? 1
             : 0;
#else
  return setenv("DEPLOYDASH_DATA_DIR", path, 1) == 0 ? 1 : 0;
#endif
}

}  // namespace

BRIDGE_EXPORT BRIDGE_USED int set_deploydash_data_dir(const char* path) {
  return apply_deploydash_data_dir(path);
}

BRIDGE_EXPORT BRIDGE_USED void warmup_python_runtime() {
  ensure_python_initialized();
}

BRIDGE_EXPORT BRIDGE_USED char* get_bridge_runtime_diagnostics() {
  std::lock_guard<std::mutex> lock(g_python_mutex);
  return dup_bridge_string(runtime_diagnostics_json_locked());
}

BRIDGE_EXPORT BRIDGE_USED void free_bridge_string(char* value) {
  if (value != nullptr) {
    free(value);
  }
}

BRIDGE_EXPORT BRIDGE_USED char* start_pyinfra_task(char* json_payload) {
  return call_python_string_arg_function(
      "orchestrator.task_runtime", "start_task", json_payload);
}

BRIDGE_EXPORT BRIDGE_USED char* poll_pyinfra_task_events(int task_id, int max_events) {
  return call_python_int_args_function(
      "orchestrator.task_runtime", "poll_task_events", task_id, max_events);
}

BRIDGE_EXPORT BRIDGE_USED char* get_pyinfra_task_result(int task_id) {
  return call_python_int_arg_function(
      "orchestrator.task_runtime", "get_task_result", task_id);
}

BRIDGE_EXPORT BRIDGE_USED char* cancel_pyinfra_task(int task_id) {
  return call_python_int_arg_function(
      "orchestrator.task_runtime", "cancel_task", task_id);
}

BRIDGE_EXPORT BRIDGE_USED char* get_recent_pyinfra_task_history(int limit) {
  return call_python_int_arg_function(
      "orchestrator.task_runtime", "get_recent_task_history", limit);
}
