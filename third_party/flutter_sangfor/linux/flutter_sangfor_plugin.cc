#include "include/flutter_sangfor/flutter_sangfor_plugin.h"

#include <flutter_linux/flutter_linux.h>
#include <gtk/gtk.h>
#include <sys/utsname.h>

#include <cstring>

#include "flutter_sangfor_plugin_private.h"

#define FLUTTER_SANGFOR_PLUGIN(obj) \
  (G_TYPE_CHECK_INSTANCE_CAST((obj), flutter_sangfor_plugin_get_type(), \
                              FlutterSangforPlugin))

struct _FlutterSangforPlugin {
  GObject parent_instance;
};

static const gchar* connection_state = "disconnected";

G_DEFINE_TYPE(FlutterSangforPlugin, flutter_sangfor_plugin, g_object_get_type())

// Called when a method call is received from Flutter.
static void flutter_sangfor_plugin_handle_method_call(
    FlutterSangforPlugin* self,
    FlMethodCall* method_call) {
  g_autoptr(FlMethodResponse) response = nullptr;

  const gchar* method = fl_method_call_get_name(method_call);

  if (strcmp(method, "getState") == 0) {
    g_autoptr(FlValue) value = fl_value_new_string(connection_state);
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(value));
  } else if (strcmp(method, "getCapabilities") == 0) {
    g_autoptr(FlValue) capabilities = fl_value_new_map();
    fl_value_set_string_take(capabilities, "platform", fl_value_new_string("linux"));
    fl_value_set_string_take(capabilities, "supportsVpn", fl_value_new_bool(FALSE));
    fl_value_set_string_take(capabilities, "supportsTun", fl_value_new_bool(FALSE));
    fl_value_set_string_take(capabilities, "supportsSocks5", fl_value_new_bool(FALSE));
    fl_value_set_string_take(capabilities, "supportedAuthTypes", fl_value_new_list());
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(capabilities));
  } else if (strcmp(method, "disconnect") == 0) {
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
  } else if (strcmp(method, "connect") == 0) {
    response = FL_METHOD_RESPONSE(fl_method_error_response_new(
        "unsupported", "The aTrust transport is not implemented on Linux yet.", nullptr));
  } else {
    response = FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
  }

  fl_method_call_respond(method_call, response, nullptr);
}

FlMethodResponse* get_platform_version() {
  struct utsname uname_data = {};
  uname(&uname_data);
  g_autofree gchar *version = g_strdup_printf("Linux %s", uname_data.version);
  g_autoptr(FlValue) result = fl_value_new_string(version);
  return FL_METHOD_RESPONSE(fl_method_success_response_new(result));
}

static void flutter_sangfor_plugin_dispose(GObject* object) {
  G_OBJECT_CLASS(flutter_sangfor_plugin_parent_class)->dispose(object);
}

static void flutter_sangfor_plugin_class_init(FlutterSangforPluginClass* klass) {
  G_OBJECT_CLASS(klass)->dispose = flutter_sangfor_plugin_dispose;
}

static void flutter_sangfor_plugin_init(FlutterSangforPlugin* self) {}

static void method_call_cb(FlMethodChannel* channel, FlMethodCall* method_call,
                           gpointer user_data) {
  FlutterSangforPlugin* plugin = FLUTTER_SANGFOR_PLUGIN(user_data);
  flutter_sangfor_plugin_handle_method_call(plugin, method_call);
}

void flutter_sangfor_plugin_register_with_registrar(FlPluginRegistrar* registrar) {
  FlutterSangforPlugin* plugin = FLUTTER_SANGFOR_PLUGIN(
      g_object_new(flutter_sangfor_plugin_get_type(), nullptr));

  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  g_autoptr(FlMethodChannel) channel =
      fl_method_channel_new(fl_plugin_registrar_get_messenger(registrar),
                            "flutter_sangfor",
                            FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(channel, method_call_cb,
                                            g_object_ref(plugin),
                                            g_object_unref);

  g_object_unref(plugin);
}
