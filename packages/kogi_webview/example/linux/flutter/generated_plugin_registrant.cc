//
//  Generated file. Do not edit.
//

// clang-format off

#include "generated_plugin_registrant.h"

#include <kogi_webview/kogi_webview_plugin.h>

void fl_register_plugins(FlPluginRegistry* registry) {
  g_autoptr(FlPluginRegistrar) kogi_webview_registrar =
      fl_plugin_registry_get_registrar_for_plugin(registry, "KogiWebviewPlugin");
  kogi_webview_plugin_register_with_registrar(kogi_webview_registrar);
}
