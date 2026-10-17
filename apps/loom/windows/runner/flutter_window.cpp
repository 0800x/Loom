#include "flutter_window.h"

#include <flutter/standard_method_codec.h>

#include <shellapi.h>
#include <mmsystem.h>
#include <chrono>
#include <algorithm>
#include "resource.h"
#include <optional>
#include <string>

#include "flutter/generated_plugin_registrant.h"

namespace {
constexpr char kCallChannel[] = "loom/calls";
constexpr UINT kNotificationCallback = WM_APP + 41;
constexpr UINT_PTR kCallToneTimeout = 9043;
std::string ArgumentString(const flutter::EncodableValue* arguments, const char* key) {
  if (arguments == nullptr) return {};
  const auto* map = std::get_if<flutter::EncodableMap>(arguments);
  if (map == nullptr) return {};
  const auto it = map->find(flutter::EncodableValue(key));
  if (it == map->end()) return {};
  const auto* value = std::get_if<std::string>(&it->second);
  return value == nullptr ? std::string{} : *value;
}
std::wstring Wide(const std::string& text) {
  const int size = MultiByteToWideChar(CP_UTF8, 0, text.data(), static_cast<int>(text.size()), nullptr, 0);
  std::wstring result(size, L'\0');
  MultiByteToWideChar(CP_UTF8, 0, text.data(), static_cast<int>(text.size()), result.data(), size);
  return result;
}
DWORD ToneLifetime(const flutter::EncodableValue* arguments) {
  if (arguments == nullptr) return 45000;
  const auto* map = std::get_if<flutter::EncodableMap>(arguments);
  if (map == nullptr) return 45000;
  const auto it = map->find(flutter::EncodableValue("expiresAt"));
  if (it == map->end()) return 45000;
  const auto* expiry = std::get_if<int64_t>(&it->second);
  if (expiry == nullptr) return 45000;
  const auto now = std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::system_clock::now().time_since_epoch()).count();
  return static_cast<DWORD>(std::clamp<int64_t>(*expiry - now, 1, 45000));
}

void FlashCallWindow(HWND window) {
  if (window == nullptr) {
    return;
  }
  FLASHWINFO flash = {};
  flash.cbSize = sizeof(FLASHWINFO);
  flash.hwnd = window;
  flash.dwFlags = FLASHW_ALL | FLASHW_TIMERNOFG;
  flash.uCount = 0;
  flash.dwTimeout = 0;
  FlashWindowEx(&flash);

}

void StopCallWindowFlash(HWND window) {
  if (window == nullptr) {
    return;
  }
  FLASHWINFO flash = {};
  flash.cbSize = sizeof(FLASHWINFO);
  flash.hwnd = window;
  flash.dwFlags = FLASHW_STOP;
  flash.uCount = 0;
  flash.dwTimeout = 0;
  FlashWindowEx(&flash);
}
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
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  call_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), kCallChannel,
          &flutter::StandardMethodCodec::GetInstance());
  call_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        const std::string& method = call.method_name();
        if (method == "showIncoming") {
          notification_conversation_.clear();
          const auto id = ArgumentString(call.arguments(), "callId");
          if (id != incoming_id_) {
            incoming_id_ = id;
            incoming_tone_ = true;
            PlayCallTone(true);
            SetTimer(GetHandle(), kCallToneTimeout, ToneLifetime(call.arguments()), nullptr);
            ShowNotification(Wide(ArgumentString(call.arguments(), "callerName")), L"Incoming Loom call");
          }
          FlashCallWindow(GetHandle());
          result->Success();
          return;
        }
        if (method == "clearIncoming") {
          if (ArgumentString(call.arguments(), "callId") == incoming_id_) {
            StopCallTone();
            incoming_id_.clear();
            StopCallWindowFlash(GetHandle());
          }
          result->Success();
          return;
        }
        if (method == "setRingback") {
          const auto* map = call.arguments() == nullptr ? nullptr : std::get_if<flutter::EncodableMap>(call.arguments());
          bool playing = false;
          if (map != nullptr) {
            const auto it = map->find(flutter::EncodableValue("playing"));
            if (it != map->end()) { const auto* value = std::get_if<bool>(&it->second); playing = value != nullptr && *value; }
          }
          if (!incoming_tone_) {
            if (playing) { PlayCallTone(false); SetTimer(GetHandle(), kCallToneTimeout, 45000, nullptr); }
            else StopCallTone();
          }
          result->Success(); return;
        }
        if (method == "stopOngoing") StopCallTone();
        if (method == "prepare" ||
            method == "requestNotificationPermission" ||
            method == "startOngoing" || method == "stopOngoing") {
          // Windows does not require a runtime notification permission for the
          // taskbar attention behavior, and WebRTC media lifetime is owned by
          // the Flutter desktop process rather than an Android-style service.
          result->Success();
          return;
        }
        result->NotImplemented();
      });

  notification_channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      flutter_controller_->engine()->messenger(), "loom/notifications", &flutter::StandardMethodCodec::GetInstance());
  notification_channel_->SetMethodCallHandler([this](const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
    const auto& method = call.method_name();
    if (method == "prepare" || method == "enable") { result->Success(); return; }
    if (method == "status") {
      result->Success(flutter::EncodableValue(flutter::EncodableMap{{flutter::EncodableValue("supported"), flutter::EncodableValue(true)}, {flutter::EncodableValue("push"), flutter::EncodableValue(false)}})); return;
    }
    if (method == "openSettings") { ShellExecuteW(GetHandle(), L"open", L"ms-settings:notifications", nullptr, nullptr, SW_SHOWNORMAL); result->Success(); return; }
    if (method == "showMessage") {
      notification_conversation_ = ArgumentString(call.arguments(), "conversationId");
      ShowNotification(Wide(ArgumentString(call.arguments(), "title")), L"New encrypted message");
      result->Success(); return;
    }
    if (method == "clearMessage") {
      const auto* id = call.arguments() == nullptr ? nullptr : std::get_if<std::string>(call.arguments());
      if (id != nullptr && *id == notification_conversation_) notification_conversation_.clear();
      result->Success(); return;
    }
    result->NotImplemented();
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
  StopCallTone();
  if (tray_added_) { NOTIFYICONDATAW icon = {}; icon.cbSize = sizeof(icon); icon.hWnd = GetHandle(); icon.uID = 1; Shell_NotifyIconW(NIM_DELETE, &icon); tray_added_ = false; }
  notification_channel_.reset();
  call_channel_.reset();
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

  if (message == kNotificationCallback) {
    if (lparam == NIN_BALLOONUSERCLICK || lparam == WM_LBUTTONUP) {
      ShowWindow(GetHandle(), SW_RESTORE); SetForegroundWindow(GetHandle());
      if (notification_channel_ && !notification_conversation_.empty()) {
        // Shell balloons share an icon and do not carry a per-message action
        // token. Open the inbox instead of guessing which queued balloon was clicked.
        notification_channel_->InvokeMethod("openInbox", nullptr);
        notification_conversation_.clear();
      }
    }
    return 0;
  }
  if (message == WM_TIMER && wparam == kCallToneTimeout) { StopCallTone(); StopCallWindowFlash(GetHandle()); return 0; }
  switch (message) {
    case WM_FONTCHANGE:
      if (flutter_controller_) {
        flutter_controller_->engine()->ReloadSystemFonts();
      }
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}

void FlutterWindow::ShowNotification(const std::wstring& title, const std::wstring& body) {
  NOTIFYICONDATAW icon = {}; icon.cbSize = sizeof(icon); icon.hWnd = GetHandle(); icon.uID = 1;
  icon.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP | NIF_INFO; icon.uCallbackMessage = kNotificationCallback;
  icon.hIcon = LoadIcon(GetModuleHandle(nullptr), MAKEINTRESOURCE(IDI_APP_ICON));
  wcsncpy_s(icon.szTip, L"Loom", _TRUNCATE);
  wcsncpy_s(icon.szInfoTitle, title.empty() ? L"Loom" : title.c_str(), _TRUNCATE);
  wcsncpy_s(icon.szInfo, body.c_str(), _TRUNCATE);
  icon.dwInfoFlags = NIIF_INFO;
  if (!tray_added_) tray_added_ = Shell_NotifyIconW(NIM_ADD, &icon) != FALSE;
  else Shell_NotifyIconW(NIM_MODIFY, &icon);
}
void FlutterWindow::PlayCallTone(bool incoming) {
  wchar_t path[MAX_PATH] = {};
  GetModuleFileNameW(nullptr, path, MAX_PATH);
  std::wstring file(path); const auto slash = file.find_last_of(L"\\/");
  file = file.substr(0, slash + 1) + L"data\\flutter_assets\\assets\\audio\\" + (incoming ? L"incoming_call.wav" : L"outgoing_call.wav");
  PlaySoundW(file.c_str(), nullptr, SND_FILENAME | SND_ASYNC | SND_LOOP | SND_NODEFAULT);
}
void FlutterWindow::StopCallTone() {
  KillTimer(GetHandle(), kCallToneTimeout);
  PlaySoundW(nullptr, nullptr, 0);
  incoming_tone_ = false;
}
