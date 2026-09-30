#ifndef FLUTTER_PLUGIN_FLUTTER_SANGFOR_PLUGIN_H_
#define FLUTTER_PLUGIN_FLUTTER_SANGFOR_PLUGIN_H_

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>

#include <memory>

namespace flutter_sangfor {

class FlutterSangforPlugin : public flutter::Plugin {
 public:
  static void RegisterWithRegistrar(flutter::PluginRegistrarWindows *registrar);

  FlutterSangforPlugin();

  virtual ~FlutterSangforPlugin();

  // Disallow copy and assign.
  FlutterSangforPlugin(const FlutterSangforPlugin&) = delete;
  FlutterSangforPlugin& operator=(const FlutterSangforPlugin&) = delete;

  // Called when a method is called on this plugin's channel from Dart.
  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue> &method_call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
};

}  // namespace flutter_sangfor

#endif  // FLUTTER_PLUGIN_FLUTTER_SANGFOR_PLUGIN_H_
