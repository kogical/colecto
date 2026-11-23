## Unreleased

- Fix `blockNetwork`: the block list never compiled (WebKit rejects regex
  disjunctions), so remote loads were allowed. A view that cannot enforce
  `blockNetwork` now builds `fallback` instead of loading.

## 0.1.0

- First release: live WebKitGTK views composited under Flutter on Linux
  (Wayland and X11), with scroll-synced clipping, wheel forwarding, route
  covering, occluders, Flutter-side context menus, network blocking and
  content-height reporting. Extracted from the Colecto mail client.
