#include "flutter_window.h"

#include <flutter/standard_method_codec.h>
#include <flutter_windows.h>
#include <wtsapi32.h>

#include <algorithm>
#include <cmath>
#include <optional>
#include <variant>

#include "flutter/generated_plugin_registrant.h"

namespace {

constexpr char kWindowChannelName[] = "discord_orb/window";
constexpr double kCollapsedOrbSizeLogical = 80.0;
constexpr double kMainWindowWidthLogical = 480.0;
constexpr double kMainWindowHeightLogical = 680.0;
constexpr double kDefaultMarginLogical = 24.0;

std::optional<double> TryGetDoubleArg(const flutter::EncodableMap& args,
                                      const char* key) {
  auto it = args.find(flutter::EncodableValue(key));
  if (it == args.end()) {
    return std::nullopt;
  }
  if (const auto* value = std::get_if<double>(&it->second)) {
    return *value;
  }
  if (const auto* value = std::get_if<int32_t>(&it->second)) {
    return static_cast<double>(*value);
  }
  if (const auto* value = std::get_if<int64_t>(&it->second)) {
    return static_cast<double>(*value);
  }
  return std::nullopt;
}

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {
  UnregisterSessionNotification();
}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  HWND hwnd = GetHandle();
  if (!hwnd) {
    return false;
  }

  ConfigureMainWindow(hwnd);

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
  RegisterWindowChannel();

  if (::WTSRegisterSessionNotification(hwnd, NOTIFY_FOR_THIS_SESSION)) {
    session_notification_registered_ = true;
    registered_hwnd_ = hwnd;
  }

  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([this]() {
    HWND window = this->GetHandle();
    if (window) {
      if (this->is_overlay_mode_) {
        ::ShowWindow(window, SW_SHOWNOACTIVATE);
        ::SetWindowPos(window, HWND_TOPMOST, 0, 0, 0, 0,
                       SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
      } else {
        ::ShowWindow(window, SW_SHOW);
      }
    }
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  UnregisterSessionNotification();

  if (window_channel_) {
    window_channel_->SetMethodCallHandler(nullptr);
    window_channel_ = nullptr;
  }

  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

void FlutterWindow::ConfigureMainWindow(HWND hwnd) {
  is_overlay_mode_ = false;
  LONG_PTR style = ::GetWindowLongPtr(hwnd, GWL_STYLE);
  style &= ~static_cast<LONG_PTR>(WS_POPUP);
  style |= WS_OVERLAPPEDWINDOW;
  ::SetWindowLongPtr(hwnd, GWL_STYLE, style);

  LONG_PTR ex_style = ::GetWindowLongPtr(hwnd, GWL_EXSTYLE);
  ex_style &= ~static_cast<LONG_PTR>(WS_EX_TOPMOST | WS_EX_TOOLWINDOW);
  ::SetWindowLongPtr(hwnd, GWL_EXSTYLE, ex_style);

  ::SetWindowPos(hwnd, HWND_NOTOPMOST, 0, 0, 0, 0,
                 SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE | SWP_FRAMECHANGED);
}

void FlutterWindow::ConfigureOverlayWindow(HWND hwnd) {
  is_overlay_mode_ = true;
  LONG_PTR style = ::GetWindowLongPtr(hwnd, GWL_STYLE);
  style &= ~static_cast<LONG_PTR>(WS_OVERLAPPEDWINDOW);
  style |= WS_POPUP;
  ::SetWindowLongPtr(hwnd, GWL_STYLE, style);

  LONG_PTR ex_style = ::GetWindowLongPtr(hwnd, GWL_EXSTYLE);
  ex_style |= WS_EX_TOPMOST | WS_EX_TOOLWINDOW;
  ::SetWindowLongPtr(hwnd, GWL_EXSTYLE, ex_style);

  ::SetWindowPos(hwnd, HWND_TOPMOST, 0, 0, 0, 0,
                 SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE | SWP_FRAMECHANGED);
}

void FlutterWindow::RegisterWindowChannel() {
  window_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), kWindowChannelName,
          &flutter::StandardMethodCodec::GetInstance());

  window_channel_->SetMethodCallHandler(
      [this](
          const flutter::MethodCall<flutter::EncodableValue>& call,
          std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
              result) {
        this->HandleWindowMethodCall(call, std::move(result));
      });
}

void FlutterWindow::HandleWindowMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const std::string& method = call.method_name();
  if (method == "hasOverlayPermission") {
    result->Success(flutter::EncodableValue(true));
    return;
  }
  if (method == "openOverlayPermissionSettings") {
    result->Success();
    return;
  }
  if (method == "showCollapsedOrb" || method == "collapsePanel") {
    ShowCollapsedOrb();
    result->Success();
    return;
  }
  if (method == "expandPanel") {
    const auto* args =
        call.arguments()
            ? std::get_if<flutter::EncodableMap>(call.arguments())
            : nullptr;
    if (!args) {
      result->Error("invalid_arguments",
                    "expandPanel requires a map with width and height");
      return;
    }
    std::optional<double> width = TryGetDoubleArg(*args, "width");
    std::optional<double> height = TryGetDoubleArg(*args, "height");
    if (!width.has_value() || !height.has_value() || *width <= 0.0 ||
        *height <= 0.0) {
      result->Error("invalid_arguments",
                    "expandPanel requires positive numeric width and height");
      return;
    }
    ExpandPanel(*width, *height);
    result->Success();
    return;
  }
  if (method == "moveOrb") {
    const auto* args =
        call.arguments()
            ? std::get_if<flutter::EncodableMap>(call.arguments())
            : nullptr;
    if (!args) {
      result->Error("invalid_arguments",
                    "moveOrb requires a map with dx and dy");
      return;
    }
    std::optional<double> dx = TryGetDoubleArg(*args, "dx");
    std::optional<double> dy = TryGetDoubleArg(*args, "dy");
    if (!dx.has_value() || !dy.has_value() || !std::isfinite(*dx) ||
        !std::isfinite(*dy)) {
      result->Error("invalid_arguments",
                    "moveOrb requires finite numeric dx and dy");
      return;
    }
    MoveOrb(*dx, *dy);
    result->Success();
    return;
  }
  if (method == "showMainWindow") {
    ShowMainWindow();
    result->Success();
    return;
  }
  if (method == "hideOrb") {
    HideOrb();
    result->Success();
    return;
  }
  result->NotImplemented();
}

void FlutterWindow::ShowMainWindow() {
  HWND hwnd = GetHandle();
  if (!hwnd) {
    return;
  }

  is_expanded_ = false;
  ConfigureMainWindow(hwnd);

  HMONITOR monitor = ::MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST);
  double scale = GetScaleFactorForMonitor(monitor);
  RECT work_area = GetMonitorWorkArea(hwnd);

  int main_width =
      static_cast<int>(std::lround(kMainWindowWidthLogical * scale));
  int main_height =
      static_cast<int>(std::lround(kMainWindowHeightLogical * scale));
  int center_x = work_area.left +
                 ((work_area.right - work_area.left) - main_width) / 2;
  int center_y = work_area.top +
                 ((work_area.bottom - work_area.top) - main_height) / 2;

  RECT clamped =
      ClampRectToWorkArea(center_x, center_y, main_width, main_height, work_area);
  ::SetWindowPos(hwnd, HWND_NOTOPMOST, clamped.left, clamped.top,
                 clamped.right - clamped.left, clamped.bottom - clamped.top,
                 SWP_SHOWWINDOW | SWP_FRAMECHANGED);
  ::ShowWindow(hwnd, SW_SHOW);
  ::SetForegroundWindow(hwnd);
  ::SetFocus(hwnd);
}

void FlutterWindow::ShowCollapsedOrb() {
  HWND hwnd = GetHandle();
  if (!hwnd) {
    return;
  }

  ConfigureOverlayWindow(hwnd);

  HMONITOR monitor = ::MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST);
  double scale = GetScaleFactorForMonitor(monitor);
  RECT work_area = GetMonitorWorkArea(hwnd);

  int orb_size =
      static_cast<int>(std::lround(kCollapsedOrbSizeLogical * scale));
  int margin = static_cast<int>(std::lround(kDefaultMarginLogical * scale));

  int desired_x =
      has_collapsed_origin_ ? collapsed_origin_.x : work_area.right - orb_size - margin;
  int desired_y =
      has_collapsed_origin_ ? collapsed_origin_.y : work_area.top + margin;

  RECT clamped =
      ClampRectToWorkArea(desired_x, desired_y, orb_size, orb_size, work_area);
  collapsed_origin_.x = clamped.left;
  collapsed_origin_.y = clamped.top;
  has_collapsed_origin_ = true;
  is_expanded_ = false;

  ::SetWindowPos(hwnd, HWND_TOPMOST, clamped.left, clamped.top,
                 clamped.right - clamped.left, clamped.bottom - clamped.top,
                 SWP_NOACTIVATE | SWP_SHOWWINDOW);
}

void FlutterWindow::ExpandPanel(double width, double height) {
  HWND hwnd = GetHandle();
  if (!hwnd) {
    return;
  }

  ConfigureOverlayWindow(hwnd);

  HMONITOR monitor = ::MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST);
  double scale = GetScaleFactorForMonitor(monitor);
  RECT work_area = GetMonitorWorkArea(hwnd);

  int orb_size =
      static_cast<int>(std::lround(kCollapsedOrbSizeLogical * scale));
  int margin = static_cast<int>(std::lround(kDefaultMarginLogical * scale));

  if (!is_expanded_) {
    RECT current_rect{};
    if (::GetWindowRect(hwnd, &current_rect) &&
        (current_rect.right - current_rect.left) == orb_size &&
        (current_rect.bottom - current_rect.top) == orb_size) {
      collapsed_origin_.x = current_rect.left;
      collapsed_origin_.y = current_rect.top;
      has_collapsed_origin_ = true;
    } else if (!has_collapsed_origin_) {
      collapsed_origin_.x = work_area.right - orb_size - margin;
      collapsed_origin_.y = work_area.top + margin;
      has_collapsed_origin_ = true;
    }
  }

  int panel_width = static_cast<int>(std::lround(width * scale));
  int panel_height = static_cast<int>(std::lround(height * scale));
  int desired_x = collapsed_origin_.x + orb_size - panel_width;
  int desired_y = collapsed_origin_.y;

  RECT clamped = ClampRectToWorkArea(desired_x, desired_y, panel_width,
                                     panel_height, work_area);

  is_expanded_ = true;
  ::SetWindowPos(hwnd, HWND_TOPMOST, clamped.left, clamped.top,
                 clamped.right - clamped.left, clamped.bottom - clamped.top,
                 SWP_SHOWWINDOW);
  ::SetForegroundWindow(hwnd);
  ::SetFocus(hwnd);
}

void FlutterWindow::MoveOrb(double dx, double dy) {
  HWND hwnd = GetHandle();
  if (!hwnd) {
    return;
  }

  RECT current_rect{};
  if (!::GetWindowRect(hwnd, &current_rect)) {
    return;
  }

  HMONITOR monitor = ::MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST);
  double scale = GetScaleFactorForMonitor(monitor);
  RECT work_area = GetMonitorWorkArea(hwnd);

  int width = current_rect.right - current_rect.left;
  int height = current_rect.bottom - current_rect.top;
  int desired_x = current_rect.left + static_cast<int>(std::lround(dx * scale));
  int desired_y = current_rect.top + static_cast<int>(std::lround(dy * scale));

  RECT clamped =
      ClampRectToWorkArea(desired_x, desired_y, width, height, work_area);
  ::SetWindowPos(hwnd, HWND_TOPMOST, clamped.left, clamped.top,
                 clamped.right - clamped.left, clamped.bottom - clamped.top,
                 SWP_NOACTIVATE);
  if (!is_expanded_) {
    collapsed_origin_.x = clamped.left;
    collapsed_origin_.y = clamped.top;
    has_collapsed_origin_ = true;
  }
}

void FlutterWindow::HideOrb() {
  HWND hwnd = GetHandle();
  is_expanded_ = false;
  if (hwnd) {
    ::ShowWindow(hwnd, SW_HIDE);
  }
}

void FlutterWindow::UnregisterSessionNotification() {
  if (session_notification_registered_ && registered_hwnd_ != nullptr) {
    if (::IsWindow(registered_hwnd_)) {
      ::WTSUnRegisterSessionNotification(registered_hwnd_);
    }
    session_notification_registered_ = false;
    registered_hwnd_ = nullptr;
  }
}

void FlutterWindow::NotifyPanelDismissRequested() {
  if (window_channel_) {
    window_channel_->InvokeMethod("onPanelDismissRequested", nullptr);
  }
}

void FlutterWindow::NotifyLockOrSleep() {
  if (window_channel_) {
    window_channel_->InvokeMethod("onLockOrSleep", nullptr);
  }
}

RECT FlutterWindow::GetMonitorWorkArea(HWND hwnd) const {
  HMONITOR monitor = ::MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST);
  MONITORINFO info{};
  info.cbSize = sizeof(info);
  if (::GetMonitorInfoW(monitor, &info)) {
    return info.rcWork;
  }
  RECT fallback{0, 0, 1920, 1080};
  ::SystemParametersInfoW(SPI_GETWORKAREA, 0, &fallback, 0);
  return fallback;
}

double FlutterWindow::GetScaleFactorForMonitor(HMONITOR monitor) const {
  UINT dpi = FlutterDesktopGetDpiForMonitor(monitor);
  if (dpi == 0) {
    return 1.0;
  }
  return static_cast<double>(dpi) / 96.0;
}

RECT FlutterWindow::ClampRectToWorkArea(int x, int y, int width, int height,
                                        const RECT& work_area) const {
  int max_width = static_cast<int>(work_area.right - work_area.left);
  int max_height = static_cast<int>(work_area.bottom - work_area.top);
  int clamped_width = (std::min)(width, max_width);
  int clamped_height = (std::min)(height, max_height);
  int clamped_x = (std::min)((std::max)(x, static_cast<int>(work_area.left)),
                             static_cast<int>(work_area.right) - clamped_width);
  int clamped_y = (std::min)((std::max)(y, static_cast<int>(work_area.top)),
                             static_cast<int>(work_area.bottom) - clamped_height);
  return RECT{clamped_x, clamped_y, clamped_x + clamped_width,
              clamped_y + clamped_height};
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  if ((message == WM_KEYDOWN || message == WM_SYSKEYDOWN) &&
      wparam == VK_ESCAPE && is_expanded_) {
    NotifyPanelDismissRequested();
    return 0;
  }

  if (message == WM_ACTIVATE && LOWORD(wparam) == WA_INACTIVE) {
    if (is_expanded_) {
      NotifyPanelDismissRequested();
    }
    return 0;
  }

  if (message == WM_WTSSESSION_CHANGE) {
    if (wparam == WTS_SESSION_LOCK) {
      NotifyLockOrSleep();
    }
    return 0;
  }

  if (message == WM_POWERBROADCAST) {
    if (wparam == PBT_APMSUSPEND) {
      NotifyLockOrSleep();
      return TRUE;
    }
  }

  if (message == WM_DESTROY) {
    UnregisterSessionNotification();
  }

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
      if (flutter_controller_) {
        flutter_controller_->engine()->ReloadSystemFonts();
      }
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
