#include "flutter_sangfor_plugin.h"

// This must be included before many other Windows headers.
#include <windows.h>

// For getPlatformVersion; remove unless needed for your plugin implementation.
#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>

#include <memory>

namespace flutter_sangfor {

namespace {
std::string state = "disconnected";
}

// static
void FlutterSangforPlugin::RegisterWithRegistrar(
    flutter::PluginRegistrarWindows *registrar) {
  auto channel =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          registrar->messenger(), "flutter_sangfor",
          &flutter::StandardMethodCodec::GetInstance());

  auto plugin = std::make_unique<FlutterSangforPlugin>();

  channel->SetMethodCallHandler(
      [plugin_pointer = plugin.get()](const auto &call, auto result) {
        plugin_pointer->HandleMethodCall(call, std::move(result));
      });

  registrar->AddPlugin(std::move(plugin));
}

FlutterSangforPlugin::FlutterSangforPlugin() {}

FlutterSangforPlugin::~FlutterSangforPlugin() {}

void FlutterSangforPlugin::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue> &method_call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  if (method_call.method_name().compare("getState") == 0) {
    result->Success(flutter::EncodableValue(state));
  } else if (method_call.method_name().compare("getCapabilities") == 0) {
    flutter::EncodableMap capabilities;
    capabilities[flutter::EncodableValue("platform")] = flutter::EncodableValue("windows");
    capabilities[flutter::EncodableValue("supportsVpn")] = flutter::EncodableValue(false);
    capabilities[flutter::EncodableValue("supportsTun")] = flutter::EncodableValue(false);
    capabilities[flutter::EncodableValue("supportsSocks5")] = flutter::EncodableValue(false);
    capabilities[flutter::EncodableValue("supportedAuthTypes")] = flutter::EncodableValue(flutter::EncodableList());
    result->Success(flutter::EncodableValue(capabilities));
  } else if (method_call.method_name().compare("disconnect") == 0) {
    state = "disconnected";
    result->Success();
  } else if (method_call.method_name().compare("connect") == 0) {
    result->Error("unsupported", "The aTrust transport is not implemented on Windows yet.");
  } else {
    result->NotImplemented();
  }
}

}  // namespace flutter_sangfor
