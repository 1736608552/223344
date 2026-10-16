#include "flutter_window.h"

#include <optional>
#include <variant>

#include "flutter/generated_plugin_registrant.h"

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

void FlutterWindow::SetFullScreen(bool full_screen) {
  if (is_full_screen_ == full_screen) {
    return;
  }
  HWND hwnd = GetHandle();
  if (!hwnd) {
    return;
  }

  if (full_screen) {
    saved_window_style_ = GetWindowLong(hwnd, GWL_STYLE);
    saved_placement_.length = sizeof(WINDOWPLACEMENT);
    GetWindowPlacement(hwnd, &saved_placement_);

    HMONITOR monitor = MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST);
    MONITORINFO mi = { sizeof(mi) };
    if (GetMonitorInfo(monitor, &mi)) {
      // 移除标题栏、厚边框与最大最小化按钮，并切换为 POPUP 样式
      SetWindowLong(hwnd, GWL_STYLE, (saved_window_style_ & ~WS_OVERLAPPEDWINDOW) | WS_POPUP);
      // 置顶并完全覆盖当前显示器全屏区域（含覆盖任务栏）
      SetWindowPos(hwnd, HWND_TOP,
                   mi.rcMonitor.left, mi.rcMonitor.top,
                   mi.rcMonitor.right - mi.rcMonitor.left,
                   mi.rcMonitor.bottom - mi.rcMonitor.top,
                   SWP_NOOWNERZORDER | SWP_FRAMECHANGED);
      is_full_screen_ = true;
    }
  } else {
    // 恢复原有样式与窗口几何尺寸
    SetWindowLong(hwnd, GWL_STYLE, saved_window_style_);
    SetWindowPlacement(hwnd, &saved_placement_);
    SetWindowPos(hwnd, nullptr, 0, 0, 0, 0,
                 SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER |
                 SWP_NOOWNERZORDER | SWP_FRAMECHANGED);
    is_full_screen_ = false;
  }
}

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
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  // 注册原生 Window 控制通道: org.moontechlab.lunatv/window
  window_channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      flutter_controller_->engine()->messenger(), "org.moontechlab.lunatv/window",
      &flutter::StandardMethodCodec::GetInstance());

  window_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
        if (call.method_name() == "setFullScreen") {
          bool full_screen = false;
          if (call.arguments()) {
            if (const auto* args = std::get_if<flutter::EncodableMap>(call.arguments())) {
              auto it = args->find(flutter::EncodableValue("fullScreen"));
              if (it != args->end() && std::holds_alternative<bool>(it->second)) {
                full_screen = std::get<bool>(it->second);
              }
            } else if (const auto* val = std::get_if<bool>(call.arguments())) {
              full_screen = *val;
            }
          }
          this->SetFullScreen(full_screen);
          result->Success(flutter::EncodableValue(this->IsFullScreen()));
        } else if (call.method_name() == "isFullScreen") {
          result->Success(flutter::EncodableValue(this->IsFullScreen()));
        } else {
          result->NotImplemented();
        }
      });

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
  if (window_channel_) {
    window_channel_ = nullptr;
  }
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
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
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
