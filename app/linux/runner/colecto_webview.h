#ifndef COLECTO_WEBVIEW_H_
#define COLECTO_WEBVIEW_H_

#include <flutter_linux/flutter_linux.h>
#include <gtk/gtk.h>

G_BEGIN_DECLS

typedef struct _ColectoWebViewHost ColectoWebViewHost;

// Attaches the `com.kogical.colecto/webview` MethodChannel to [view] and
// mounts a lazy WebKitGTK 4.1 WebView inside [overlay_fixed] only while an
// HTML email is open.
ColectoWebViewHost* colecto_webview_host_new(FlView* view,
                                             GtkFixed* overlay_fixed);

void colecto_webview_host_dispose(ColectoWebViewHost* host);

G_END_DECLS

#endif  // COLECTO_WEBVIEW_H_
