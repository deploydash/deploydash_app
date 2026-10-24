#include "flutter_window.h"

#include <optional>

#include "flutter/generated_plugin_registrant.h"
#include "utils.h"

namespace {

constexpr char kProtocolChannelName[] = "com.deploydash.desktop/protocol";
constexpr char kProtocolMethodName[] = "deliverProtocolUri";
constexpr char kProtocolReadyMethodName[] = "protocolIngressReady";

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  protocol_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), kProtocolChannelName,
          &flutter::StandardMethodCodec::GetInstance());
  protocol_channel_->SetMethodCallHandler(
      [this](
          const flutter::MethodCall<flutter::EncodableValue>& call,
          std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
              result) {
        if (call.method_name() == kProtocolReadyMethodName) {
          protocol_ingress_ready_ = true;
          FlushQueuedProtocolUris();
          result->Success();
          return;
        }
        result->NotImplemented();
      });
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  if (flutter_controller_) {
    pending_protocol_uris_.clear();
    protocol_ingress_ready_ = false;
    protocol_channel_ = nullptr;
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

void FlutterWindow::DeliverProtocolUri(const std::string& uri) {
  if (!protocol_channel_ || uri.empty()) {
    return;
  }
  if (!protocol_ingress_ready_) {
    pending_protocol_uris_.push_back(uri);
    return;
  }
  protocol_channel_->InvokeMethod(
      kProtocolMethodName,
      std::make_unique<flutter::EncodableValue>(uri));
}

void FlutterWindow::FlushQueuedProtocolUris() {
  if (!protocol_ingress_ready_ || !protocol_channel_ ||
      pending_protocol_uris_.empty()) {
    return;
  }
  const auto pending = pending_protocol_uris_;
  pending_protocol_uris_.clear();
  for (const auto& uri : pending) {
    protocol_channel_->InvokeMethod(
        kProtocolMethodName,
        std::make_unique<flutter::EncodableValue>(uri));
  }
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_COPYDATA: {
      const auto* copy_data =
          reinterpret_cast<const COPYDATASTRUCT*>(lparam);
      if (copy_data == nullptr ||
          copy_data->dwData != kDeployDashProtocolCopyDataId ||
          copy_data->lpData == nullptr || copy_data->cbData == 0) {
        break;
      }

      const auto* utf16 =
          reinterpret_cast<const wchar_t*>(copy_data->lpData);
      const std::string uri = Utf8FromUtf16(utf16);
      if (!uri.empty()) {
        DeliverProtocolUri(uri);
        if (::IsIconic(hwnd)) {
          ::ShowWindow(hwnd, SW_RESTORE);
        }
        ::ShowWindow(hwnd, SW_SHOW);
        ::SetForegroundWindow(hwnd);
        return TRUE;
      }
      break;
    }
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
