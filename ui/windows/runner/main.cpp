#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include <optional>

#include "flutter_window.h"
#include "utils.h"
#include "../../shared_native/process_security.h"

namespace {

std::optional<std::string> FindProtocolLaunchUrl(
    const std::vector<std::string>& arguments) {
  for (const auto& argument : arguments) {
    if (argument.rfind("deploydash://", 0) == 0) {
      return argument;
    }
  }
  return std::nullopt;
}

bool HandOffProtocolLaunchToRunningInstance(const std::string& uri) {
  const HWND existing_window = ::FindWindow(
      kDeployDashWindowClassName, kDeployDashWindowTitle);
  if (existing_window == nullptr) {
    return false;
  }

  const std::wstring utf16_uri = Utf16FromUtf8(uri);
  if (utf16_uri.empty()) {
    return false;
  }

  COPYDATASTRUCT copy_data{};
  copy_data.dwData = kDeployDashProtocolCopyDataId;
  copy_data.cbData = static_cast<DWORD>(
      (utf16_uri.size() + 1) * sizeof(wchar_t));
  copy_data.lpData = const_cast<wchar_t*>(utf16_uri.c_str());

  const LRESULT result = ::SendMessage(
      existing_window, WM_COPYDATA, 0,
      reinterpret_cast<LPARAM>(&copy_data));
  return result == TRUE;
}

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  std::string hardening_error;
  if (!deploydash::ApplyProcessHardening(&hardening_error)) {
    const std::wstring message =
        L"Deploy Dash could not apply the required process security controls. "
        L"Reinstall the application and try again.";
    ::MessageBoxW(nullptr, message.c_str(), L"Deploy Dash could not start",
                  MB_OK | MB_ICONERROR);
    return EXIT_FAILURE;
  }

  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();
  const auto protocol_launch_url =
      FindProtocolLaunchUrl(command_line_arguments);
  if (protocol_launch_url &&
      HandOffProtocolLaunchToRunningInstance(*protocol_launch_url)) {
    ::CoUninitialize();
    return EXIT_SUCCESS;
  }

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"Deploy Dash", origin, size)) {
    ::CoUninitialize();
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
