import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter/gestures.dart'
    show PointerScrollEvent, PointerSignalEvent, kMiddleMouseButton;
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:material_ui/material_ui.dart';

import '../onboarding/onboarding_view.dart';
import '../../../domain/models/mail_models.dart';
import '../../core/theme/colecto_palette.dart';
import '../../core/widgets/colecto_mark.dart';
import '../../core/kit/kit.dart';
import '../composer/compose_requests.dart';
import '../composer/composer_view.dart';
import '../mailbox/message_list_pane.dart';
import '../reader/reader_pane.dart';
import '../settings/settings_view.dart';
import 'command_palette.dart';
import 'mail_controller.dart';
import 'folders.dart';
import 'top_bar.dart';

/// Adaptive mail shell (`docs/ui-design.md`):
/// - Phone (`< 600px`): a native navigation stack — large-title list, a
///   bottom folder bar, and pushed reader, composer and settings pages.
/// - Wider: Colecto's two-column workspace (Mail pane and reader) under
///   the top bar, with Settings in the design's own modal.
class MailShell extends StatefulWidget {
  const MailShell({super.key, required this.controller});

  final MailController controller;

  @override
  State<MailShell> createState() => _MailShellState();
}

class _MailShellState extends State<MailShell> {
  final _searchFocus = FocusNode();
  final _shellFocus = FocusNode();

  MailController get c => widget.controller;

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_onStrayKey);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onStrayKey);
    _searchFocus.dispose();
    _shellFocus.dispose();
    super.dispose();
  }

  void _compose([ComposeRequest request = const ComposeRequest()]) {
    c.closeSettings();
    c.startCompose(request);
  }

  void _openDraft(Draft d) => _compose(
    ComposeRequest(
      heading: 'Your draft',
      draftId: d.id,
      to: d.recipient,
      cc: d.cc,
      subject: d.subject,
      body: d.body,
      inReplyTo: d.inReplyTo,
      references: d.references,
      forwardOf: d.forwardOf,
    ),
  );

  void _openCommandPalette() {
    if (c.activeSettings != null) c.closeSettings();
    showCommandPalette(
      context: context,
      controller: c,
      onCompose: _compose,
      onOpenThread: c.selectThread,
    );
  }

  bool _editingText() {
    final ctx = FocusManager.instance.primaryFocus?.context;
    if (ctx == null) return false;
    return ctx.widget is EditableText ||
        ctx.findAncestorStateOfType<EditableTextState>() != null;
  }

  /// Runs the shell's shortcuts when focus has left the shell, for example
  /// after a field gives up focus to its route's scope, so they never stop
  /// working. Focus inside the shell, or a dialog or menu on top, keeps the
  /// normal focus-based handling.
  bool _onStrayKey(KeyEvent event) {
    if (!mounted || _shellFocus.hasFocus || _shellFocus.context == null) {
      return false;
    }
    if (ModalRoute.of(context)?.isCurrent == false) return false;
    return _onKey(_shellFocus, event) == KeyEventResult.handled;
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final keys = HardwareKeyboard.instance;
    final mod = keys.isControlPressed || keys.isMetaPressed;
    final key = event.logicalKey;

    if (mod && key == LogicalKeyboardKey.keyK) {
      _openCommandPalette();
      return KeyEventResult.handled;
    }
    if (mod && key == LogicalKeyboardKey.comma) {
      c.openSettings();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.escape) {
      if (c.activeSettings != null) {
        c.closeSettings();
        return KeyEventResult.handled;
      }
      if (c.bulkSelectedIds.isNotEmpty) {
        c.clearBulkSelection();
        return KeyEventResult.handled;
      }
      if (c.selectedMessageId != null && c.compose == null) {
        c.clearSelection();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }
    if (mod || keys.isAltPressed) return KeyEventResult.ignored;
    if (_editingText() || c.activeSettings != null || c.compose != null) {
      return KeyEventResult.ignored;
    }

    final shift = keys.isShiftPressed;
    if (key == LogicalKeyboardKey.keyJ || key == LogicalKeyboardKey.arrowDown) {
      c.selectAdjacentThread(1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.keyK || key == LogicalKeyboardKey.arrowUp) {
      c.selectAdjacentThread(-1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.keyC) {
      _compose();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.slash && !shift) {
      _searchFocus.requestFocus();
      return KeyEventResult.handled;
    }
    if (shift && key == LogicalKeyboardKey.slash) {
      _openCommandPalette();
      return KeyEventResult.handled;
    }

    final msg = c.conversation.lastOrNull?.message;
    if (c.selectedMessageId == null || msg == null) {
      return KeyEventResult.ignored;
    }
    final ids = [for (final t in c.conversation) t.message.id];
    final content = c.contentFor(msg.id);
    final self = c.currentAccountInfo?.address ?? '';
    final unread = c.conversation.any((t) => !t.message.seen);
    final starred = c.conversation.any((t) => t.message.flagged);
    switch (key) {
      case LogicalKeyboardKey.keyA || LogicalKeyboardKey.keyE:
        c.organizeMessages('archive', ids: ids);
      case LogicalKeyboardKey.keyD ||
          LogicalKeyboardKey.delete ||
          LogicalKeyboardKey.numberSign:
        c.organizeMessages('delete', ids: ids);
      case LogicalKeyboardKey.digit3 when shift:
        c.organizeMessages('delete', ids: ids);
      case LogicalKeyboardKey.keyU:
        c.organizeMessages('flags', ids: ids, seen: unread);
      case LogicalKeyboardKey.keyS:
        // As the list and its menu: the thread is starred if any message is.
        c.organizeMessages(
          'flags',
          ids: starred
              ? [
                  for (final t in c.conversation)
                    if (t.message.flagged) t.message.id,
                ]
              : [msg.id],
          flagged: !starred,
        );
      case LogicalKeyboardKey.keyR:
        _compose(replyRequest(msg, content, all: shift, self: self));
      case LogicalKeyboardKey.keyF:
        _compose(forwardRequest(msg, content));
      case LogicalKeyboardKey.period || LogicalKeyboardKey.contextMenu:
        c.threadMenuRequests.value++;
      case LogicalKeyboardKey.f10 when shift:
        c.threadMenuRequests.value++;
      default:
        return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) {
        if (c.authRequired) return _ConnectScreen(controller: c);
        if (c.showsOnboarding) return OnboardingView(controller: c);
        return Focus(
          focusNode: _shellFocus,
          autofocus: true,
          onKeyEvent: _onKey,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final width = constraints.maxWidth;
              if (width < 600) {
                return _PhoneShell(
                  controller: c,
                  searchFocus: _searchFocus,
                  onCompose: _compose,
                  onOpenDraft: _openDraft,
                  onOpenCommandPalette: _openCommandPalette,
                );
              }
              return Material(
                color: ColectoPalette.of(context).ground,
                child: _Workspace(
                  controller: c,
                  searchFocus: _searchFocus,
                  compact: width <= 1050,
                  onCompose: _compose,
                  onOpenDraft: _openDraft,
                  onOpenCommandPalette: _openCommandPalette,
                ),
              );
            },
          ),
        );
      },
    );
  }
}

// ───────────────────────── Desktop & tablet ─────────────────────────

class _Workspace extends StatefulWidget {
  const _Workspace({
    required this.controller,
    required this.searchFocus,
    required this.compact,
    required this.onCompose,
    required this.onOpenDraft,
    required this.onOpenCommandPalette,
  });

  final MailController controller;
  final FocusNode searchFocus;
  final bool compact;
  final ValueChanged<ComposeRequest> onCompose;
  final ValueChanged<Draft> onOpenDraft;
  final VoidCallback onOpenCommandPalette;

  @override
  State<_Workspace> createState() => _WorkspaceState();
}

/// Colecto's two-column workspace under the top bar: the Mail pane (search
/// and Compose, folder tabs, labels, the list, its footer and the account
/// switcher) beside the reader. Settings open as the design's own modal.
class _WorkspaceState extends State<_Workspace> {
  double? _listWidth;
  late final _settings = _ModalSlot(_sync);
  NavigatorState? _navigator;

  MailController get c => widget.controller;

  @override
  void initState() {
    super.initState();
    c.addListener(_sync);
    WidgetsBinding.instance.addPostFrameCallback((_) => _sync());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _navigator = Navigator.maybeOf(context);
  }

  @override
  void dispose() {
    c.removeListener(_sync);
    // Shrinking to phone width swaps in the phone shell, which opens its
    // own Settings page.
    _settings.dispose(_navigator);
    super.dispose();
  }

  void _sync() => _settings.sync(
    mounted ? _navigator : null,
    open: c.activeSettings != null,
    design: c.design,
    build: () => colectoModalRoute(
      context,
      style: c.design,
      builder: (_) => ListenableBuilder(
        listenable: c,
        builder: (_, _) => SettingsView(controller: c),
      ),
    ),
    onDismissed: c.closeSettings,
  );

  @override
  Widget build(BuildContext context) {
    final p = ColectoPalette.of(context);
    void compose() => widget.onCompose(const ComposeRequest());
    return Column(
      children: [
        ColectoTopBar(
          controller: c,
          onOpenCommandPalette: widget.onOpenCommandPalette,
        ),
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final fallback = widget.compact ? 300.0 : 344.0;
              final maxList = (constraints.maxWidth - 360).clamp(260.0, 620.0);
              final listWidth = (_listWidth ?? fallback).clamp(260.0, maxList);
              return Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(
                    width: listWidth,
                    child: RepaintBoundary(
                      child: ColoredBox(
                        color: p.bg,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Expanded(
                              child: MessageListPane(
                                controller: c,
                                searchFocusNode: widget.searchFocus,
                                onOpenDraft: widget.onOpenDraft,
                                onThreadSelected: c.selectThread,
                                onCompose: compose,
                                folderTabs: true,
                              ),
                            ),
                            _AccountsBar(controller: c),
                          ],
                        ),
                      ),
                    ),
                  ),
                  _Gutter(
                    onDrag: (dx) => setState(
                      () => _listWidth = (listWidth + dx).clamp(260.0, maxList),
                    ),
                    onReset: () => setState(() => _listWidth = null),
                  ),
                  Expanded(
                    child: RepaintBoundary(
                      child: ColoredBox(
                        color: p.bg,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            _ReaderHeader(controller: c),
                            Expanded(child: _reader()),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _reader() => c.compose != null
      ? ComposerView(
          key: ValueKey('compose-${c.composeKey}'),
          controller: c,
          request: c.compose!,
          onClose: c.closeCompose,
        )
      : ReaderPane(controller: c, onCompose: widget.onCompose);
}

/// The foot of the Mail pane: the account switcher with live sync status.
class _AccountsBar extends StatelessWidget {
  const _AccountsBar({required this.controller});

  final MailController controller;

  @override
  Widget build(BuildContext context) {
    final p = ColectoPalette.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: p.lineSoft)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(6),
        child: AccountSwitcher(controller: controller, expand: true),
      ),
    );
  }
}

/// The reader's tab strip for open conversations. Hidden when no tabs are open.
/// Vertical mouse-wheel scrolling scrolls the strip horizontally.
class _PaneHeader extends StatefulWidget {
  const _PaneHeader({required this.children});

  final List<Widget> children;

  @override
  State<_PaneHeader> createState() => _PaneHeaderState();
}

class _PaneHeaderState extends State<_PaneHeader> {
  final _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _onPointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent || !_scroll.hasClients) return;
    final delta = event.scrollDelta.dx != 0
        ? event.scrollDelta.dx
        : event.scrollDelta.dy;
    if (delta == 0) return;
    final target = (_scroll.offset + delta).clamp(
      0.0,
      _scroll.position.maxScrollExtent,
    );
    if (target != _scroll.offset) {
      _scroll.jumpTo(target);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = ColectoPalette.of(context);
    return Listener(
      onPointerSignal: _onPointerSignal,
      child: Container(
        height: 38,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: p.lineSoft)),
        ),
        child: ScrollConfiguration(
          behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
          child: ListView(
            controller: _scroll,
            scrollDirection: Axis.horizontal,
            children: widget.children,
          ),
        ),
      ),
    );
  }
}

/// The reader's head: one tab per open message. Selecting one shows it;
/// × (or a middle click) closes it; right-click offers Close all.
class _ReaderHeader extends StatelessWidget {
  const _ReaderHeader({required this.controller});

  final MailController controller;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    if (c.openTabs.isEmpty) return const SizedBox.shrink();
    final active = c.compose == null ? c.activeTabId : null;
    return _PaneHeader(
      children: [
        for (final t in c.openTabs)
          _MessageTab(
            label: t.subject.trim().isEmpty ? '(No subject)' : t.subject,
            active: t.id == active,
            onTap: () => c.selectThread(t),
            onClose: () => c.closeTab(t.id),
            onCloseOthers: () => c.closeOtherTabs(t),
            onCloseAll: c.closeAllTabs,
          ),
      ],
    );
  }
}

class _MessageTab extends StatelessWidget {
  const _MessageTab({
    required this.label,
    required this.active,
    required this.onTap,
    required this.onClose,
    required this.onCloseOthers,
    required this.onCloseAll,
  });

  final String label;
  final bool active;
  final VoidCallback onTap;
  final VoidCallback onClose;
  final VoidCallback onCloseOthers;
  final VoidCallback onCloseAll;

  @override
  Widget build(BuildContext context) {
    final p = ColectoPalette.of(context);
    return Padding(
      padding: const EdgeInsets.only(right: 4),
      child: Center(
        child: Listener(
          onPointerDown: (e) {
            if (e.buttons == kMiddleMouseButton) onClose();
          },
          child: ColectoPressable(
            onTap: onTap,
            onSecondaryTapDown: (pos) => showColectoContextMenu(
              context: context,
              globalPosition: pos,
              title: label,
              items: [
                ColectoMenuItem(
                  label: 'Close',
                  icon: LucideIcons.x,
                  onSelected: onClose,
                ),
                ColectoMenuItem(
                  label: 'Close others',
                  onSelected: onCloseOthers,
                ),
                ColectoMenuItem(label: 'Close all', onSelected: onCloseAll),
              ],
            ),
            selected: active,
            semanticLabel: label,
            tooltip: label,
            focusRadius: colectoRadius(context),
            builder: (context, s) => AnimatedContainer(
              duration: ColectoMotion.hover,
              height: 28,
              constraints: const BoxConstraints(maxWidth: 240),
              padding: const EdgeInsets.only(left: 10, right: 4),
              decoration: BoxDecoration(
                color: active
                    ? p.raise
                    : s.hovered
                    ? p.raise.withValues(alpha: 0.5)
                    : const Color(0x00000000),
                borderRadius: BorderRadius.circular(colectoRadius(context)),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: kStyle(
                        12.5,
                        weight: active ? 560 : 450,
                        color: active ? p.ink : p.ink2,
                      ),
                    ),
                  ),
                  const SizedBox(width: 2),
                  ColectoIconButton(
                    icon: LucideIcons.x,
                    tooltip: 'Close',
                    size: 12,
                    dimension: 22,
                    onPressed: onClose,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// One modal page that follows controller state: pushed as a real route
/// when state asks for it, removed when state drops it, and reported back
/// when the person dismisses it. A design switch re-presents it in the new
/// design's modal once that design is in the tree.
class _ModalSlot {
  _ModalSlot(this._resync);

  final VoidCallback _resync;
  Route<void>? _route;
  ColectoPlatformStyle? _design;
  bool _waiting = false;

  void sync(
    NavigatorState? nav, {
    required bool open,
    required ColectoPlatformStyle design,
    required Route<void> Function() build,
    required VoidCallback onDismissed,
  }) {
    if (nav == null) return;
    final shown = _route;
    if (shown != null && (!open || design != _design)) {
      _route = null;
      if (open || !shown.isCurrent) {
        if (shown.isActive) nav.removeRoute(shown);
      } else {
        nav.pop();
      }
      if (open) {
        _waiting = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _waiting = false;
          _resync();
        });
        return;
      }
    }
    if (open && _route == null && !_waiting) {
      final route = build();
      _route = route;
      _design = design;
      nav.push(route).whenComplete(() {
        if (_route == route) {
          _route = null;
          onDismissed();
        }
      });
    }
  }

  void dispose(NavigatorState? nav) {
    final shown = _route;
    _route = null;
    if (shown != null && shown.isActive && nav != null && nav.mounted) {
      nav.removeRoute(shown);
    }
  }
}

/// A 1px line you can see, with a wider grip you can hit. Drag to resize,
/// double-click to even it out, or focus it and use the arrow keys.
class _Gutter extends StatefulWidget {
  const _Gutter({required this.onDrag, required this.onReset});

  final ValueChanged<double> onDrag;
  final VoidCallback onReset;

  @override
  State<_Gutter> createState() => _GutterState();
}

class _GutterState extends State<_Gutter> {
  bool _hot = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final p = ColectoPalette.of(context);
    final lit = _hot || _focused;
    return FocusableActionDetector(
      mouseCursor: SystemMouseCursors.resizeColumn,
      onShowHoverHighlight: (v) => setState(() => _hot = v),
      onShowFocusHighlight: (v) => setState(() => _focused = v),
      shortcuts: const {
        SingleActivator(LogicalKeyboardKey.arrowLeft): _NudgeIntent(-16),
        SingleActivator(LogicalKeyboardKey.arrowRight): _NudgeIntent(16),
        SingleActivator(LogicalKeyboardKey.arrowLeft, shift: true):
            _NudgeIntent(-64),
        SingleActivator(LogicalKeyboardKey.arrowRight, shift: true):
            _NudgeIntent(64),
      },
      actions: {
        _NudgeIntent: CallbackAction<_NudgeIntent>(
          onInvoke: (i) {
            widget.onDrag(i.dx);
            return null;
          },
        ),
      },
      child: Semantics(
        label: 'Resize message list',
        child: GestureDetector(
          behavior: HitTestBehavior.translucent,
          onHorizontalDragUpdate: (d) => widget.onDrag(d.delta.dx),
          onDoubleTap: widget.onReset,
          child: SizedBox(
            width: 1,
            child: OverflowBox(
              maxWidth: 7,
              child: Center(
                child: AnimatedContainer(
                  duration: ColectoMotion.hover,
                  width: 1,
                  color: lit ? Color.lerp(p.line, p.accent, 0.6) : p.lineSoft,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _NudgeIntent extends Intent {
  const _NudgeIntent(this.dx);

  final double dx;
}

// ───────────────────────────── Phones ─────────────────────────────

class _PhoneShell extends StatefulWidget {
  const _PhoneShell({
    required this.controller,
    required this.searchFocus,
    required this.onCompose,
    required this.onOpenDraft,
    required this.onOpenCommandPalette,
  });

  final MailController controller;
  final FocusNode searchFocus;
  final ValueChanged<ComposeRequest> onCompose;
  final ValueChanged<Draft> onOpenDraft;
  final VoidCallback onOpenCommandPalette;

  @override
  State<_PhoneShell> createState() => _PhoneShellState();
}

/// Phone pages are real routes, so the iOS edge swipe and Android predictive
/// back work. The controller stays the source of truth: routes are pushed
/// when state asks for a page and popped when it no longer does.
class _PhoneShellState extends State<_PhoneShell> {
  Route<void>? _reader;
  Route<void>? _composer;
  late final _settings = _ModalSlot(_sync);
  int? _composerKey;

  MailController get c => widget.controller;

  @override
  void initState() {
    super.initState();
    c.addListener(_sync);
    WidgetsBinding.instance.addPostFrameCallback((_) => _sync());
  }

  NavigatorState? _navigator;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _navigator = Navigator.maybeOf(context);
  }

  @override
  void dispose() {
    c.removeListener(_sync);
    // Growing past phone width swaps in the desktop shell: take the phone
    // pages down with this one. State stays in the controller.
    final nav = _navigator;
    _settings.dispose(nav);
    final pages = [_composer, _reader];
    _composer = _reader = null;
    if (nav != null && nav.mounted) {
      for (final r in pages) {
        if (r != null && r.isActive) nav.removeRoute(r);
      }
    }
    super.dispose();
  }

  NavigatorState? get _nav => mounted ? _navigator : null;

  Route<void> _route(Widget page, {bool sheet = false}) {
    switch (colectoPlatformStyle(context)) {
      case ColectoPlatformStyle.ios when sheet:
        return CupertinoSheetRoute<void>(scrollableBuilder: (_, _) => page);
      case ColectoPlatformStyle.ios:
        return CupertinoPageRoute<void>(
          fullscreenDialog: sheet,
          builder: (_) => page,
        );
      case ColectoPlatformStyle.android:
        return MaterialPageRoute<void>(
          fullscreenDialog: sheet,
          builder: (_) => page,
        );
      case ColectoPlatformStyle.desktop ||
          ColectoPlatformStyle.fluent ||
          ColectoPlatformStyle.macos:
        return PageRouteBuilder<void>(
          transitionDuration: ColectoMotion.of(
            context,
            const Duration(milliseconds: 280),
          ),
          reverseTransitionDuration: ColectoMotion.of(
            context,
            const Duration(milliseconds: 200),
          ),
          pageBuilder: (_, _, _) => page,
          transitionsBuilder: (_, a, _, child) {
            final curved = CurvedAnimation(
              parent: a,
              curve: ColectoMotion.easeOut,
              reverseCurve: Curves.easeIn,
            );
            return SlideTransition(
              position: Tween(
                begin: sheet ? const Offset(0, 1) : const Offset(1, 0),
                end: Offset.zero,
              ).animate(curved),
              child: child,
            );
          },
        );
    }
  }

  void _drop(Route<void>? route) {
    final nav = _nav;
    if (route == null || nav == null || !route.isActive) return;
    if (route.isCurrent) {
      nav.pop();
    } else {
      nav.removeRoute(route);
    }
  }

  void _sync() {
    final nav = _nav;
    if (nav == null) return;

    // Reader
    if (c.selectedMessageId != null && _reader == null) {
      final r = _route(
        _PhoneReaderPage(controller: c, onCompose: widget.onCompose),
      );
      _reader = r;
      nav.push(r).whenComplete(() {
        if (_reader == r) {
          _reader = null;
          c.clearSelection();
        }
      });
    } else if (c.selectedMessageId == null && _reader != null) {
      final r = _reader;
      _reader = null;
      _drop(r);
    }

    // Composer
    if (c.compose != null &&
        (_composer == null || _composerKey != c.composeKey)) {
      final old = _composer;
      _composer = null;
      _drop(old);
      _composerKey = c.composeKey;
      final r = _route(
        _PhoneComposerPage(
          composeKey: c.composeKey,
          controller: c,
          request: c.compose!,
          onClose: c.closeCompose,
        ),
        sheet: true,
      );
      _composer = r;
      nav.push(r).whenComplete(() {
        if (_composer == r) {
          _composer = null;
          c.closeCompose();
        }
      });
    } else if (c.compose == null && _composer != null) {
      final r = _composer;
      _composer = null;
      _drop(r);
    }

    // Settings
    _settings.sync(
      nav,
      open: c.activeSettings != null,
      design: c.design,
      build: () => colectoModalRoute(
        context,
        style: c.design,
        fullscreen: true,
        builder: (_) => ListenableBuilder(
          listenable: c,
          builder: (_, _) => SettingsView(controller: c, phone: true),
        ),
      ),
      onDismissed: c.closeSettings,
    );
  }

  // Inbox, Drafts and Sent, as in Colecto; everything else is under More.
  List<Folder> get _tabs => primaryFolders(c.folders);

  void _more() {
    showColectoModalPicker(
      context: context,
      title: 'Mailboxes',
      items: [
        for (final f in c.folders.where((f) => !_tabs.contains(f)))
          ColectoMenuItem(
            label: folderDisplayName(f),
            icon: folderIcon(f.role),
            checked: f.id == c.activeFolder,
            onSelected: () => c.selectFolder(f.id),
          ),
        const ColectoMenuItem.divider(),
        if (c.pendingApprovalCount > 0)
          ColectoMenuItem(
            label: 'Send approvals (${c.pendingApprovalCount})',
            icon: LucideIcons.shieldAlert,
            onSelected: () => c.openSettings(SettingsSection.sendApprovals),
          ),
        ColectoMenuItem(
          label: 'Settings',
          icon: LucideIcons.settings,
          onSelected: () => c.openSettings(),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = ColectoPalette.of(context);
    final style = colectoPlatformStyle(context);
    final tabs = _tabs;
    var index = tabs.indexWhere((f) => f.id == c.activeFolder);
    if (index < 0) index = tabs.length;

    void onTab(int i) {
      if (i >= tabs.length) {
        _more();
      } else {
        c.selectFolder(tabs[i].id);
      }
    }

    final title = c.currentFolderName;
    final account = Builder(
      builder: (ctx) => ColectoPressable(
        onTap: () => _accountSheet(ctx),
        tooltip: 'Accounts',
        focusRadius: 999,
        builder: (context, s) => Padding(
          padding: const EdgeInsets.all(6),
          child: ColectoAvatar(
            name: c.currentAccountInfo?.displayName ?? '?',
            hueKey: c.currentAccountInfo?.address,
            size: 30,
          ),
        ),
      ),
    );

    final List<Widget> header = switch (style) {
      ColectoPlatformStyle.ios => [
        CupertinoSliverNavigationBar(
          largeTitle: Text(title),
          leading: account,
          trailing: CupertinoButton(
            padding: EdgeInsets.zero,
            onPressed: () => widget.onCompose(const ComposeRequest()),
            child: Icon(LucideIcons.squarePen, color: p.accent, size: 22),
          ),
          backgroundColor: p.bg.withValues(alpha: 0.86),
          border: Border(bottom: BorderSide(color: p.lineSoft, width: 0.5)),
        ),
      ],
      ColectoPlatformStyle.android => [
        SliverAppBar.large(
          title: Text(title),
          backgroundColor: p.bg,
          surfaceTintColor: const Color(0x00000000),
          actions: [account, const SizedBox(width: 8)],
        ),
      ],
      _ => [
        SliverToBoxAdapter(
          child: SafeArea(
            bottom: false,
            child: Container(
              height: 54,
              padding: const EdgeInsets.only(left: 14, right: 8),
              child: Row(
                children: [
                  const ColectoBrand(),
                  const Spacer(),
                  ColectoIconButton(
                    icon: LucideIcons.search,
                    tooltip: 'Search and commands',
                    size: 18,
                    onPressed: widget.onOpenCommandPalette,
                  ),
                  account,
                  ColectoIconButton(
                    icon: LucideIcons.slidersHorizontal,
                    tooltip: 'Settings',
                    size: 18,
                    onPressed: () => c.openSettings(),
                  ),
                ],
              ),
            ),
          ),
        ),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 6, 16, 4),
            child: Text(
              title,
              style: kStyle(
                28,
                weight: 660,
                width: 108,
                color: p.ink,
                letterSpacing: -0.7,
              ),
            ),
          ),
        ),
      ],
    };

    final list = MessageListPane(
      controller: c,
      searchFocusNode: widget.searchFocus,
      onOpenDraft: widget.onOpenDraft,
      onThreadSelected: c.selectThread,
      headerSlivers: header,
      phone: true,
      // Colecto puts Compose beside search; the native designs keep it in
      // their chrome (the iOS toolbar, Material's FAB).
      onCompose:
          style == ColectoPlatformStyle.ios ||
              style == ColectoPlatformStyle.android
          ? null
          : () => widget.onCompose(const ComposeRequest()),
    );

    final destinations = [
      for (final f in tabs)
        (folderIcon(f.role), folderDisplayName(f), f.unread),
      (LucideIcons.ellipsis, 'More', c.pendingApprovalCount),
    ];

    final Widget? bottom = destinations.length < 2
        ? null
        : switch (style) {
            ColectoPlatformStyle.ios => CupertinoTabBar(
              currentIndex: index,
              onTap: onTab,
              activeColor: p.accent,
              inactiveColor: p.ink3,
              backgroundColor: p.bg.withValues(alpha: 0.86),
              border: Border(top: BorderSide(color: p.lineSoft, width: 0.5)),
              items: [
                for (final d in destinations)
                  BottomNavigationBarItem(
                    icon: Badge(
                      isLabelVisible: d.$3 > 0,
                      backgroundColor: p.accent,
                      smallSize: 7,
                      child: Icon(d.$1),
                    ),
                    label: d.$2,
                  ),
              ],
            ),
            ColectoPlatformStyle.android => NavigationBar(
              selectedIndex: index,
              onDestinationSelected: onTab,
              backgroundColor: p.bg,
              indicatorColor: p.select,
              destinations: [
                for (final d in destinations)
                  NavigationDestination(
                    icon: Badge(
                      isLabelVisible: d.$3 > 0,
                      label: Text('${d.$3}'),
                      child: Icon(d.$1, color: p.ink2),
                    ),
                    selectedIcon: Icon(d.$1, color: p.accentHi),
                    label: d.$2,
                  ),
              ],
            ),
            _ => _FolderBar(
              destinations: destinations,
              index: index,
              onTap: onTab,
            ),
          };

    return Scaffold(
      backgroundColor: p.bg,
      body: list,
      bottomNavigationBar: bottom,
      floatingActionButton: style == ColectoPlatformStyle.android
          ? FloatingActionButton.extended(
              onPressed: () => widget.onCompose(const ComposeRequest()),
              backgroundColor: p.accent,
              foregroundColor: p.accentInk,
              icon: const Icon(LucideIcons.squarePen),
              label: const Text('Compose'),
            )
          : null,
    );
  }

  void _accountSheet(BuildContext ctx) => showAccountMenu(ctx, c);
}

/// Colecto's phone folder bar: icons over labels, the active one in mint.
class _FolderBar extends StatelessWidget {
  const _FolderBar({
    required this.destinations,
    required this.index,
    required this.onTap,
  });

  final List<(IconData, String, int)> destinations;
  final int index;
  final ValueChanged<int> onTap;

  @override
  Widget build(BuildContext context) {
    final p = ColectoPalette.of(context);
    return Container(
      decoration: BoxDecoration(
        color: p.bg,
        border: Border(top: BorderSide(color: p.lineSoft)),
      ),
      padding: EdgeInsets.fromLTRB(
        8,
        4,
        8,
        4 + MediaQuery.paddingOf(context).bottom,
      ),
      child: Row(
        children: [
          for (var i = 0; i < destinations.length; i++)
            Expanded(
              child: ColectoPressable(
                onTap: () => onTap(i),
                selected: i == index,
                semanticLabel: destinations[i].$2,
                builder: (context, s) {
                  final on = i == index;
                  final color = on ? p.accent : (s.hovered ? p.ink : p.ink3);
                  return SizedBox(
                    height: 56,
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Stack(
                          clipBehavior: Clip.none,
                          children: [
                            Icon(destinations[i].$1, size: 20, color: color),
                            if (destinations[i].$3 > 0)
                              Positioned(
                                top: -1,
                                right: -3,
                                child: Container(
                                  width: 7,
                                  height: 7,
                                  decoration: BoxDecoration(
                                    color: p.accent,
                                    shape: BoxShape.circle,
                                    border: Border.all(color: p.bg),
                                  ),
                                ),
                              ),
                          ],
                        ),
                        const SizedBox(height: 3),
                        Text(
                          destinations[i].$2,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: kStyle(11.5, weight: 560, color: color),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }
}

class _PhoneReaderPage extends StatelessWidget {
  const _PhoneReaderPage({required this.controller, required this.onCompose});

  final MailController controller;
  final ValueChanged<ComposeRequest> onCompose;

  @override
  Widget build(BuildContext context) {
    final p = ColectoPalette.of(context);
    return Scaffold(
      backgroundColor: p.bg,
      body: SafeArea(
        bottom: false,
        child: ListenableBuilder(
          listenable: controller,
          builder: (context, _) => ReaderPane(
            controller: controller,
            onCompose: onCompose,
            showBackButton: true,
            onBack: () => Navigator.of(context).maybePop(),
          ),
        ),
      ),
    );
  }
}

class _PhoneComposerPage extends StatelessWidget {
  const _PhoneComposerPage({
    required this.composeKey,
    required this.controller,
    required this.request,
    required this.onClose,
  });

  final int composeKey;
  final MailController controller;
  final ComposeRequest request;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final p = ColectoPalette.of(context);
    return Scaffold(
      backgroundColor: p.bg,
      body: SafeArea(
        bottom: false,
        child: ComposerView(
          key: ValueKey('compose-$composeKey'),
          controller: controller,
          request: request,
          onClose: onClose,
          phone: true,
        ),
      ),
    );
  }
}

// ───────────────────────────── Connect ─────────────────────────────

/// Colecto's connect page: the mark, one line on what this is, and the two
/// fields it needs.
class _ConnectScreen extends StatefulWidget {
  const _ConnectScreen({required this.controller});

  final MailController controller;

  @override
  State<_ConnectScreen> createState() => _ConnectScreenState();
}

class _ConnectScreenState extends State<_ConnectScreen> {
  late final _url = TextEditingController(text: widget.controller.daemonUrl);
  final _token = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _url.dispose();
    _token.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    if (_busy) return;
    setState(() => _busy = true);
    await widget.controller.authenticateDaemon(_url.text, _token.text);
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final p = ColectoPalette.of(context);
    final error = widget.controller.error;
    return Scaffold(
      backgroundColor: p.ground,
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 440),
            child: AutofillGroup(
              child: Container(
                padding: const EdgeInsets.all(32),
                decoration: BoxDecoration(
                  color: p.bg,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: p.line),
                  boxShadow: p.floatShadow,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Align(
                      alignment: Alignment.centerLeft,
                      child: ColectoMark(size: 44),
                    ),
                    const SizedBox(height: 18),
                    Text(
                      'Connect to Colecto',
                      style: kStyle(
                        22,
                        weight: 640,
                        width: 106,
                        color: p.ink,
                        letterSpacing: -0.4,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Enter the address of your colecto-daemon and the '
                      'access token it printed when it started.',
                      style: kStyle(13.5, color: p.ink2, height: 1.55),
                    ),
                    const SizedBox(height: 20),
                    ColectoTextField(
                      controller: _url,
                      labelText: 'Daemon address',
                      hintText: 'http://127.0.0.1:4173',
                      keyboardType: TextInputType.url,
                      textInputAction: TextInputAction.next,
                      autofillHints: const [AutofillHints.url],
                    ),
                    const SizedBox(height: 14),
                    ColectoTextField(
                      controller: _token,
                      labelText: 'Access token',
                      obscureText: true,
                      autofocus: true,
                      textInputAction: TextInputAction.go,
                      autofillHints: const [AutofillHints.password],
                      onSubmitted: (_) => _connect(),
                    ),
                    if (error != null) ...[
                      const SizedBox(height: 14),
                      ColectoErrorBox(message: error),
                    ],
                    const SizedBox(height: 20),
                    ColectoButton(
                      label: _busy ? 'Connecting…' : 'Connect',
                      variant: ColectoButtonVariant.primary,
                      expand: true,
                      onPressed: _busy ? null : _connect,
                    ),
                    const SizedBox(height: 10),
                    ColectoButton(
                      label: 'Try the demo instead',
                      variant: ColectoButtonVariant.ghost,
                      expand: true,
                      onPressed: _busy
                          ? null
                          : () => widget.controller.switchBackend(
                              kind: BackendKind.demo,
                            ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
