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
constexpr double kMinExpandedWidthLogical = 260.0;
constexpr double kMinExpandedHeightLogical = 240.0;
constexpr double kMaxExpandedWidthLogical = 720.0;
constexpr double kMaxExpandedHeightLogical = 800.0;
constexpr double kResizeEdgeThicknessLogical = 8.0;
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
  if (is_overlay_mode_) {
    return;
  }
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
    std::string direction = ExpandPanel(*width, *height);
    result->Success(flutter::EncodableValue(direction));
    return;
  }
  if (method == "showToastOverlay") {
    const auto* args =
        call.arguments()
            ? std::get_if<flutter::EncodableMap>(call.arguments())
            : nullptr;
    if (!args) {
      result->Error("invalid_arguments",
                    "showToastOverlay requires a map with width and height");
      return;
    }
    std::optional<double> width = TryGetDoubleArg(*args, "width");
    std::optional<double> height = TryGetDoubleArg(*args, "height");
    if (!width.has_value() || !height.has_value() || *width <= 0.0 ||
        *height <= 0.0) {
      result->Error(
          "invalid_arguments",
          "showToastOverlay requires positive numeric width and height");
      return;
    }
    std::string direction = ShowToastOverlay(*width, *height);
    result->Success(flutter::EncodableValue(direction));
    return;
  }
  if (method == "updateToastStack" || method == "hideToastStack") {
    result->Success();
    return;
  }
  if (method == "setPanelPinned") {
    const auto* args =
        call.arguments()
            ? std::get_if<flutter::EncodableMap>(call.arguments())
            : nullptr;
    if (!args) {
      result->Error("invalid_arguments",
                    "setPanelPinned requires a map with pinned");
      return;
    }
    auto it = args->find(flutter::EncodableValue("pinned"));
    const auto* pinned =
        it != args->end() ? std::get_if<bool>(&it->second) : nullptr;
    if (!pinned) {
      result->Error("invalid_arguments",
                    "setPanelPinned requires a boolean pinned argument");
      return;
    }
    is_panel_pinned_ = *pinned;
    result->Success();
    return;
  }
  if (method == "setToastNotificationsEnabled") {
    const auto* args =
        call.arguments()
            ? std::get_if<flutter::EncodableMap>(call.arguments())
            : nullptr;
    if (!args) {
      result->Error(
          "invalid_arguments",
          "setToastNotificationsEnabled requires a map with enabled");
      return;
    }
    auto it = args->find(flutter::EncodableValue("enabled"));
    const auto* enabled =
        it != args->end() ? std::get_if<bool>(&it->second) : nullptr;
    if (!enabled) {
      result->Error(
          "invalid_arguments",
          "setToastNotificationsEnabled requires a boolean enabled argument");
      return;
    }
    is_toast_notifications_enabled_ = *enabled;
    result->Success();
    return;
  }
  if (method == "setToastLayout") {
    const auto* args =
        call.arguments()
            ? std::get_if<flutter::EncodableMap>(call.arguments())
            : nullptr;
    if (!args) {
      result->Error("invalid_arguments",
                    "setToastLayout requires a map with compact");
      return;
    }
    auto it = args->find(flutter::EncodableValue("compact"));
    const auto* compact =
        it != args->end() ? std::get_if<bool>(&it->second) : nullptr;
    if (!compact) {
      result->Error("invalid_arguments",
                    "setToastLayout requires a boolean compact argument");
      return;
    }
    is_compact_toast_layout_ = *compact;
    result->Success();
    return;
  }
  if (method == "quitApp") {
    result->Success();
    QuitApp();
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
  if (method == "startOrbDrag") {
    StartOrbDrag();
    result->Success();
    return;
  }
  if (method == "startPanelResize") {
    const auto* args =
        call.arguments()
            ? std::get_if<flutter::EncodableMap>(call.arguments())
            : nullptr;
    if (!args) {
      result->Error("invalid_arguments",
                    "startPanelResize requires a map with edge");
      return;
    }
    auto it = args->find(flutter::EncodableValue("edge"));
    const auto* edge =
        it != args->end() ? std::get_if<std::string>(&it->second) : nullptr;
    if (!edge) {
      result->Error("invalid_arguments",
                    "startPanelResize requires a string edge");
      return;
    }
    WPARAM hit_test = HTNOWHERE;
    if (*edge == "left") hit_test = HTLEFT;
    else if (*edge == "right") hit_test = HTRIGHT;
    else if (*edge == "top") hit_test = HTTOP;
    else if (*edge == "bottom") hit_test = HTBOTTOM;
    else if (*edge == "topLeft") hit_test = HTTOPLEFT;
    else if (*edge == "topRight") hit_test = HTTOPRIGHT;
    else if (*edge == "bottomLeft") hit_test = HTBOTTOMLEFT;
    else if (*edge == "bottomRight") hit_test = HTBOTTOMRIGHT;
    if (hit_test == HTNOWHERE) {
      result->Error("invalid_arguments",
                    "startPanelResize received an unknown edge");
      return;
    }
    StartPanelResize(hit_test);
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
  is_toast_showing_ = false;
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

  if (is_overlay_mode_ && (is_expanded_ || is_toast_showing_) &&
      did_move_while_expanded_) {
    SyncCollapsedOriginFromWindow(hwnd);
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
  expanded_above_ = false;
  is_expanded_ = false;
  is_toast_showing_ = false;
  did_move_while_expanded_ = false;

  ::SetWindowPos(hwnd, HWND_TOPMOST, clamped.left, clamped.top,
                 clamped.right - clamped.left, clamped.bottom - clamped.top,
                 SWP_NOACTIVATE | SWP_SHOWWINDOW);
}

std::string FlutterWindow::ExpandPanel(double width, double height) {
  HWND hwnd = GetHandle();
  if (!hwnd) {
    return "below";
  }

  ConfigureOverlayWindow(hwnd);

  HMONITOR monitor = ::MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST);
  double scale = GetScaleFactorForMonitor(monitor);
  RECT work_area = GetMonitorWorkArea(hwnd);

  int orb_size =
      static_cast<int>(std::lround(kCollapsedOrbSizeLogical * scale));
  int margin = static_cast<int>(std::lround(kDefaultMarginLogical * scale));

  if (is_toast_showing_ && did_move_while_expanded_) {
    SyncCollapsedOriginFromWindow(hwnd);
  } else if (!is_expanded_ && !is_toast_showing_) {
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

  double logical_width =
      has_persisted_expanded_size_ ? persisted_expanded_width_logical_ : width;
  double logical_height =
      has_persisted_expanded_size_ ? persisted_expanded_height_logical_ : height;
  logical_width = (std::min)((std::max)(logical_width, kMinExpandedWidthLogical),
                             kMaxExpandedWidthLogical);
  logical_height =
      (std::min)((std::max)(logical_height, kMinExpandedHeightLogical),
                 kMaxExpandedHeightLogical);

  int panel_width = static_cast<int>(std::lround(logical_width * scale));
  int panel_height = static_cast<int>(std::lround(logical_height * scale));

  int space_below = static_cast<int>(work_area.bottom) - collapsed_origin_.y;
  int space_above =
      (collapsed_origin_.y + orb_size) - static_cast<int>(work_area.top);
  if (space_below >= panel_height) {
    expanded_above_ = false;
  } else if (space_above > space_below) {
    expanded_above_ = true;
  } else {
    expanded_above_ = false;
  }

  int desired_x = collapsed_origin_.x + orb_size - panel_width;
  int desired_y = expanded_above_
                      ? (collapsed_origin_.y + orb_size - panel_height)
                      : collapsed_origin_.y;

  RECT clamped = ClampRectToWorkArea(desired_x, desired_y, panel_width,
                                     panel_height, work_area);

  is_toast_showing_ = false;
  is_expanded_ = true;
  did_move_while_expanded_ = false;
  ::SetWindowPos(hwnd, HWND_TOPMOST, clamped.left, clamped.top,
                 clamped.right - clamped.left, clamped.bottom - clamped.top,
                 SWP_SHOWWINDOW);
  ::SetForegroundWindow(hwnd);
  ::SetFocus(hwnd);
  return expanded_above_ ? "above" : "below";
}

std::string FlutterWindow::ShowToastOverlay(double width, double height) {
  HWND hwnd = GetHandle();
  if (!hwnd) {
    return "below";
  }

  ConfigureOverlayWindow(hwnd);

  HMONITOR monitor = ::MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST);
  double scale = GetScaleFactorForMonitor(monitor);
  RECT work_area = GetMonitorWorkArea(hwnd);

  int orb_size =
      static_cast<int>(std::lround(kCollapsedOrbSizeLogical * scale));
  int margin = static_cast<int>(std::lround(kDefaultMarginLogical * scale));

  if (is_toast_showing_ && did_move_while_expanded_) {
    SyncCollapsedOriginFromWindow(hwnd);
  } else if (!is_expanded_ && !is_toast_showing_) {
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

  double logical_width = (std::max)(width, kCollapsedOrbSizeLogical);
  double logical_height = (std::max)(height, kCollapsedOrbSizeLogical);
  int max_work_width = static_cast<int>(work_area.right - work_area.left);
  int max_work_height = static_cast<int>(work_area.bottom - work_area.top);
  int toast_width = (std::min)(
      static_cast<int>(std::lround(logical_width * scale)), max_work_width);
  int toast_height = (std::min)(
      static_cast<int>(std::lround(logical_height * scale)), max_work_height);

  int space_below = static_cast<int>(work_area.bottom) - collapsed_origin_.y;
  int space_above =
      (collapsed_origin_.y + orb_size) - static_cast<int>(work_area.top);
  if (space_below >= toast_height) {
    expanded_above_ = false;
  } else if (space_above > space_below) {
    expanded_above_ = true;
  } else {
    expanded_above_ = false;
  }

  int desired_x = collapsed_origin_.x + orb_size - toast_width;
  int desired_y = expanded_above_
                      ? (collapsed_origin_.y + orb_size - toast_height)
                      : collapsed_origin_.y;

  RECT clamped = ClampRectToWorkArea(desired_x, desired_y, toast_width,
                                     toast_height, work_area);

  is_expanded_ = false;
  is_toast_showing_ = true;
  did_move_while_expanded_ = false;
  ::SetWindowPos(hwnd, HWND_TOPMOST, clamped.left, clamped.top,
                 clamped.right - clamped.left, clamped.bottom - clamped.top,
                 SWP_NOACTIVATE | SWP_SHOWWINDOW);
  return expanded_above_ ? "above" : "below";
}

void FlutterWindow::StartOrbDrag() {
  HWND hwnd = GetHandle();
  if (!hwnd || !is_overlay_mode_ || is_native_dragging_) {
    return;
  }

  is_native_dragging_ = true;
  ::ReleaseCapture();
  ::SendMessage(hwnd, WM_NCLBUTTONDOWN, HTCAPTION, 0);
  is_native_dragging_ = false;

  RECT current_rect{};
  if (::GetWindowRect(hwnd, &current_rect)) {
    RECT work_area = GetMonitorWorkArea(hwnd);
    int width = current_rect.right - current_rect.left;
    int height = current_rect.bottom - current_rect.top;
    RECT clamped = ClampRectToWorkArea(current_rect.left, current_rect.top,
                                       width, height, work_area);
    if (clamped.left != current_rect.left || clamped.top != current_rect.top) {
      ::SetWindowPos(hwnd, HWND_TOPMOST, clamped.left, clamped.top,
                     clamped.right - clamped.left, clamped.bottom - clamped.top,
                     SWP_NOACTIVATE);
    }
    if (is_expanded_ || is_toast_showing_) {
      did_move_while_expanded_ = true;
    }
    SyncCollapsedOriginFromWindow(hwnd);
  }
}

void FlutterWindow::StartPanelResize(WPARAM hit_test) {
  HWND hwnd = GetHandle();
  if (!hwnd || !is_overlay_mode_ || !is_expanded_ || is_native_dragging_) {
    return;
  }

  is_native_dragging_ = true;
  ::ReleaseCapture();
  ::SendMessage(hwnd, WM_NCLBUTTONDOWN, hit_test, 0);
  is_native_dragging_ = false;

  RECT current_rect{};
  if (::GetWindowRect(hwnd, &current_rect)) {
    HMONITOR monitor = ::MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST);
    double scale = GetScaleFactorForMonitor(monitor);
    RECT work_area = GetMonitorWorkArea(hwnd);
    int width = current_rect.right - current_rect.left;
    int height = current_rect.bottom - current_rect.top;
    RECT clamped = ClampRectToWorkArea(current_rect.left, current_rect.top,
                                       width, height, work_area);
    if (clamped.left != current_rect.left || clamped.top != current_rect.top ||
        (clamped.right - clamped.left) != width ||
        (clamped.bottom - clamped.top) != height) {
      ::SetWindowPos(hwnd, HWND_TOPMOST, clamped.left, clamped.top,
                     clamped.right - clamped.left, clamped.bottom - clamped.top,
                     SWP_NOACTIVATE);
    }
    if (scale > 0.0) {
      persisted_expanded_width_logical_ =
          static_cast<double>(clamped.right - clamped.left) / scale;
      persisted_expanded_height_logical_ =
          static_cast<double>(clamped.bottom - clamped.top) / scale;
      has_persisted_expanded_size_ = true;
    }
    did_move_while_expanded_ = true;
    SyncCollapsedOriginFromWindow(hwnd);
  }
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
  if (is_expanded_ || is_toast_showing_) {
    did_move_while_expanded_ = true;
  }
  SyncCollapsedOriginFromWindow(hwnd);
}

LRESULT FlutterWindow::HitTestResizeEdge(HWND hwnd, POINT screen_pt) const {
  if (!is_overlay_mode_ || !is_expanded_) {
    return HTNOWHERE;
  }
  RECT rect{};
  if (!::GetWindowRect(hwnd, &rect)) {
    return HTNOWHERE;
  }
  HMONITOR monitor = ::MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST);
  double scale = GetScaleFactorForMonitor(monitor);
  int edge = static_cast<int>(std::lround(kResizeEdgeThicknessLogical * scale));

  bool on_left = screen_pt.x >= rect.left && screen_pt.x < rect.left + edge;
  bool on_right = screen_pt.x <= rect.right && screen_pt.x > rect.right - edge;
  bool on_top = screen_pt.y >= rect.top && screen_pt.y < rect.top + edge;
  bool on_bottom =
      screen_pt.y <= rect.bottom && screen_pt.y > rect.bottom - edge;

  if (on_top && on_left) return HTTOPLEFT;
  if (on_top && on_right) return HTTOPRIGHT;
  if (on_bottom && on_left) return HTBOTTOMLEFT;
  if (on_bottom && on_right) return HTBOTTOMRIGHT;
  if (on_left) return HTLEFT;
  if (on_right) return HTRIGHT;
  if (on_top) return HTTOP;
  if (on_bottom) return HTBOTTOM;
  return HTNOWHERE;
}

bool FlutterWindow::IsPointInOrbDragRegion(HWND hwnd, POINT screen_pt) const {
  if (!is_overlay_mode_) {
    return false;
  }
  RECT rect{};
  if (!::GetWindowRect(hwnd, &rect)) {
    return false;
  }
  if (!is_expanded_ && !is_toast_showing_) {
    return screen_pt.x >= rect.left && screen_pt.x <= rect.right &&
           screen_pt.y >= rect.top && screen_pt.y <= rect.bottom;
  }
  HMONITOR monitor = ::MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST);
  double scale = GetScaleFactorForMonitor(monitor);
  int orb_size =
      static_cast<int>(std::lround(kCollapsedOrbSizeLogical * scale));
  if (screen_pt.x < rect.right - orb_size || screen_pt.x > rect.right) {
    return false;
  }
  if (expanded_above_) {
    return screen_pt.y >= rect.bottom - orb_size && screen_pt.y <= rect.bottom;
  }
  return screen_pt.y >= rect.top && screen_pt.y <= rect.top + orb_size;
}

void FlutterWindow::SyncCollapsedOriginFromWindow(HWND hwnd) {
  if (!is_overlay_mode_) {
    return;
  }
  RECT current_rect{};
  if (!::GetWindowRect(hwnd, &current_rect)) {
    return;
  }
  HMONITOR monitor = ::MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST);
  double scale = GetScaleFactorForMonitor(monitor);
  RECT work_area = GetMonitorWorkArea(hwnd);
  int orb_size =
      static_cast<int>(std::lround(kCollapsedOrbSizeLogical * scale));

  bool is_large_overlay = is_expanded_ || is_toast_showing_;
  int raw_x = is_large_overlay ? (current_rect.right - orb_size)
                               : current_rect.left;
  int raw_y = (is_large_overlay && expanded_above_)
                  ? (current_rect.bottom - orb_size)
                  : current_rect.top;
  RECT clamped_orb =
      ClampRectToWorkArea(raw_x, raw_y, orb_size, orb_size, work_area);
  collapsed_origin_.x = clamped_orb.left;
  collapsed_origin_.y = clamped_orb.top;
  has_collapsed_origin_ = true;
}

void FlutterWindow::HideOrb() {
  HWND hwnd = GetHandle();
  is_expanded_ = false;
  is_toast_showing_ = false;
  if (hwnd) {
    ::ShowWindow(hwnd, SW_HIDE);
  }
}

void FlutterWindow::QuitApp() {
  HWND hwnd = GetHandle();
  is_expanded_ = false;
  is_toast_showing_ = false;
  if (hwnd) {
    ::ShowWindow(hwnd, SW_HIDE);
    ::DestroyWindow(hwnd);
  }
  ::PostQuitMessage(0);
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
  if (message == WM_GETMINMAXINFO && is_overlay_mode_ && is_expanded_) {
    auto* mmi = reinterpret_cast<MINMAXINFO*>(lparam);
    if (mmi != nullptr) {
      HMONITOR monitor = ::MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST);
      double scale = GetScaleFactorForMonitor(monitor);
      mmi->ptMinTrackSize.x =
          static_cast<LONG>(std::lround(kMinExpandedWidthLogical * scale));
      mmi->ptMinTrackSize.y =
          static_cast<LONG>(std::lround(kMinExpandedHeightLogical * scale));
      mmi->ptMaxTrackSize.x =
          static_cast<LONG>(std::lround(kMaxExpandedWidthLogical * scale));
      mmi->ptMaxTrackSize.y =
          static_cast<LONG>(std::lround(kMaxExpandedHeightLogical * scale));
      return 0;
    }
  }

  if (message == WM_NCHITTEST && is_overlay_mode_) {
    POINT screen_pt{static_cast<short>(LOWORD(lparam)),
                    static_cast<short>(HIWORD(lparam))};
    if (is_expanded_) {
      LRESULT resize_hit = HitTestResizeEdge(hwnd, screen_pt);
      if (resize_hit != HTNOWHERE) {
        return resize_hit;
      }
    }
    if (is_native_dragging_ && IsPointInOrbDragRegion(hwnd, screen_pt)) {
      return HTCAPTION;
    }
  }

  if (message == WM_EXITSIZEMOVE && is_overlay_mode_) {
    if (is_expanded_) {
      RECT current_rect{};
      if (::GetWindowRect(hwnd, &current_rect)) {
        HMONITOR monitor = ::MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST);
        double scale = GetScaleFactorForMonitor(monitor);
        if (scale > 0.0) {
          persisted_expanded_width_logical_ =
              static_cast<double>(current_rect.right - current_rect.left) /
              scale;
          persisted_expanded_height_logical_ =
              static_cast<double>(current_rect.bottom - current_rect.top) /
              scale;
          has_persisted_expanded_size_ = true;
        }
      }
      did_move_while_expanded_ = true;
    } else if (is_toast_showing_) {
      did_move_while_expanded_ = true;
    }
    SyncCollapsedOriginFromWindow(hwnd);
  }

  if ((message == WM_KEYDOWN || message == WM_SYSKEYDOWN) &&
      wparam == VK_ESCAPE && is_expanded_) {
    NotifyPanelDismissRequested();
    return 0;
  }

  if (message == WM_ACTIVATE && LOWORD(wparam) == WA_INACTIVE) {
    if (is_expanded_ && is_overlay_mode_ && !is_panel_pinned_) {
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
