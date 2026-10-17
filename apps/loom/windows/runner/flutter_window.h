#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <memory>

#include "win32_window.h"

// A window that hosts the Loom Flutter view and native desktop integrations.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;

  // Native call-attention bridge used by LoomCallPlatformBridge. Windows
  // currently provides taskbar attention while the Flutter process is alive;
  // actionable lock-screen toasts require a packaged notification activation
  // model and are deliberately not claimed here.
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> call_channel_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> notification_channel_;
  bool tray_added_ = false;
  bool incoming_tone_ = false;
  std::string incoming_id_;
  std::string notification_conversation_;
  void ShowNotification(const std::wstring& title, const std::wstring& body);
  void PlayCallTone(bool incoming);
  void StopCallTone();
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
