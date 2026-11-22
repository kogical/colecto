#include "my_application.h"

#include <cstdlib>

int main(int argc, char** argv) {
  // Keep WebKitGTK on its software Cairo path when overlaid on Flutter's
  // GtkGLArea so Wayland/NVIDIA/Mesa DMA-BUF compositors never paint a blank
  // white WebView surface (users can still override via env).
  if (std::getenv("WEBKIT_DISABLE_DMABUF_RENDERER") == nullptr) {
    setenv("WEBKIT_DISABLE_DMABUF_RENDERER", "1", 0);
  }
  if (std::getenv("WEBKIT_DISABLE_COMPOSITING_MODE") == nullptr) {
    setenv("WEBKIT_DISABLE_COMPOSITING_MODE", "1", 0);
  }
  g_autoptr(MyApplication) app = my_application_new();
  return g_application_run(G_APPLICATION(app), argc, argv);
}
