# UI & Navigation Specification

Colecto is **mobile-first in navigation clarity** and **platform-native in visual personality**.

## Adaptive 3-Tier Layout

Drop dockable/split game-engine panes. Use a proven adaptive mail layout:

| Viewport | Layout | Navigation |
| --- | --- | --- |
| **Phone** (`< 600px`) | Single-column navigation stack | Bottom nav or drawer (Inbox / Folders / Search) → Thread List (swipe actions, pull-to-refresh, compose FAB/button) → Pushed Thread Reader (native back gesture) → Compose sheet |
| **Tablet / Compact Desktop** (`600–1050px`) | Colecto two-column, narrower Mail pane | Same as desktop |
| **Desktop / Wide Web** (`> 1050px`) | Colecto two-column | Top bar \| Mail pane (search + Compose, Inbox/Drafts/Sent tabs with More, labels, list, account switcher) \| Reader, plus `Cmd/Ctrl+K` command palette |

## Per-Platform Design Systems

Share the controller, `MailBackend`, layouts and mail views, and branch only in the **Colecto kit** (`app/lib/ui/core/kit/`) and the navigation shell.

| Design (`COLECTO_DESIGN`) | Library | Native on | Signature details |
| --- | --- | --- | --- |
| `colecto` | `shadcn_ui` + Colecto palette | Linux, Web | Colecto top bar with centred command trigger, Compose beside search, glowing mint selection node, Mona Sans |
| `fluent` | `fluent_ui` | Windows | 48 px Mica title bar (small icon + name, Fluent search box), sender pictures in rows, labelled command bar, Settings as a `ContentDialog` over the smoke layer, Segoe UI Variable, 4 px radii |
| `macos` | `macos_ui` | macOS | 52 px unified toolbar with room for traffic lights, folder tabs like a favourites bar, accent-filled selected row and unread dot, icon-only toolbar, Settings as a sheet |
| `material` | `material_ui` + `dynamic_color` | Android | Pill search bar, sender pictures in rows, Settings as an M3 dialog; on phones a large app bar, `NavigationBar`, extended FAB, bottom sheets and full-screen dialogs; Material You colours |
| `cupertino` | `cupertino_ui` | iOS | Settings and the phone composer as card sheets; on phones a large-title navigation bar, tab bar, inset grouped Settings list, action sheets and edge-swipe back |

### The Colecto kit

Feature code never imports a design library. Widget tests render every design at desktop, tablet and phone widths. It uses kit components, each with one API and one mapping per design:

| Component | Colecto (shadcn) | Fluent | macOS | Material 3 | Cupertino |
| --- | --- | --- | --- | --- | --- |
| `ColectoButton` | `ShadButton` variants | `FilledButton` / `Button` / `HyperlinkButton` | `PushButton` | `FilledButton` / tonal / `TextButton` | `CupertinoButton.filled` / `.tinted` |
| `ColectoIconButton` | `ShadIconButton.ghost` | `IconButton` | `MacosIconButton` | `IconButton` | `CupertinoButton` |
| `ColectoSwitch` | `ShadSwitch` | `ToggleSwitch` | `MacosSwitch` | `Switch` | `CupertinoSwitch` |
| `ColectoCheckbox` | `ShadCheckbox` | `Checkbox` | `MacosCheckbox` | `Checkbox` | `CupertinoCheckbox` |
| `ColectoTextField` | `ShadInput` | `TextBox` | `MacosTextField` | outlined `TextField` | `CupertinoTextField` |
| `ColectoSegmented` | Colecto segmented | `ToggleButton` row | `MacosSegmentedControl` | `SegmentedButton` | `CupertinoSlidingSegmentedControl` |
| `ColectoSelect` | `ShadSelect` | `ComboBox` | `MacosPopupButton` | `DropdownMenu` | action sheet |
| `showColectoConfirm` / `showColectoPrompt` | `ShadDialog.alert` | `ContentDialog` | `MacosAlertDialog` | `AlertDialog` | `CupertinoAlertDialog` |
| `colectoModalRoute` (Settings, Add an account) | card rising over a scrim | `FluentDialogRoute` with `ContentDialog` surface | sheet | `Dialog` (full-screen dialog on phones) | `CupertinoSheetRoute` |
| `ColectoNavBar` / `ColectoNavList` (phone pages) | slim bar, Colecto rows | slim bar, Colecto rows | slim bar, Colecto rows | top app bar, `ListTile`s | `CupertinoNavigationBar` with *Done*, inset grouped list |
| `showColectoContextMenu` | popover from the pointer | Fluent-metric popover | macOS-metric popover | bottom sheet | action sheet |
| `ColectoText` / `ColectoParagraph` | role → Colecto ramp | Windows type ramp | macOS ramp | M3 type scale | iOS Dynamic Type sizes |

Shared Colecto components (`ColectoChip`, `ColectoAvatar`, `ColectoSection`, `ColectoSettingRow`, `ColectoNotice`, `ColectoSkeleton`, toasts) take only radii and metrics from the design.

### Brand

The mark is Colecto's (`app/assets/branding/logo-square.svg`), drawn natively by `ColectoMark` and exported to every platform's app icons and the web favicon/manifest.

### Stress data

`just run demo <device> <design> worst` (`--dart-define=COLECTO_DEMO=worst`, development only) replaces the demo mailbox with worst realistic data: long names and unbreakable addresses, one-letter names, missing subjects, Japanese and Arabic text, emoji, 999+ counts, long label names, a 27-message thread, 3.2 GB and empty attachments, and hundreds of rows. Widget tests run it through every design at desktop, tablet and phone widths.

### Choosing a design

Each platform starts with its own design, but **any design works on any platform and at any window size**: someone can run Material on Windows or Fluent on Linux. The choice is an owner preference (`Preferences.design`, stored by `colecto-service`), set in Settings → Appearance → Design; picking the platform's own design clears it. For previews, `just run demo <device> <design>` and `just build web <design>` pass `--dart-define=COLECTO_DESIGN=<design>`, which overrides the saved choice for that launch.

### Rules that hold on every desktop design

- No Material ink splashes or ripples, no floating action buttons.
- Readable text (subjects, headers, bodies, addresses) is selectable.
- Right-click context menus on folders, labels, threads and messages.
- Desktop scroll behaviour without mobile overscroll; crisp scrollbars.
- Sharp 2px keyboard focus rings.
- Full keyboard navigation: `j`/`k` (or arrows) move, `a` archive (`e` too), `d` trash (`#`/Delete too), `s` star or unstar, `u` read or unread, `r` reply, `Shift+R` reply all, `f` forward, `.` (or `Shift+F10`, or the Menu key) the open conversation's actions menu, `c` compose, `/` search, `?` or `Cmd/Ctrl+K` command palette, `Cmd/Ctrl+,` settings, `Esc` back out. Shortcuts keep working after a click into an HTML email: the Linux view hands each key to Flutter first and gets back only the ones the app does not use (copy, Space, Page Down). Context menus, tooltips and the command palette show each action's key; labels and *Move to* folders have none. Every shortcut also has a pointer path.
- Light and dark mode both supported; the default follows the system.
- `Cmd/Ctrl +`, `-` and `0` zoom the whole interface like a browser (50–200 %, saved as `Preferences.zoom`); on touch designs the same setting is *Interface size* in Settings → Appearance.
- Send approvals appear in the top bar and command palette only while a request is waiting; Settings always lists the section.

### Android

Material You is on by default: with no accent chosen, `dynamic_color` supplies the whole palette from the wallpaper. Settings → Appearance → *Use system colours* turns it off and shows the accent picker. Swipe to archive or trash, pull to refresh, predictive back, long-press for actions.

### iOS

Large-title list, tab bar for Inbox/Drafts/Sent/Archive/More, edge-swipe back from the reader, Cupertino alerts and action sheets, swipe actions and pull to refresh.

## Layout and behaviour carried over from Colecto

- **Top bar** (every design at desktop width, drawn as its title bar or toolbar): brand, a centred `Search mail or run a command` trigger with its shortcut, Send approvals while one waits, Settings.
- **Sorting:** newest first by default; oldest first, sender A–Z or subject A–Z from the folder tabs' More menu or the command palette, with a *Sorted …* note above the list to clear it. Date headings show only for date order.
- **Mail pane:** search with Compose beside it, Inbox/Drafts/Sent tabs (every other folder under More), label filter chips with an inline *New label* field, sticky date groups, rows that become single lines when the pane is wide, hover actions (archive, read/unread, trash), Cmd/Ctrl-click and Shift-click selection with a bulk bar, and a footer with the conversation count and sync status, then the account switcher with live sync status. The list/reader divider can be dragged, nudged with the arrow keys, and double-clicked to reset.
- **Reader tabs:** every conversation you open becomes a tab at the top of the reader (up to 30 per account; hidden when no conversations are open), so several messages stay open at once; click to switch, × or a middle click to close (the neighbour opens), right-click for Close, Close others and Close all. Archiving or deleting a message closes its tab. Phones show one message at a time, without tabs.
- **Context menus:** right-click (desktop) or long-press (touch) ONLY — `showColectoContextMenu` is reserved strictly for secondary-click / long-tap menus on message rows (Open, Select, read or unread, Star, a *Label:* toggle per label, *Check labels again* when AI is enabled, Archive, *Move to* each folder, Move to Trash), folder tabs, label chips, reader tabs, messages in a conversation, attachments, and the account switcher. Normal button taps on mobile/touch (account switcher, More menus, font/select pickers) open a modal (`colectoModalRoute` / `showColectoModalPicker`) instead of a context menu. Screen readers reach the same context menu as the long-press action.
- **Reader:** a sticky translucent toolbar, a centred letter (large subject, sender row with a stable per-correspondent avatar hue, label toggles, attachments that save to disk, 68ch body), earlier messages folded to one line, AI summary and reply drafting, and a welcome state with a time-of-day greeting.
- **Composer:** opens in the reader (a full-screen page on phones) with From/To/Cc/Subject rows, a save-state line, real file attachments, Cmd/Ctrl+Enter to send and Cmd/Ctrl+S to save. Closing with unsaved changes keeps them as a draft.
- **Settings:** the design's own modal (see `colectoModalRoute`) with Colecto's section list (*Settings* title, a *Built-in* group, a button that folds the list to icons), a `Settings / Page` breadcrumb and a close button. Sections in order: Accounts, Mail, Appearance, Notifications, Privacy, Connection, Backup, AI, API keys, Send approvals. Pages keep Colecto's organisation: a title and lead, then labelled groups spaced apart (not cards); each setting is a row with its label and description on the left and the control on the right (under the text when the page is narrow). On phones it opens at the section list and each section is a page; Back returns to the list.
  - **Accounts & security:** *Mail accounts* rows (avatar, protocol tag, status · server, Reconnect / Edit / Remove, on/off switch) with an *Add account* button, then *Credential protection*.
  - **Add an account / Edit account:** a three-step wizard (Email → Servers → Review) in its own modal (a full-screen page with *Cancel* on phones). Email looks up the provider (Skip, *Enter settings myself*, OAuth-only and no-access notes); Servers shows what was found and where from, IMAP + SMTP or JMAP, port presets with *Other* and TLS/STARTTLS, sign-in and a trusted certificate; Review lists each server with *Change* links and likely-mistake warnings, the optional account name, and a master-password fallback when the device has no credential store. Going back never loses what was typed.
  - **Appearance:** Text (font, size, letter/word/line/paragraph spacing), Colour (accent swatches, custom hex), Message list (density, date headings, load on scroll), Window (theme, design, zoom). **Mail:** Ready to read (prefetch switch and a slider). **Notifications:** Show notifications, then Delivery (desktop notifications, position, test). **Connection:** the current mail service; on Linux, *Background* with *Keep running after closing* and *Start on login* (see [self-hosting](self-hosting.md#desktop-notifications)); then *Use another server*. **Backup:** export (locked with a passphrase by default) and restore; see [Backups](accounts.md#backups).
- **Onboarding:** on first run with no real account, a full-window welcome (floating mark, *Add your first account*, *Explore with sample mail first*, step dots), the account wizard in a card (full screen on phones), and *You're all set* with a drawn check and *Open Inbox*.
- **Notifications:** enter from the edge they are docked to, leave after six seconds unless hovered.
- **Motion:** presses scale to 0.97, menus grow from their trigger in ~200 ms, the Colecto Settings card rises 6 px in 220 ms (other designs use their own modal motion), the command palette opens instantly, and reduced-motion turns transitions off.

## Visual Identity: Colecto Palette + Native Controls

Colecto carries forward **Colecto's calm, green-tinted dark surface palette and typography discipline**, paired with **native, crisp platform controls** (shadcn-style on Desktop/Web, Material 3 on Android, Cupertino on iOS) rather than Colecto's custom web-only controls.

### Signature Dark Palette (Default Dark Theme)
Surfaces use a subtle cool-green tint (`oklch` hue ~165) with crisp hairline borders and Colecto's signature mint accent (user-customizable via `#rrggbb` in `Preferences.accent`):

| Token | Value | Role |
| --- | --- | --- |
| `--ground` | `oklch(0.112 0.002 165)` | App canvas / deepest backdrop |
| `--sunk` | `oklch(0.125 0.003 165)` | Recessed containers, search inputs |
| `--bg` | `oklch(0.148 0.003 165)` | Primary pane background |
| `--float` | `oklch(0.185 0.004 165)` | Popovers, menus, dialogs |
| `--raise` | `oklch(0.207 0.004 165)` | Elevated cards / hovered rows |
| `--control` | `oklch(0.235 0.005 165)` | Buttons, inputs, segmented controls |
| `--line` | `oklch(0.265 0.005 165)` | Primary 1px hairline dividers |
| `--line-soft` | `oklch(0.212 0.004 165)` | Subtle row/list separators |
| `--ink` | `oklch(0.95 0.003 155)` | Primary text |
| `--ink-2` | `oklch(0.79 0.006 155)` | Secondary text (snippets, metadata) |
| `--ink-3` | `oklch(0.63 0.008 158)` | Muted labels, timestamps |
| `--mint` | `#a2d6b1` | Default accent (selection, focus ring, unread dot, primary action) |
| `--select` | `color-mix(in oklch, var(--mint) 13%, var(--bg))` | Selected row / active nav item |
| `--status-online` | `#82c995` | Connected / push-active indicator |
| `--danger` / `--danger-bg` | `oklch(0.8 0.1 30)` / `oklch(0.245 0.045 28)` | Destructive actions and errors |
| `--star` | `oklch(0.85 0.12 85)` | Flagged/starred indicator |

Light mode uses matching neutral-mint surface counterparts (crisp white/off-white surfaces, deeper forest-mint accent for WCAG AA contrast) while keeping the same visual restraint.

### Typography, Density, and Accessibility
- **Typefaces:** Bundled `Mona Sans` variable font (OFL) on Colecto, Material and Cupertino; Segoe UI Variable on Fluent and the system font on macOS unless the owner picks one; with owner-selectable `Inter`, `Geist`, `IBM Plex Sans`, `Atkinson Hyperlegible Next`, or an installed system font (`Preferences.font`).
- **Base scale:** 13–18 px (`Preferences.font_size`, 14 px default).
- **WCAG 1.4.12 Text Spacing:** Independent 0–2 step controls for letter, word, line, and paragraph spacing (`Preferences.text_spacing`).
- **List density & grouping:** `full` (two-line with preview), `medium`, and `compact` (single-line) row densities (`Preferences.list_density`), plus optional relative date group headers (`Preferences.date_groups`).
- **Balance with native controls:** Use the palette and spacing tokens above, while letting each platform supply native scroll physics, focus/hover semantics, context menus, sheets, switches, and navigation chrome.
