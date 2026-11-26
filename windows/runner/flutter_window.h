#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/encodable_value.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>

#include <memory>
#include <string>

#include "win32_window.h"

// A window that hosts the frameless topmost Discord Orb Flutter view.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();

  // Returns true while the orb panel is expanded.
  bool IsExpanded() const { return is_expanded_; }

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  void ConfigureMainWindow(HWND hwnd);
  void ConfigureOverlayWindow(HWND hwnd);
  void RegisterWindowChannel();
  void HandleWindowMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  void ShowMainWindow();
  void ShowCollapsedOrb();
  std::string ExpandPanel(double width, double height);
  std::string ShowToastOverlay(double width, double height);
  void StartOrbDrag();
  void StartPanelResize(WPARAM hit_test);
  void MoveOrb(double dx, double dy);
  void HideOrb();
  void QuitApp();
  LRESULT HitTestResizeEdge(HWND hwnd, POINT screen_pt) const;
  bool IsPointInOrbDragRegion(HWND hwnd, POINT screen_pt) const;
  void SyncCollapsedOriginFromWindow(HWND hwnd);
  void UnregisterSessionNotification();
  void NotifyPanelDismissRequested();
  void NotifyLockOrSleep();
  RECT GetMonitorWorkArea(HWND hwnd) const;
  double GetScaleFactorForMonitor(HMONITOR monitor) const;
  RECT ClampRectToWorkArea(int x, int y, int width, int height,
                           const RECT& work_area) const;

  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;

  // Platform channel for orb window sizing and OS event forwarding.
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      window_channel_;

  bool is_overlay_mode_ = false;
  bool is_expanded_ = false;
  bool is_toast_showing_ = false;
  bool is_panel_pinned_ = true;
  bool is_toast_notifications_enabled_ = true;
  bool is_compact_toast_layout_ = false;
  bool expanded_above_ = false;
  bool is_native_dragging_ = false;
  bool did_move_while_expanded_ = false;
  bool has_persisted_expanded_size_ = false;
  double persisted_expanded_width_logical_ = 0.0;
  double persisted_expanded_height_logical_ = 0.0;
  bool has_collapsed_origin_ = false;
  POINT collapsed_origin_{0, 0};
  bool session_notification_registered_ = false;
  HWND registered_hwnd_ = nullptr;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
