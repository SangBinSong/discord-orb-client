#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/encodable_value.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>

#include <memory>

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
  void ConfigureOverlayWindow(HWND hwnd);
  void RegisterWindowChannel();
  void HandleWindowMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  void ShowCollapsedOrb();
  void ExpandPanel(double width, double height);
  void HideOrb();
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

  bool is_expanded_ = false;
  bool has_collapsed_origin_ = false;
  POINT collapsed_origin_{0, 0};
  bool session_notification_registered_ = false;
  HWND registered_hwnd_ = nullptr;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
