#include <native_adaptive_toolbox/native_adaptive_toolbox_plugin.h>

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>

#include <memory>
#include <string>

namespace {
using flutter::EncodableList;
using flutter::EncodableMap;
using flutter::EncodableValue;
using Channel = flutter::MethodChannel<EncodableValue>;

// The Dart menu sends its anchor in physical pixels relative to this view.
int ShowSelectionMenu(HWND window, const EncodableMap& args) {
  const auto& rect = std::get<EncodableList>(args.at(EncodableValue("rect")));
  const auto& items = std::get<EncodableList>(args.at(EncodableValue("items")));
  POINT anchor{std::get<int>(rect.at(0)), std::get<int>(rect.at(1))};
  ClientToScreen(window, &anchor);
  HMENU menu = CreatePopupMenu();
  if (!menu) return 0;
  for (size_t i = 0; i < items.size(); ++i) {
    const auto& item = std::get<EncodableMap>(items[i]);
    const auto& text = std::get<std::string>(item.at(EncodableValue("label")));
    const int length = MultiByteToWideChar(CP_UTF8, 0, text.c_str(), -1, nullptr, 0);
    if (length <= 0) continue;
    std::wstring label(length, L'\0');
    MultiByteToWideChar(CP_UTF8, 0, text.c_str(), -1, label.data(), length);
    AppendMenuW(menu, MF_STRING, i + 1, label.c_str());
  }
  const bool right = std::get<bool>(args.at(EncodableValue("topRight")));
  const int chosen = TrackPopupMenuEx(menu, TPM_RETURNCMD | TPM_NONOTIFY |
      (right ? TPM_RIGHTALIGN : TPM_LEFTALIGN), anchor.x, anchor.y, window, nullptr);
  DestroyMenu(menu);
  return chosen;
}
}  // namespace

void NativeAdaptiveToolboxPluginRegisterWithRegistrar(FlutterDesktopPluginRegistrarRef ref) {
  auto* registrar = flutter::PluginRegistrarManager::GetInstance()
      ->GetRegistrar<flutter::PluginRegistrarWindows>(ref);
  auto channel = std::make_shared<Channel>(registrar->messenger(),
      "native_adaptive_toolbox/menu", &flutter::StandardMethodCodec::GetInstance());
  const HWND window = registrar->GetView()->GetNativeWindow();
  channel->SetMethodCallHandler([channel, window](const auto& call, auto result) {
    if (call.method_name() == "dismissMenu") {
      EndMenu();
      result->Success();
    } else if (call.method_name() == "showMenu") {
      const auto* args = std::get_if<EncodableMap>(call.arguments());
      if (!args) {
        result->Error("invalid_arguments", "Missing selection menu arguments");
        return;
      }
      const int choice = ShowSelectionMenu(window, *args);
      result->Success(EncodableValue(true));
      if (choice == 0) {
        channel->InvokeMethod("onDismiss", nullptr);
      } else {
        channel->InvokeMethod("onAction", std::make_unique<EncodableValue>(choice - 1));
      }
    } else {
      result->NotImplemented();
    }
  });
}
