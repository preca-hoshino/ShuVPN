#include "include/flutter_sangfor/flutter_sangfor_plugin_c_api.h"

#include <flutter/plugin_registrar_windows.h>

#include "flutter_sangfor_plugin.h"

void FlutterSangforPluginCApiRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar) {
  flutter_sangfor::FlutterSangforPlugin::RegisterWithRegistrar(
      flutter::PluginRegistrarManager::GetInstance()
          ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar));
}
