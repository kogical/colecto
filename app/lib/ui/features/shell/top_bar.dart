import 'package:flutter/foundation.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:material_ui/material_ui.dart';

import '../../../domain/models/account_models.dart';
import '../../../domain/models/preferences_models.dart';
import '../../core/theme/colecto_palette.dart';
import '../../core/widgets/colecto_mark.dart';
import '../../core/kit/kit.dart';
import 'mail_controller.dart';

/// Colecto's slim top bar: brand on the left, the command trigger centred,
/// Send approvals (only while one waits) and Settings on the right. Each
/// design draws it as its own title bar or toolbar. These are host controls
/// and do not move.
class ColectoTopBar extends StatelessWidget {
  const ColectoTopBar({
    super.key,
    required this.controller,
    required this.onOpenCommandPalette,
  });

  final MailController controller;
  final VoidCallback onOpenCommandPalette;

  @override
  Widget build(BuildContext context) {
    final p = ColectoPalette.of(context);
    final style = colectoPlatformStyle(context);
    final c = controller;
    final (height, color, border, searchShare, searchMax) = switch (style) {
      ColectoPlatformStyle.fluent => (48.0, p.ground, false, 0.4, 480.0),
      ColectoPlatformStyle.macos => (52.0, p.float, true, 0.36, 420.0),
      ColectoPlatformStyle.android => (64.0, p.sunk, false, 0.46, 720.0),
      ColectoPlatformStyle.ios => (52.0, p.bg, true, 0.4, 480.0),
      ColectoPlatformStyle.desktop => (46.0, p.ground, true, 0.42, 520.0),
    };
    // Reserve room for macOS traffic lights only when running natively on macOS.
    final macTrafficLights =
        !kIsWeb &&
        defaultTargetPlatform == TargetPlatform.macOS &&
        style == ColectoPlatformStyle.macos;
    return Container(
      height: height,
      padding: EdgeInsets.only(left: macTrafficLights ? 80 : 14, right: 8),
      decoration: BoxDecoration(
        color: color,
        border: border
            ? Border(
                bottom: BorderSide(
                  color: p.lineSoft,
                  width: style == ColectoPlatformStyle.ios ? 0.5 : 1,
                ),
              )
            : null,
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final roomy = constraints.maxWidth > 820;
          return Row(
            children: [
              Expanded(
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: _goHome(_lead(context, style, roomy)),
                ),
              ),
              // `grid-template-columns: 1fr minmax(0, 520px) 1fr`.
              SizedBox(
                width: (constraints.maxWidth * searchShare).clamp(
                  180.0,
                  searchMax,
                ),
                child: _CommandTrigger(onTap: onOpenCommandPalette),
              ),
              Expanded(
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    if (c.hasUpdateBanner && roomy) ...[
                      Flexible(child: _UpdateChip(controller: c)),
                      const SizedBox(width: 6),
                    ],
                    if (c.pendingApprovalCount > 0) ...[
                      Flexible(child: _ApprovalsChip(controller: c)),
                      const SizedBox(width: 4),
                    ],
                    ColectoIconButton(
                      icon: LucideIcons.slidersHorizontal,
                      tooltip: 'Settings (${colectoModKey(context)}+,)',
                      onPressed: () => c.openSettings(),
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _goHome(Widget child) => ColectoPressable(
    onTap: () {
      controller.closeSettings();
      controller.selectFolder('inbox');
    },
    tooltip: 'Go to Inbox',
    focusRadius: 6,
    pressScale: 0.98,
    builder: (context, s) => child,
  );

  /// The brand, as each platform's title bar shows an app's name.
  Widget _lead(BuildContext context, ColectoPlatformStyle style, bool roomy) {
    final p = ColectoPalette.of(context);
    Widget named(double mark, double gap, TextStyle text) => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        ColectoMark(size: mark),
        SizedBox(width: gap),
        Text('Colecto', style: text),
      ],
    );
    return switch (style) {
      ColectoPlatformStyle.desktop =>
        roomy ? const ColectoBrand() : const ColectoMark(size: 24),
      ColectoPlatformStyle.fluent => named(18, 12, kStyle(12, color: p.ink2)),
      ColectoPlatformStyle.macos => named(
        18,
        8,
        kStyle(13, weight: 700, color: p.ink),
      ),
      ColectoPlatformStyle.android => named(28, 12, kStyle(20, color: p.ink)),
      ColectoPlatformStyle.ios => Text(
        'Colecto',
        style: kStyle(17, weight: 600, color: p.ink),
      ),
    };
  }
}

/// Shown only while a send waits for the owner's approval.
class _ApprovalsChip extends StatelessWidget {
  const _ApprovalsChip({required this.controller});

  final MailController controller;

  @override
  Widget build(BuildContext context) {
    final p = ColectoPalette.of(context);
    final n = controller.pendingApprovalCount;
    return ColectoPressable(
      onTap: () => controller.openSettings(SettingsSection.sendApprovals),
      tooltip: n == 1 ? '1 send waits for you' : '$n sends wait for you',
      focusRadius: colectoRadius(context),
      builder: (context, s) => AnimatedContainer(
        duration: ColectoMotion.hover,
        height: 30,
        padding: const EdgeInsets.only(left: 9, right: 6),
        decoration: BoxDecoration(
          color: s.hovered ? p.raise : p.select,
          borderRadius: BorderRadius.circular(colectoRadius(context)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(LucideIcons.shieldAlert, size: 14, color: p.accent),
            const SizedBox(width: 7),
            Flexible(
              child: Text(
                'Send approvals',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: kStyle(12.5, weight: 560, color: p.ink),
              ),
            ),
            const SizedBox(width: 7),
            ColectoBadge(text: '$n', accent: true),
          ],
        ),
      ),
    );
  }
}

/// The search / command trigger, drawn as each design's search box.
class _CommandTrigger extends StatelessWidget {
  const _CommandTrigger({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = ColectoPalette.of(context);
    final style = colectoPlatformStyle(context);
    final mod = colectoModKey(context);
    final (height, radius, fill, hint) = switch (style) {
      ColectoPlatformStyle.fluent => (
        32.0,
        4.0,
        p.ink.withValues(alpha: p.isDark ? 0.06 : 0.04),
        'Search mail or run a command',
      ),
      ColectoPlatformStyle.macos => (
        28.0,
        6.0,
        p.ink.withValues(alpha: 0.07),
        'Search mail or run a command',
      ),
      ColectoPlatformStyle.android => (
        48.0,
        28.0,
        p.raise,
        'Search mail or commands',
      ),
      ColectoPlatformStyle.ios => (
        36.0,
        10.0,
        p.control,
        'Search mail or commands',
      ),
      ColectoPlatformStyle.desktop => (
        30.0,
        7.0,
        p.sunk,
        'Search mail or run a command',
      ),
    };
    final iconLeft = style != ColectoPlatformStyle.fluent;
    final showShortcut = style.pointer;
    return ColectoPressable(
      onTap: onTap,
      pressScale: 0.99,
      semanticLabel: 'Search and commands',
      tooltip: '$mod+K',
      focusRadius: radius,
      builder: (context, s) {
        final icon = Icon(
          LucideIcons.search,
          size: style == ColectoPlatformStyle.android ? 20 : 15,
          color: s.hovered ? p.ink2 : p.ink3,
        );
        return AnimatedContainer(
          duration: ColectoMotion.hover,
          height: height,
          padding: EdgeInsets.symmetric(
            horizontal: style == ColectoPlatformStyle.android ? 16 : 10,
          ),
          decoration: BoxDecoration(
            color: s.hovered && style != ColectoPlatformStyle.desktop
                ? Color.lerp(fill, p.ink, 0.04)
                : fill,
            borderRadius: BorderRadius.circular(radius),
            border: switch (style) {
              ColectoPlatformStyle.desktop => Border.all(
                color: s.hovered ? p.line : p.lineSoft,
              ),
              ColectoPlatformStyle.fluent => Border.all(
                color: p.ink3.withValues(alpha: 0.35),
              ),
              _ => null,
            },
          ),
          child: Row(
            children: [
              if (iconLeft) ...[
                icon,
                SizedBox(width: style == ColectoPlatformStyle.android ? 14 : 8),
              ],
              Expanded(
                child: Text(
                  hint,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: kStyle(
                    style == ColectoPlatformStyle.android ? 16 : 13,
                    color: s.hovered ? p.ink2 : p.ink3,
                  ),
                ),
              ),
              if (showShortcut) ...[
                ColectoKbd(mod, raised: true),
                const SizedBox(width: 3),
                const ColectoKbd('K', raised: true),
                if (!iconLeft) const SizedBox(width: 8),
              ],
              if (!iconLeft) icon,
            ],
          ),
        );
      },
    );
  }
}

class _UpdateChip extends StatelessWidget {
  const _UpdateChip({required this.controller});

  final MailController controller;

  @override
  Widget build(BuildContext context) {
    final version = controller.releaseStatus!.latest!.version;
    return ColectoChip(
      label: 'Colecto $version is out',
      icon: LucideIcons.sparkles,
      selected: true,
      onTap: () => controller.updatePreferences(
        PreferencesPatch(notifiedRelease: version),
      ),
    );
  }
}

/// The account switcher: avatar, name and live sync status; it opens a
/// listbox with every enabled account.
class AccountSwitcher extends StatelessWidget {
  const AccountSwitcher({
    super.key,
    required this.controller,
    this.showName = true,
    this.expand = false,
  });

  final MailController controller;
  final bool showName;

  /// Fills the width of the pane it sits in.
  final bool expand;

  @override
  Widget build(BuildContext context) {
    final p = ColectoPalette.of(context);
    final c = controller;
    final current = c.currentAccountInfo;
    final sync = c.currentAccountSync;
    final online = sync?.isOnline ?? (current?.connected ?? false);
    final status = sync == null
        ? (online ? 'Connected' : 'Offline')
        : sync.error != null
        ? 'Sync paused'
        : sync.activity == SyncActivity.syncing
        ? 'Syncing…'
        : sync.mode.label;

    return Builder(
      builder: (ctx) => ColectoPressable(
        onTap: () => showAccountMenu(ctx, c),
        onSecondaryTapDown: (pos) => showColectoContextMenu(
          context: ctx,
          globalPosition: pos,
          title: c.currentAccountInfo?.displayName,
          items: [
            ColectoMenuItem(
              label: 'Check for new mail',
              icon: LucideIcons.refreshCw,
              onSelected: () => c.loadMailbox(refresh: true),
            ),
            ColectoMenuItem(
              label: 'Account settings…',
              icon: LucideIcons.settings,
              onSelected: () => c.openSettings(SettingsSection.accounts),
            ),
          ],
        ),
        pressScale: 0.98,
        tooltip: showName ? null : current?.displayName,
        semanticLabel: 'Current account: ${current?.displayName ?? 'none'}',
        builder: (context, s) => AnimatedContainer(
          duration: ColectoMotion.hover,
          height: expand ? 44 : 40,
          padding: EdgeInsets.only(left: 6, right: showName ? 8 : 6),
          decoration: BoxDecoration(
            color: s.hovered ? p.raise : const Color(0x00000000),
            borderRadius: BorderRadius.circular(7),
          ),
          child: Row(
            mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
            children: [
              ColectoAvatar(
                name: current?.displayName ?? '?',
                hueKey: current?.address,
                size: 28,
              ),
              if (showName) ...[
                const SizedBox(width: 10),
                Flexible(
                  fit: expand ? FlexFit.tight : FlexFit.loose,
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        current?.displayName ?? 'No account',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: kStyle(
                          13,
                          weight: 600,
                          color: p.ink,
                          height: 1.25,
                        ),
                      ),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          ColectoStatusDot(
                            on: online,
                            error: sync?.error != null,
                          ),
                          const SizedBox(width: 6),
                          Flexible(
                            child: Text(
                              status,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: kStyle(11.5, color: p.ink3, height: 1.25),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Icon(LucideIcons.chevronsUpDown, size: 14, color: p.ink3),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

void showAccountMenu(BuildContext anchorContext, MailController c) {
  if (colectoTouch(anchorContext)) {
    final style = colectoPlatformStyle(anchorContext);
    Navigator.of(anchorContext).push<void>(
      colectoModalRoute(
        anchorContext,
        style: style,
        fullscreen: style == ColectoPlatformStyle.android,
        builder: (ctx) => _AccountSwitcherModal(controller: c),
      ),
    );
    return;
  }
  final items = [
    for (final a in c.enabledAccounts)
      ColectoMenuItem(
        label: a.displayName,
        subtitle: a.address,
        checked: a.id == c.activeAccount,
        onSelected: () => c.selectAccount(a.id),
      ),
    const ColectoMenuItem.divider(),
    ColectoMenuItem(
      label: 'Add or manage accounts…',
      icon: LucideIcons.userRoundPlus,
      onSelected: () => c.openSettings(SettingsSection.accounts),
    ),
  ];
  showColectoMenu(
    context: anchorContext,
    anchor: colectoRectOf(anchorContext),
    items: items,
    width: 260,
    alignRight: !(colectoRectOf(anchorContext).left < 200),
  );
}

class _AccountSwitcherModal extends StatelessWidget {
  const _AccountSwitcherModal({required this.controller});

  final MailController controller;

  @override
  Widget build(BuildContext context) {
    final p = ColectoPalette.of(context);
    final c = controller;
    return ColoredBox(
      color: p.bg,
      child: Column(
        children: [
          ColectoNavBar(
            title: 'Accounts',
            onClose: () => Navigator.of(context).pop(),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(vertical: 8),
              children: [
                for (final a in c.enabledAccounts)
                  ColectoPressable(
                    onTap: () {
                      Navigator.of(context).pop();
                      c.selectAccount(a.id);
                    },
                    builder: (context, s) => Container(
                      color: s.hovered ? p.raise : const Color(0x00000000),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 18,
                        vertical: 12,
                      ),
                      child: Row(
                        children: [
                          ColectoAvatar(
                            name: a.displayName,
                            hueKey: a.address,
                            size: 36,
                          ),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  a.displayName,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: kStyle(15, weight: 600, color: p.ink),
                                ),
                                if (a.address.isNotEmpty &&
                                    a.address != a.displayName)
                                  Text(
                                    a.address,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: kStyle(12.5, color: p.ink3),
                                  ),
                              ],
                            ),
                          ),
                          if (a.id == c.activeAccount) ...[
                            const SizedBox(width: 12),
                            Icon(LucideIcons.check, size: 18, color: p.accent),
                          ],
                        ],
                      ),
                    ),
                  ),
                Divider(height: 16, color: p.lineSoft),
                ColectoPressable(
                  onTap: () {
                    Navigator.of(context).pop();
                    c.openSettings(SettingsSection.accounts);
                  },
                  builder: (context, s) => Container(
                    color: s.hovered ? p.raise : const Color(0x00000000),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 18,
                      vertical: 13,
                    ),
                    child: Row(
                      children: [
                        Icon(
                          LucideIcons.userRoundPlus,
                          size: 18,
                          color: p.ink2,
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Text(
                            'Add or manage accounts…',
                            style: kStyle(15, weight: 500, color: p.ink),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
