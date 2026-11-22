#include "my_application.h"

#include <cstdlib>

int main(int argc, char** argv) {
  // Mitigate WebKitGTK DMA-BUF compositor crashes/blank surfaces on Wayland
  // (KDE Plasma, Sway, Hyprland, NVIDIA/Mesa) unless explicitly overridden.
  if (std::getenv("WAYLAND_DISPLAY") != nullptr &&
      std::getenv("WEBKIT_DISABLE_DMABUF_RENDERER") == nullptr) {
    setenv("WEBKIT_DISABLE_DMABUF_RENDERER", "1", 0);
  }
  g_autoptr(MyApplication) app = my_application_new();
  return g_application_run(G_APPLICATION(app), argc, argv);
}
