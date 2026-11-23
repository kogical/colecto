// kogi_webview: live WebKitGTK views composited *under* Flutter on Linux.
//
// Flutter >= 3.50 renders into a Wayland subsurface stacked above the GTK
// window, so a GTK widget can only be seen where Flutter leaves transparent
// pixels. Each view therefore lives in a GtkOverlay child under the FlView and
// shows through a hole that the Dart widget clears in Flutter's frame. On X11
// Flutter draws into the GTK window itself and overlay children paint on top,
// so there we hide covered views and shape around occluders instead.
//
// Every view sits in its own GtkLayout, which clips both its pixels and its
// input to the visible part of the slot, while the WebKitWebView inside keeps
// its full content size and is moved synchronously as Flutter scrolls.
#include "include/kogi_webview/kogi_webview_plugin.h"

#include <gtk/gtk.h>
#ifdef GDK_WINDOWING_WAYLAND
#include <gdk/gdkwayland.h>
#endif
#include <webkit2/webkit2.h>

#include <cmath>
#include <cstring>

namespace {

constexpr char kChannel[] = "kogi_webview";
constexpr char kFilterId[] = "kogi-block-network";
// Blocks every network fetch; data:, cid-rewritten and about: content loads.
// One rule per scheme: WebKit's content-blocker regexes reject disjunctions.
constexpr char kBlockNetworkRules[] =
    R"([{"trigger":{"url-filter":"^https?://"},"action":{"type":"block"}},)"
    R"({"trigger":{"url-filter":"^wss?://"},"action":{"type":"block"}},)"
    R"({"trigger":{"url-filter":"^ftp://"},"action":{"type":"block"}}])";

struct KogiView;

struct Plugin {
  FlMethodChannel* channel = nullptr;
  FlView* view = nullptr;
  GtkOverlay* overlay = nullptr;
  bool wayland = false;
  GHashTable* views = nullptr;  // int64 id -> KogiView*
  WebKitWebContext* context = nullptr;
  WebKitUserContentFilter* block_filter = nullptr;
  bool filter_pending = true;  // compiling; loads that need it wait
  cairo_region_t* occluders = nullptr;  // window coords
  // Keys handed to Flutter that it may give back (see on_key).
  GdkEventKey forwarded[16] = {};
  guint forwarded_next = 0;
};

struct KogiView {
  Plugin* plugin = nullptr;
  int64_t id = 0;
  GtkWidget* clip = nullptr;  // GtkLayout: clips pixels + input
  GtkWidget* web = nullptr;   // WebKitWebView at full slot size
  GdkRectangle visible = {0, 0, 0, 0};  // window coords
  int width = 0;
  double zoom = 1;
  bool shown = false;
  bool covered = false;
  bool internal_scroll = false;
  bool block_network = true;
  gchar* pending_html = nullptr;  // waiting for the network filter
};

Plugin* g_plugin = nullptr;

// ── Helpers ────────────────────────────────────────────────────────────────

FlValue* arg(FlValue* args, const char* key) {
  return args != nullptr && fl_value_get_type(args) == FL_VALUE_TYPE_MAP
             ? fl_value_lookup_string(args, key)
             : nullptr;
}

double num(FlValue* args, const char* key, double fallback = 0) {
  FlValue* v = arg(args, key);
  if (v == nullptr) return fallback;
  switch (fl_value_get_type(v)) {
    case FL_VALUE_TYPE_FLOAT: return fl_value_get_float(v);
    case FL_VALUE_TYPE_INT: return static_cast<double>(fl_value_get_int(v));
    default: return fallback;
  }
}

bool flag(FlValue* args, const char* key, bool fallback = false) {
  FlValue* v = arg(args, key);
  return v != nullptr && fl_value_get_type(v) == FL_VALUE_TYPE_BOOL
             ? fl_value_get_bool(v)
             : fallback;
}

const char* str(FlValue* args, const char* key) {
  FlValue* v = arg(args, key);
  return v != nullptr && fl_value_get_type(v) == FL_VALUE_TYPE_STRING
             ? fl_value_get_string(v)
             : nullptr;
}

int rounded(double v) { return static_cast<int>(v >= 0 ? v + 0.5 : v - 0.5); }

// Flutter lays out on fractional logical pixels (a centered column often
// starts at x.5) but GTK places widgets on whole ones. Round the view
// outward so it always covers the whole hole and no half-cleared seam shows.
GdkRectangle outward(double x, double y, double w, double h) {
  const int left = static_cast<int>(std::floor(x));
  const int top = static_cast<int>(std::floor(y));
  return {left, top, static_cast<int>(std::ceil(x + w)) - left,
          static_cast<int>(std::ceil(y + h)) - top};
}

KogiView* lookup(FlValue* args) {
  int64_t id = static_cast<int64_t>(num(args, "id", -1));
  return static_cast<KogiView*>(
      g_hash_table_lookup(g_plugin->views, &id));
}

void send(const char* method, FlValue* args) {
  fl_method_channel_invoke_method(g_plugin->channel, method, args, nullptr,
                                  nullptr, nullptr);
}

FlValue* event_for(KogiView* v) {
  FlValue* map = fl_value_new_map();
  fl_value_set_string_take(map, "id", fl_value_new_int(v->id));
  return map;
}

void to_view_coords(GtkWidget* from, double x, double y, double* vx,
                    double* vy) {
  int ix = 0, iy = 0;
  gtk_widget_translate_coordinates(from, GTK_WIDGET(g_plugin->view),
                                   rounded(x), rounded(y), &ix, &iy);
  *vx = ix;
  *vy = iy;
}

// ── Input and visual shape ─────────────────────────────────────────────────

// The clip receives input only where it is visible and no Flutter occluder
// (a toast, a popover) sits above it. On X11, where WebKit paints over
// Flutter, the same region also shapes what WebKit draws.
void apply_shape(KogiView* v) {
  if (!v->shown) return;
  cairo_region_t* region = cairo_region_create();
  if (!v->covered) {
    cairo_rectangle_int_t all = {0, 0, v->visible.width, v->visible.height};
    cairo_region_union_rectangle(region, &all);
    if (g_plugin->occluders != nullptr) {
      cairo_region_t* occ = cairo_region_copy(g_plugin->occluders);
      cairo_region_translate(occ, -v->visible.x, -v->visible.y);
      cairo_region_subtract(region, occ);
      cairo_region_destroy(occ);
    }
  }
  gtk_widget_input_shape_combine_region(v->clip, region);
  if (!g_plugin->wayland) {
    gtk_widget_shape_combine_region(v->clip, v->covered ? nullptr : region);
    gtk_widget_set_child_visible(v->clip, !v->covered);
  }
  cairo_region_destroy(region);
}

// ── WebKit signals ─────────────────────────────────────────────────────────

void on_height(GObject* source, GAsyncResult* result, gpointer data) {
  int64_t id = GPOINTER_TO_SIZE(data);
  g_autoptr(GError) error = nullptr;
  g_autoptr(JSCValue) value = webkit_web_view_evaluate_javascript_finish(
      WEBKIT_WEB_VIEW(source), result, &error);
  if (value == nullptr || g_plugin == nullptr) return;
  auto* v = static_cast<KogiView*>(g_hash_table_lookup(g_plugin->views, &id));
  if (v == nullptr) return;
  g_autoptr(FlValue) ev = event_for(v);
  fl_value_set_string_take(ev, "height",
                           fl_value_new_float(jsc_value_to_double(value)));
  send("height", ev);
}

// Measures content height in an isolated world; page scripts stay off.
// body.scrollHeight tracks content rather than the view, so the height can
// shrink again after a reflow.
void probe_height(KogiView* v) {
  static const char kScript[] =
      "Math.ceil(Math.max(document.body ? document.body.scrollHeight : 0,"
      " document.body ? document.body.getBoundingClientRect().bottom : 0))";
  webkit_web_view_evaluate_javascript(
      WEBKIT_WEB_VIEW(v->web), kScript, -1, "kogi-webview-probe", nullptr,
      nullptr, on_height, GSIZE_TO_POINTER(static_cast<gsize>(v->id)));
}

gboolean probe_later(gpointer data) {
  int64_t id = GPOINTER_TO_SIZE(data);
  if (g_plugin == nullptr) return G_SOURCE_REMOVE;
  auto* v = static_cast<KogiView*>(g_hash_table_lookup(g_plugin->views, &id));
  if (v != nullptr) probe_height(v);
  return G_SOURCE_REMOVE;
}

void on_load_changed(WebKitWebView*, WebKitLoadEvent event, gpointer data) {
  if (event == WEBKIT_LOAD_FINISHED) probe_height(static_cast<KogiView*>(data));
}

// Never navigate: every link goes to Flutter, which opens it elsewhere.
gboolean on_decide_policy(WebKitWebView*, WebKitPolicyDecision* decision,
                          WebKitPolicyDecisionType type, gpointer data) {
  if (type != WEBKIT_POLICY_DECISION_TYPE_NAVIGATION_ACTION &&
      type != WEBKIT_POLICY_DECISION_TYPE_NEW_WINDOW_ACTION) {
    return FALSE;
  }
  auto* nav = WEBKIT_NAVIGATION_POLICY_DECISION(decision);
  WebKitNavigationAction* action =
      webkit_navigation_policy_decision_get_navigation_action(nav);
  const char* uri =
      webkit_uri_request_get_uri(webkit_navigation_action_get_request(action));
  if (type == WEBKIT_POLICY_DECISION_TYPE_NAVIGATION_ACTION &&
      webkit_navigation_action_get_navigation_type(action) ==
          WEBKIT_NAVIGATION_TYPE_OTHER &&
      uri != nullptr && std::strcmp(uri, "about:blank") == 0) {
    webkit_policy_decision_use(decision);  // our own load_html()
    return TRUE;
  }
  webkit_policy_decision_ignore(decision);
  if (uri != nullptr && webkit_navigation_action_is_user_gesture(action)) {
    auto* v = static_cast<KogiView*>(data);
    g_autoptr(FlValue) ev = event_for(v);
    fl_value_set_string_take(ev, "url", fl_value_new_string(uri));
    send("link", ev);
  }
  return TRUE;
}

// Wheel and touchpad over a content-sized view scroll the Flutter page.
gboolean on_scroll(GtkWidget* widget, GdkEventScroll* event, gpointer data) {
  auto* v = static_cast<KogiView*>(data);
  if (v->internal_scroll) return FALSE;
  double dx = 0, dy = 0;
  switch (event->direction) {
    case GDK_SCROLL_UP: dy = -1; break;
    case GDK_SCROLL_DOWN: dy = 1; break;
    case GDK_SCROLL_LEFT: dx = -1; break;
    case GDK_SCROLL_RIGHT: dx = 1; break;
    case GDK_SCROLL_SMOOTH:
      gdk_event_get_scroll_deltas(reinterpret_cast<GdkEvent*>(event), &dx,
                                  &dy);
      break;
    default: return FALSE;
  }
  double x = 0, y = 0;
  to_view_coords(widget, event->x, event->y, &x, &y);
  g_autoptr(FlValue) ev = event_for(v);
  fl_value_set_string_take(ev, "x", fl_value_new_float(x));
  fl_value_set_string_take(ev, "y", fl_value_new_float(y));
  fl_value_set_string_take(ev, "dx", fl_value_new_float(dx));
  fl_value_set_string_take(ev, "dy", fl_value_new_float(dy));
  send("scroll", ev);
  return TRUE;
}

// A focused email view gets keys only after Flutter: the app's shortcuts
// (S, A, Ctrl+K…) work wherever the click went. Flutter puts back each key it
// does not use as the same event (`gdk_event_put`); WebKit then handles it, so
// copying a selection, Space and Page Down still work in the email.
bool same_key(const GdkEventKey& a, const GdkEventKey* b) {
  return a.type == b->type && a.time == b->time &&
         a.hardware_keycode == b->hardware_keycode && a.state == b->state;
}

gboolean on_key(GtkWidget*, GdkEvent* event, gpointer) {
  if (g_plugin == nullptr || g_plugin->view == nullptr) return FALSE;
  auto* key = reinterpret_cast<GdkEventKey*>(event);
  for (auto& seen : g_plugin->forwarded) {
    if (same_key(seen, key)) {
      seen = {};
      return FALSE;  // Flutter gave it back: WebKit's turn.
    }
  }
  g_plugin->forwarded[g_plugin->forwarded_next++ % 16] = *key;
  gtk_widget_event(GTK_WIDGET(g_plugin->view), event);
  return TRUE;
}

// Replace WebKit's GTK menu (Back, Reload, Inspect…) with a Flutter one.
gboolean on_context_menu(WebKitWebView* web, WebKitContextMenu*,
                         GdkEvent* event, WebKitHitTestResult* hit,
                         gpointer data) {
  auto* v = static_cast<KogiView*>(data);
  double ex = 0, ey = 0;
  if (event == nullptr || !gdk_event_get_coords(event, &ex, &ey)) {
    ex = 0;
    ey = 0;
  }
  double x = 0, y = 0;
  to_view_coords(GTK_WIDGET(web), ex, ey, &x, &y);
  g_autoptr(FlValue) ev = event_for(v);
  fl_value_set_string_take(ev, "x", fl_value_new_float(x));
  fl_value_set_string_take(ev, "y", fl_value_new_float(y));
  const char* link = webkit_hit_test_result_context_is_link(hit)
                         ? webkit_hit_test_result_get_link_uri(hit)
                         : nullptr;
  fl_value_set_string_take(
      ev, "link", link ? fl_value_new_string(link) : fl_value_new_null());
  fl_value_set_string_take(
      ev, "hasSelection",
      fl_value_new_bool(webkit_hit_test_result_context_is_selection(hit)));
  send("contextMenu", ev);
  return TRUE;
}

// ── View lifecycle ─────────────────────────────────────────────────────────

void load(KogiView* v, const char* html) {
  WebKitUserContentManager* ucm =
      webkit_web_view_get_user_content_manager(WEBKIT_WEB_VIEW(v->web));
  if (v->block_network && g_plugin->filter_pending) {
    g_free(v->pending_html);
    v->pending_html = g_strdup(html);
    return;
  }
  webkit_user_content_manager_remove_all_filters(ucm);
  if (v->block_network) {
    if (g_plugin->block_filter == nullptr) {
      // Fail closed: without the filter this page could fetch remotely.
      g_autoptr(FlValue) ev = event_for(v);
      send("unavailable", ev);
      return;
    }
    webkit_user_content_manager_add_filter(ucm, g_plugin->block_filter);
  }
  webkit_web_view_load_html(WEBKIT_WEB_VIEW(v->web), html, "about:blank");
}

void on_filter_ready(GObject* source, GAsyncResult* result, gpointer) {
  g_autoptr(GError) error = nullptr;
  WebKitUserContentFilter* filter = webkit_user_content_filter_store_save_finish(
      WEBKIT_USER_CONTENT_FILTER_STORE(source), result, &error);
  if (g_plugin == nullptr) {
    if (filter != nullptr) webkit_user_content_filter_unref(filter);
    return;
  }
  if (filter == nullptr) {
    // Views that block the network now report themselves unavailable.
    g_warning("kogi_webview: network filter unavailable: %s",
              error ? error->message : "unknown error");
  }
  g_plugin->block_filter = filter;
  g_plugin->filter_pending = false;
  GHashTableIter it;
  gpointer value;
  g_hash_table_iter_init(&it, g_plugin->views);
  while (g_hash_table_iter_next(&it, nullptr, &value)) {
    auto* v = static_cast<KogiView*>(value);
    if (v->pending_html != nullptr) {
      g_autofree gchar* html = v->pending_html;
      v->pending_html = nullptr;
      load(v, html);
    }
  }
}

void compile_filter() {
  g_autofree gchar* dir =
      g_build_filename(g_get_user_cache_dir(), "kogi_webview", nullptr);
  g_autoptr(WebKitUserContentFilterStore) store =
      webkit_user_content_filter_store_new(dir);
  g_autoptr(GBytes) rules =
      g_bytes_new_static(kBlockNetworkRules, strlen(kBlockNetworkRules));
  webkit_user_content_filter_store_save(store, kFilterId, rules, nullptr,
                                        on_filter_ready, nullptr);
}

gboolean on_child_position(GtkOverlay*, GtkWidget* widget,
                           GdkRectangle* allocation, gpointer) {
  GHashTableIter it;
  gpointer value;
  g_hash_table_iter_init(&it, g_plugin->views);
  while (g_hash_table_iter_next(&it, nullptr, &value)) {
    auto* v = static_cast<KogiView*>(value);
    if (v->clip == widget) {
      *allocation = v->visible;
      return TRUE;
    }
  }
  return FALSE;
}

bool ensure_overlay() {
  if (g_plugin->overlay != nullptr) return true;
  GtkWidget* overlay =
      gtk_widget_get_ancestor(GTK_WIDGET(g_plugin->view), GTK_TYPE_OVERLAY);
  if (overlay == nullptr) {
    g_warning(
        "kogi_webview: the FlView is not inside a GtkOverlay; see the "
        "package README for the two-line runner change.");
    return false;
  }
  g_plugin->overlay = GTK_OVERLAY(overlay);
  g_signal_connect(overlay, "get-child-position",
                   G_CALLBACK(on_child_position), nullptr);
  return true;
}

KogiView* create_view(int64_t id) {
  if (g_plugin->context == nullptr) {
    g_plugin->context = webkit_web_context_new_ephemeral();
  }
  auto* v = g_new0(KogiView, 1);
  v->plugin = g_plugin;
  v->id = id;

  g_autoptr(WebKitSettings) settings = webkit_settings_new();
  // Page scripts never run; the embedder's isolated-world probes still do.
  webkit_settings_set_enable_javascript_markup(settings, FALSE);
  webkit_settings_set_enable_html5_database(settings, FALSE);
  webkit_settings_set_enable_html5_local_storage(settings, FALSE);
  webkit_settings_set_enable_developer_extras(settings, FALSE);
  webkit_settings_set_enable_write_console_messages_to_stdout(settings, FALSE);
  webkit_settings_set_media_playback_requires_user_gesture(settings, TRUE);
  // Software painting into the GTK window that Flutter's hole reveals.
  webkit_settings_set_hardware_acceleration_policy(
      settings, WEBKIT_HARDWARE_ACCELERATION_POLICY_NEVER);
  g_autoptr(WebKitUserContentManager) ucm = webkit_user_content_manager_new();

  v->web = GTK_WIDGET(g_object_new(
      WEBKIT_TYPE_WEB_VIEW, "web-context", g_plugin->context, "settings",
      settings, "user-content-manager", ucm, nullptr));
  g_signal_connect(v->web, "decide-policy", G_CALLBACK(on_decide_policy), v);
  g_signal_connect(v->web, "load-changed", G_CALLBACK(on_load_changed), v);
  g_signal_connect(v->web, "scroll-event", G_CALLBACK(on_scroll), v);
  g_signal_connect(v->web, "context-menu", G_CALLBACK(on_context_menu), v);
  g_signal_connect(v->web, "key-press-event", G_CALLBACK(on_key), v);
  g_signal_connect(v->web, "key-release-event", G_CALLBACK(on_key), v);

  v->clip = gtk_layout_new(nullptr, nullptr);
  gtk_layout_put(GTK_LAYOUT(v->clip), v->web, 0, 0);
  gtk_widget_show(v->web);
  gtk_widget_set_no_show_all(v->clip, TRUE);
  gtk_overlay_add_overlay(g_plugin->overlay, v->clip);
  // GtkOverlay wraps each child in its own input window; let that wrapper
  // pass events through so the clip's input shape alone decides what WebKit
  // receives and everything else reaches Flutter.
  gtk_overlay_set_overlay_pass_through(g_plugin->overlay, v->clip, TRUE);

  auto* key = g_new(int64_t, 1);
  *key = id;
  g_hash_table_insert(g_plugin->views, key, v);
  return v;
}

// If WebKit holds keyboard focus when its view goes away, GTK would leave the
// window with no focus widget and Flutter would stop receiving keys.
void return_focus(KogiView* v) {
  if (g_plugin == nullptr || g_plugin->view == nullptr || v->clip == nullptr) {
    return;
  }
  GtkWidget* top = gtk_widget_get_toplevel(GTK_WIDGET(g_plugin->view));
  GtkWidget* focus = GTK_IS_WINDOW(top) ? gtk_window_get_focus(GTK_WINDOW(top))
                                        : nullptr;
  if (focus != nullptr &&
      (focus == v->clip || gtk_widget_is_ancestor(focus, v->clip))) {
    gtk_widget_grab_focus(GTK_WIDGET(g_plugin->view));
  }
}

void destroy_view(gpointer data) {
  auto* v = static_cast<KogiView*>(data);
  return_focus(v);
  if (v->clip != nullptr) gtk_widget_destroy(v->clip);  // destroys v->web
  g_free(v->pending_html);
  g_free(v);
  if (g_plugin != nullptr && g_hash_table_size(g_plugin->views) == 0) {
    // Last view gone: drop the context so no web process outlives the UI.
    g_clear_object(&g_plugin->context);
  }
}

void place(KogiView* v, FlValue* args) {
  GdkRectangle slot = outward(num(args, "sx"), num(args, "sy"),
                              num(args, "sw"), num(args, "sh"));
  GdkRectangle clip = {rounded(num(args, "cx")), rounded(num(args, "cy")),
                       rounded(num(args, "cw")), rounded(num(args, "ch"))};
  v->internal_scroll = flag(args, "internalScroll");
  GdkRectangle vis;
  if (!flag(args, "visible", true) || slot.width <= 0 || slot.height <= 0 ||
      !gdk_rectangle_intersect(&slot, &clip, &vis)) {
    v->shown = false;
    return_focus(v);
    gtk_widget_hide(v->clip);
    return;
  }
  double zoom = num(args, "zoom", 1);
  if (std::fabs(zoom - v->zoom) > 1e-3) {
    // Keeps the page at the same CSS width inside a scaled slot.
    v->zoom = zoom;
    webkit_web_view_set_zoom_level(WEBKIT_WEB_VIEW(v->web), zoom);
  }
  if (slot.width != v->width) {
    // A new width reflows the document; measure it again once laid out.
    v->width = slot.width;
    g_timeout_add(120, probe_later,
                  GSIZE_TO_POINTER(static_cast<gsize>(v->id)));
  }
  v->visible = vis;
  gtk_widget_set_size_request(v->web, slot.width, slot.height);
  gtk_layout_set_size(GTK_LAYOUT(v->clip), slot.width, slot.height);
  gtk_layout_move(GTK_LAYOUT(v->clip), v->web, slot.x - vis.x,
                  slot.y - vis.y);
  v->shown = true;
  gtk_widget_show(v->clip);
  gtk_widget_queue_resize(GTK_WIDGET(g_plugin->overlay));
  apply_shape(v);
}

void set_occluders(FlValue* list) {
  g_clear_pointer(&g_plugin->occluders, cairo_region_destroy);
  if (list != nullptr && fl_value_get_type(list) == FL_VALUE_TYPE_FLOAT_LIST) {
    const double* r = fl_value_get_float_list(list);
    size_t n = fl_value_get_length(list) / 4;
    if (n > 0) {
      g_plugin->occluders = cairo_region_create();
      for (size_t i = 0; i < n; i++) {
        cairo_rectangle_int_t rect = {rounded(r[i * 4]), rounded(r[i * 4 + 1]),
                                      rounded(r[i * 4 + 2]),
                                      rounded(r[i * 4 + 3])};
        cairo_region_union_rectangle(g_plugin->occluders, &rect);
      }
    }
  }
  GHashTableIter it;
  gpointer value;
  g_hash_table_iter_init(&it, g_plugin->views);
  while (g_hash_table_iter_next(&it, nullptr, &value)) {
    apply_shape(static_cast<KogiView*>(value));
  }
}

void set_background(KogiView* v, FlValue* args) {
  FlValue* bg = arg(args, "background");
  if (bg == nullptr || fl_value_get_type(bg) != FL_VALUE_TYPE_INT) return;
  const auto argb = static_cast<uint32_t>(fl_value_get_int(bg));
  GdkRGBA rgba = {((argb >> 16) & 0xff) / 255.0, ((argb >> 8) & 0xff) / 255.0,
                  (argb & 0xff) / 255.0, 1.0};
  webkit_web_view_set_background_color(WEBKIT_WEB_VIEW(v->web), &rgba);
}

// ── Method channel ─────────────────────────────────────────────────────────

void respond(FlMethodCall* call, FlValue* result = nullptr) {
  fl_method_call_respond_success(call, result, nullptr);
}

void on_method(FlMethodChannel*, FlMethodCall* call, gpointer) {
  const gchar* m = fl_method_call_get_name(call);
  FlValue* args = fl_method_call_get_args(call);

  if (std::strcmp(m, "create") == 0) {
    if (!ensure_overlay()) {
      g_autoptr(FlValue) no = fl_value_new_bool(FALSE);
      respond(call, no);
      return;
    }
    if (lookup(args) == nullptr) {
      create_view(static_cast<int64_t>(num(args, "id")));
    }
    g_autoptr(FlValue) info = fl_value_new_map();
    fl_value_set_string_take(info, "wayland",
                             fl_value_new_bool(g_plugin->wayland));
    respond(call, info);
    return;
  }

  if (std::strcmp(m, "focusFlutter") == 0) {
    GtkWidget* view = GTK_WIDGET(g_plugin->view);
    if (!gtk_widget_has_focus(view)) gtk_widget_grab_focus(view);
    respond(call);
    return;
  }

  if (std::strcmp(m, "setOccluders") == 0) {
    set_occluders(args);
    respond(call);
    return;
  }

  KogiView* v = lookup(args);
  if (v == nullptr) {
    respond(call);
    return;
  }
  if (std::strcmp(m, "load") == 0) {
    v->block_network = flag(args, "blockNetwork", true);
    set_background(v, args);
    const char* html = str(args, "html");
    load(v, html != nullptr ? html : "");
  } else if (std::strcmp(m, "place") == 0) {
    place(v, args);
  } else if (std::strcmp(m, "setCovered") == 0) {
    v->covered = flag(args, "covered");
    if (v->covered) return_focus(v);
    apply_shape(v);
  } else if (std::strcmp(m, "copySelection") == 0) {
    webkit_web_view_execute_editing_command(WEBKIT_WEB_VIEW(v->web),
                                            WEBKIT_EDITING_COMMAND_COPY);
  } else if (std::strcmp(m, "dispose") == 0) {
    int64_t id = v->id;
    g_hash_table_remove(g_plugin->views, &id);
  }
  respond(call);
}

}  // namespace

void kogi_webview_plugin_register_with_registrar(FlPluginRegistrar* registrar) {
  if (g_plugin != nullptr) return;
  g_plugin = new Plugin();
  g_plugin->view = fl_plugin_registrar_get_view(registrar);
#ifdef GDK_WINDOWING_WAYLAND
  g_plugin->wayland = GDK_IS_WAYLAND_DISPLAY(gdk_display_get_default());
#endif
  g_plugin->views =
      g_hash_table_new_full(g_int64_hash, g_int64_equal, g_free, destroy_view);
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  g_plugin->channel = fl_method_channel_new(
      fl_plugin_registrar_get_messenger(registrar), kChannel,
      FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(g_plugin->channel, on_method,
                                            nullptr, nullptr);
  compile_filter();
}
