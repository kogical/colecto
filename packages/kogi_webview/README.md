# kogi_webview

Live WebKitGTK views that composite like ordinary Flutter content on Linux.

Flutter has no Linux platform views, and since Flutter 3.50 its Wayland
renderer draws into a subsurface stacked **above** the GTK window, so a GTK
widget layered over the Flutter view is simply invisible. `kogi_webview` turns
that stacking into the solution:

1. The WebKit view lives in a `GtkOverlay` child **under** Flutter.
2. The Dart widget paints a transparent hole (`BlendMode.clear`) in Flutter's
   frame exactly where the view goes, so the compositor shows WebKit through
   it, while anything Flutter draws above that spot (dialogs, menus, toasts,
   dimming) still lands on top.
3. Every frame, the widget reports its rectangle, the enclosing scroll
   viewports and whether a route covers it. The native side moves the view
   synchronously inside a clipping `GtkLayout`, so it scrolls, clips and
   resizes with the page.

What you get is the real engine: native text selection and copy, link hover,
fonts, tables and CSS exactly as WebKit renders them, without copying pixels
into a texture.

| | |
|---|---|
| Platforms | Linux (Wayland and X11). Elsewhere the widget builds `fallback`. |
| Flutter | 3.50 or later |
| Native deps | `webkit2gtk-4.1` (`libwebkit2gtk-4.1-dev` to build) |
| License | MIT or Apache-2.0, at your option |

## Setup

Put the `FlView` inside a `GtkOverlay` in `linux/runner/my_application.cc`:

```cpp
GtkWidget* overlay = gtk_overlay_new();
gtk_container_add(GTK_CONTAINER(overlay), GTK_WIDGET(view));
gtk_widget_show(overlay);
gtk_container_add(GTK_CONTAINER(window), overlay);  // instead of the view
```

Without the overlay the plugin logs a warning and every `KogiWebView` builds
its `fallback`.

## Usage

```dart
double height = 400;

SizedBox(
  height: height,
  child: KogiWebView(
    html: sanitizedHtml,
    background: const Color(0xFFFFFFFF),
    onContentHeight: (h) => setState(() => height = h),
    onLinkTap: (url) => launchInBrowser(url),
    onContextMenu: (menu) => showMyMenu(menu.globalPosition, menu),
    fallback: MyPlainRenderer(html: sanitizedHtml),
  ),
)
```

- **Sizing:** the view fills its parent. Feed `onContentHeight` back into the
  parent to size it to the document; it fires after each load and after a
  width change reflows the page. For very tall documents, give it a fixed
  height and `scrollsInternally: true` instead.
- **Scrolling:** with `scrollsInternally: false` (the default) wheel and
  touchpad events over the view are replayed as Flutter pointer-scroll
  events, so the enclosing Flutter scrollable scrolls.
- **Links:** the view never navigates. User-initiated link activations go to
  `onLinkTap`.
- **Context menu:** WebKit's own GTK menu is suppressed. `onContextMenu` gets
  the position, the link under the pointer, whether the click hit a
  selection, and a `copySelection()` callback, so you can show a Flutter menu.
- **Keyboard focus:** pressing anywhere in Flutter takes focus back from
  WebKit; clicking the view gives it focus (so Ctrl+C copies its selection).
  Keys the page does not handle are passed on to Flutter, so app shortcuts
  keep working while the view has focus.
- **Safety defaults:** page JavaScript is disabled (the plugin's own probes
  run in an isolated world), storage is off, the web context is ephemeral,
  and `blockNetwork: true` blocks every `http(s)`, `ws(s)` and `ftp` load.
  `data:` URLs still work. If the block list cannot be compiled, the widget
  builds `fallback` instead of loading the page unprotected. This is defence
  in depth, not a sanitizer: if you show untrusted HTML, sanitize it first.
- **Memory:** a view's WebKit widget is destroyed when the widget is disposed,
  and the shared web context goes with the last view.

### Things that float above a view

Routes need nothing: a view under a route that is not current stops taking
input (and on X11 is hidden). For non-route overlays (a toast, an inline
popover) wrap them in `KogiWebViewOccluder` so clicks on them reach Flutter:

```dart
KogiWebViewOccluder(child: MyToast())
```

## Limitations

- Anything that composites the view's ancestors into an offscreen layer
  (`Opacity` between 0 and 1, `ShaderMask`, `BackdropFilter` below the view)
  turns the hole into a hole in that layer only, so WebKit will not show
  through while it is active.
- On X11 the view paints above Flutter. Covered views are hidden and
  occluders still receive clicks, but an occluder overlapping a view is drawn
  underneath it.
- Wheel scrolling over the view follows Flutter's Linux wheel behaviour
  (fixed steps, no smoothing), exactly like the rest of the app.
- One view per `KogiWebView`; there is no navigation, history or JavaScript
  bridge. It is built to show documents, not to be a browser.

## Testing

`tool/wayland_smoke.sh` runs the example under headless Weston, screenshots
it and checks pixels: WebKit must show through the hole, opaque Flutter
content must surround it, and a Flutter toast must draw above it.

```sh
cd example
flutter build linux --release --dart-define=KOGI_SMOKE=true
../tool/wayland_smoke.sh build/linux/x64/release/bundle/kogi_webview_example
```

It needs `weston`, ImageMagick and `python3`. X11-only testing (Xvfb) cannot
catch the Wayland stacking problem this package exists to solve.
