#include "colecto_webview.h"

#include <webkit2/webkit2.h>

#include <cmath>
#include <cstring>

static constexpr const char* kChannelName = "com.kogical.colecto/webview";

struct _ColectoWebViewHost {
  FlMethodChannel* channel;
  GtkOverlay* overlay;
  WebKitWebView* webview;
  int x;
  int y;
  int width;
  int height;
  bool visible;
};

static bool is_external_scheme(const char* uri) {
  if (uri == nullptr) return false;
  return g_str_has_prefix(uri, "http://") ||
         g_str_has_prefix(uri, "https://") ||
         g_str_has_prefix(uri, "mailto:");
}

static gboolean on_decide_policy(WebKitWebView* /*web_view*/,
                                 WebKitPolicyDecision* decision,
                                 WebKitPolicyDecisionType decision_type,
                                 gpointer user_data) {
  auto* host = static_cast<ColectoWebViewHost*>(user_data);
  if (decision_type != WEBKIT_POLICY_DECISION_TYPE_NAVIGATION_ACTION &&
      decision_type != WEBKIT_POLICY_DECISION_TYPE_NEW_WINDOW_ACTION) {
    return FALSE;
  }

  auto* nav_decision = WEBKIT_NAVIGATION_POLICY_DECISION(decision);
  WebKitNavigationAction* action =
      webkit_navigation_policy_decision_get_navigation_action(nav_decision);
  WebKitURIRequest* request = webkit_navigation_action_get_request(action);
  const char* uri = webkit_uri_request_get_uri(request);

  if (uri == nullptr || std::strcmp(uri, "about:blank") == 0) {
    webkit_policy_decision_use(decision);
    return TRUE;
  }

  // Intercept every external link and hand it to Flutter -> OS browser.
  if (is_external_scheme(uri) ||
      decision_type == WEBKIT_POLICY_DECISION_TYPE_NEW_WINDOW_ACTION ||
      webkit_navigation_action_get_navigation_type(action) ==
          WEBKIT_NAVIGATION_TYPE_LINK_CLICKED) {
    webkit_policy_decision_ignore(decision);
    if (is_external_scheme(uri) && host->channel != nullptr) {
      g_autoptr(FlValue) arg = fl_value_new_string(uri);
      fl_method_channel_invoke_method(host->channel, "openUrl", arg, nullptr,
                                      nullptr, nullptr);
    }
    return TRUE;
  }

  webkit_policy_decision_ignore(decision);
  return TRUE;
}

static void ensure_webview(ColectoWebViewHost* host) {
  if (host->webview != nullptr) return;

  g_autoptr(WebKitWebContext) context = webkit_web_context_new_ephemeral();
  g_autoptr(WebKitSettings) settings = webkit_settings_new();
  webkit_settings_set_enable_javascript(settings, FALSE);
  webkit_settings_set_enable_developer_extras(settings, FALSE);
  webkit_settings_set_enable_write_console_messages_to_stdout(settings, FALSE);
  webkit_settings_set_enable_html5_database(settings, FALSE);
  webkit_settings_set_enable_html5_local_storage(settings, FALSE);
  webkit_settings_set_hardware_acceleration_policy(
      settings, WEBKIT_HARDWARE_ACCELERATION_POLICY_NEVER);

  host->webview = WEBKIT_WEB_VIEW(g_object_new(
      WEBKIT_TYPE_WEB_VIEW, "web-context", context, "settings", settings,
      nullptr));
  g_signal_connect(host->webview, "decide-policy",
                   G_CALLBACK(on_decide_policy), host);
  GtkWidget* widget = GTK_WIDGET(host->webview);
  gtk_widget_set_halign(widget, GTK_ALIGN_START);
  gtk_widget_set_valign(widget, GTK_ALIGN_START);
  gtk_overlay_add_overlay(host->overlay, widget);
}

static void destroy_webview(ColectoWebViewHost* host) {
  if (host->webview == nullptr) return;
  gtk_widget_destroy(GTK_WIDGET(host->webview));
  host->webview = nullptr;
  host->visible = false;
}

static void apply_geometry(ColectoWebViewHost* host, int x, int y, int width,
                           int height, bool visible) {
  host->x = x;
  host->y = y;
  host->width = width;
  host->height = height;
  host->visible = visible;

  if (host->webview == nullptr) return;
  GtkWidget* widget = GTK_WIDGET(host->webview);
  if (!visible || width <= 1 || height <= 1) {
    gtk_widget_hide(widget);
    return;
  }
  gtk_widget_set_margin_start(widget, x > 0 ? x : 0);
  gtk_widget_set_margin_top(widget, y > 0 ? y : 0);
  gtk_widget_set_size_request(widget, width, height);
  gtk_widget_show(widget);
  gtk_widget_queue_draw(widget);
}

static int get_int_arg(FlValue* args, const char* key, int fallback = 0) {
  FlValue* v = fl_value_lookup_string(args, key);
  if (v == nullptr) return fallback;
  if (fl_value_get_type(v) == FL_VALUE_TYPE_INT) {
    return static_cast<int>(fl_value_get_int(v));
  }
  if (fl_value_get_type(v) == FL_VALUE_TYPE_FLOAT) {
    return static_cast<int>(std::lround(fl_value_get_float(v)));
  }
  return fallback;
}

static bool get_bool_arg(FlValue* args, const char* key, bool fallback = true) {
  FlValue* v = fl_value_lookup_string(args, key);
  if (v == nullptr || fl_value_get_type(v) != FL_VALUE_TYPE_BOOL) {
    return fallback;
  }
  return fl_value_get_bool(v);
}

static const char* get_string_arg(FlValue* args, const char* key) {
  FlValue* v = fl_value_lookup_string(args, key);
  if (v == nullptr || fl_value_get_type(v) != FL_VALUE_TYPE_STRING) {
    return nullptr;
  }
  return fl_value_get_string(v);
}

static void method_call_cb(FlMethodChannel* /*channel*/,
                           FlMethodCall* method_call, gpointer user_data) {
  auto* host = static_cast<ColectoWebViewHost*>(user_data);
  const gchar* method = fl_method_call_get_name(method_call);
  FlValue* args = fl_method_call_get_args(method_call);

  if (std::strcmp(method, "loadHtml") == 0 && args != nullptr &&
      fl_value_get_type(args) == FL_VALUE_TYPE_MAP) {
    const char* html = get_string_arg(args, "html");
    const char* bg = get_string_arg(args, "bg");
    int x = get_int_arg(args, "x");
    int y = get_int_arg(args, "y");
    int width = get_int_arg(args, "width");
    int height = get_int_arg(args, "height");
    bool visible = get_bool_arg(args, "visible", true);

    ensure_webview(host);
    if (bg != nullptr) {
      GdkRGBA rgba;
      if (gdk_rgba_parse(&rgba, bg)) {
        webkit_web_view_set_background_color(host->webview, &rgba);
      }
    }
    apply_geometry(host, x, y, width, height, visible);
    webkit_web_view_load_html(host->webview, html != nullptr ? html : "",
                              "about:blank");
    g_autoptr(FlValue) ok = fl_value_new_bool(TRUE);
    fl_method_call_respond_success(method_call, ok, nullptr);
    return;
  }

  if (std::strcmp(method, "updateRect") == 0 && args != nullptr &&
      fl_value_get_type(args) == FL_VALUE_TYPE_MAP) {
    int x = get_int_arg(args, "x", host->x);
    int y = get_int_arg(args, "y", host->y);
    int width = get_int_arg(args, "width", host->width);
    int height = get_int_arg(args, "height", host->height);
    bool visible = get_bool_arg(args, "visible", true);
    apply_geometry(host, x, y, width, height, visible);
    fl_method_call_respond_success(method_call, nullptr, nullptr);
    return;
  }

  if (std::strcmp(method, "hide") == 0) {
    if (host->webview != nullptr) {
      gtk_widget_hide(GTK_WIDGET(host->webview));
      host->visible = false;
    }
    fl_method_call_respond_success(method_call, nullptr, nullptr);
    return;
  }

  if (std::strcmp(method, "dispose") == 0) {
    destroy_webview(host);
    fl_method_call_respond_success(method_call, nullptr, nullptr);
    return;
  }

  fl_method_call_respond_not_implemented(method_call, nullptr);
}

ColectoWebViewHost* colecto_webview_host_new(FlView* view,
                                             GtkOverlay* overlay) {
  auto* host = g_new0(ColectoWebViewHost, 1);
  host->overlay = overlay;

  FlEngine* engine = fl_view_get_engine(view);
  FlBinaryMessenger* messenger = fl_engine_get_binary_messenger(engine);
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  host->channel = fl_method_channel_new(messenger, kChannelName,
                                        FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(host->channel, method_call_cb, host,
                                            nullptr);
  return host;
}

void colecto_webview_host_dispose(ColectoWebViewHost* host) {
  if (host == nullptr) return;
  destroy_webview(host);
  g_clear_object(&host->channel);
  g_free(host);
}
