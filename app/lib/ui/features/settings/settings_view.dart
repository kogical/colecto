import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/theme/colecto_palette.dart';
import '../../core/kit/kit.dart';
import '../shell/mail_controller.dart';
import 'accounts_settings_tab.dart';
import 'ai_settings_tab.dart';
import 'automation_tabs.dart';
import 'mail_appearance_tabs.dart';

/// Colecto's Settings: a section list on the left, a breadcrumb and a close
/// button over the page, inside the design's own modal (see
/// `colectoModalRoute`). On phones it starts at the section list and each
/// section opens as its own page; in a narrow window the sections scroll
/// sideways above the page.
class SettingsView extends StatefulWidget {
  const SettingsView({super.key, required this.controller, this.phone = false});

  final MailController controller;
  final bool phone;

  @override
  State<SettingsView> createState() => _SettingsViewState();
}

class _SettingsViewState extends State<SettingsView> {
  final _scroll = ScrollController();
  SettingsSection? _shown;

  /// The section list folded to icons, as in Colecto's Settings.
  bool _collapsed = false;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  Widget _page(SettingsSection section) {
    final c = widget.controller;
    return switch (section) {
      SettingsSection.accounts => AccountsSettingsTab(controller: c),
      SettingsSection.mail => MailSettingsTab(controller: c),
      SettingsSection.appearance => AppearanceSettingsTab(controller: c),
      SettingsSection.notifications => NotificationsSettingsTab(controller: c),
      SettingsSection.privacy => PrivacySettingsTab(controller: c),
      SettingsSection.servers => ServersSettingsTab(controller: c),
      SettingsSection.ai => AiSettingsTab(controller: c),
      SettingsSection.apiKeys => ApiKeysSettingsTab(controller: c),
      SettingsSection.sendApprovals => SendApprovalsSettingsTab(controller: c),
    };
  }

  @override
  Widget build(BuildContext context) {
    final p = ColectoPalette.of(context);
    final c = widget.controller;
    final section = c.activeSettings ?? SettingsSection.accounts;
    if (_shown != section) {
      _shown = section;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _scroll.hasClients) _scroll.jumpTo(0);
      });
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = !widget.phone && constraints.maxWidth >= 720;
        final narrowPage = constraints.maxWidth < 600;
        final page = Scrollbar(
          controller: _scroll,
          child: SingleChildScrollView(
            controller: _scroll,
            padding: EdgeInsets.fromLTRB(
              narrowPage ? 16 : 48,
              narrowPage ? 20 : 32,
              narrowPage ? 16 : 48,
              48 + MediaQuery.paddingOf(context).bottom,
            ),
            child: Align(
              alignment: Alignment.topLeft,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 720),
                child: KeyedSubtree(
                  key: ValueKey(section),
                  child: _page(section),
                ),
              ),
            ),
          ),
        );

        final head = Container(
          height: widget.phone ? 54 : 52,
          padding: EdgeInsets.only(left: wide ? 24 : 16, right: 10),
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: p.lineSoft)),
          ),
          child: Row(
            children: [
              Expanded(
                child: Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(
                        text: 'Settings',
                        style: kStyle(13.5, color: p.ink3),
                      ),
                      TextSpan(
                        text: '  /  ',
                        style: kStyle(13.5, color: p.ink3),
                      ),
                      TextSpan(
                        text: section.label,
                        style: kStyle(13.5, weight: 600, color: p.ink),
                      ),
                    ],
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              ColectoIconButton(
                icon: LucideIcons.x,
                tooltip: 'Close settings (Esc)',
                size: 18,
                onPressed: c.closeSettings,
              ),
            ],
          ),
        );

        if (widget.phone) return _phone(context, section, page);

        if (!wide) {
          return ColoredBox(
            color: p.bg,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                head,
                Container(
                  height: 52,
                  decoration: BoxDecoration(
                    border: Border(bottom: BorderSide(color: p.lineSoft)),
                  ),
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 6,
                    ),
                    children: [
                      for (final s in c.visibleSettingsSections)
                        _NavItem(
                          section: s,
                          selected: s == section,
                          badge: _badge(s),
                          dense: true,
                          onTap: () => c.openSettings(s),
                        ),
                    ],
                  ),
                ),
                Expanded(child: page),
              ],
            ),
          );
        }

        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AnimatedContainer(
              duration: ColectoMotion.of(
                context,
                const Duration(milliseconds: 200),
              ),
              curve: ColectoMotion.easeOut,
              width: _collapsed ? 60 : 228,
              decoration: BoxDecoration(
                color: p.sunk,
                border: Border(right: BorderSide(color: p.lineSoft)),
              ),
              child: ListView(
                padding: const EdgeInsets.fromLTRB(10, 12, 10, 12),
                children: [
                  SizedBox(
                    height: 40,
                    child: Row(
                      children: [
                        if (!_collapsed)
                          Expanded(
                            child: Padding(
                              padding: const EdgeInsets.only(left: 10),
                              child: Text(
                                'Settings',
                                maxLines: 1,
                                overflow: TextOverflow.clip,
                                softWrap: false,
                                style: kStyle(
                                  18,
                                  weight: 640,
                                  width: 108,
                                  color: p.ink,
                                  letterSpacing: -0.27,
                                ),
                              ),
                            ),
                          ),
                        ColectoIconButton(
                          icon: LucideIcons.panelLeft,
                          tooltip: _collapsed
                              ? 'Expand the section list'
                              : 'Collapse the section list',
                          size: 17,
                          onPressed: () =>
                              setState(() => _collapsed = !_collapsed),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 10),
                  if (!_collapsed)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(10, 0, 10, 6),
                      child: Text(
                        'BUILT-IN',
                        style: kStyle(
                          11,
                          weight: 600,
                          color: p.ink3,
                          letterSpacing: 0.66,
                        ),
                      ),
                    ),
                  for (final s in c.visibleSettingsSections)
                    _NavItem(
                      section: s,
                      selected: s == section,
                      badge: _badge(s),
                      iconOnly: _collapsed,
                      onTap: () => c.openSettings(s),
                    ),
                ],
              ),
            ),
            Expanded(
              child: ColoredBox(
                color: p.bg,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    head,
                    Expanded(child: page),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  /// Phones: the section list, then each section as a page. Back (the
  /// button, the system gesture) returns to the list.
  Widget _phone(BuildContext context, SettingsSection section, Widget page) {
    final p = ColectoPalette.of(context);
    final c = widget.controller;
    final index = c.showsSettingsIndex;
    return PopScope(
      canPop: index,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) c.showSettingsIndex();
      },
      child: ColoredBox(
        color: p.bg,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ColectoNavBar(
              // A page's large title sits at the top of its content.
              title: index ? 'Settings' : '',
              backLabel: 'Settings',
              onBack: index ? null : c.showSettingsIndex,
              onClose: c.closeSettings,
            ),
            Expanded(
              child: index
                  ? ListView(
                      padding: EdgeInsets.only(
                        top: 8,
                        bottom: 24 + MediaQuery.paddingOf(context).bottom,
                      ),
                      children: [
                        ColectoNavList(
                          entries: [
                            for (final s in c.visibleSettingsSections)
                              (
                                icon: s.icon,
                                label: s.label,
                                badge: _badge(s),
                                onTap: () => c.openSettings(s),
                              ),
                          ],
                        ),
                      ],
                    )
                  : page,
            ),
          ],
        ),
      ),
    );
  }

  int _badge(SettingsSection s) => s == SettingsSection.sendApprovals
      ? widget.controller.pendingApprovalCount
      : 0;
}

class _NavItem extends StatelessWidget {
  const _NavItem({
    required this.section,
    required this.selected,
    required this.onTap,
    this.badge = 0,
    this.dense = false,
    this.iconOnly = false,
  });

  final SettingsSection section;
  final bool selected;
  final VoidCallback onTap;
  final int badge;
  final bool dense;
  final bool iconOnly;

  @override
  Widget build(BuildContext context) {
    final p = ColectoPalette.of(context);
    final style = colectoPlatformStyle(context);
    final material = style == ColectoPlatformStyle.android;
    final ios = style == ColectoPlatformStyle.ios;
    final fluent = style == ColectoPlatformStyle.fluent;
    final radius = switch (style) {
      ColectoPlatformStyle.android => 28.0,
      ColectoPlatformStyle.ios => 10.0,
      ColectoPlatformStyle.fluent => 4.0,
      _ => 8.0,
    };
    return Padding(
      padding: dense
          ? const EdgeInsets.only(right: 4)
          : const EdgeInsets.only(bottom: 2),
      child: ColectoPressable(
        onTap: onTap,
        selected: selected,
        semanticLabel: section.label,
        tooltip: iconOnly ? section.label : null,
        focusRadius: radius,
        builder: (context, s) => AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          height: dense ? 40 : (material || ios ? 44 : (fluent ? 36 : 34)),
          padding: EdgeInsets.symmetric(horizontal: material ? 16 : 10),
          decoration: BoxDecoration(
            color: selected
                ? (material
                      ? p.select
                      : ios
                      ? p.accent
                      : fluent
                      ? p.ink.withValues(alpha: 0.08)
                      : p.raise)
                : s.hovered
                ? (fluent || ios || material
                      ? p.ink.withValues(alpha: 0.05)
                      : p.raise)
                : const Color(0x00000000),
            borderRadius: BorderRadius.circular(radius),
            border: fluent && selected && !dense
                ? Border(left: BorderSide(color: p.accent, width: 3))
                : null,
          ),
          child: Row(
            mainAxisSize: dense ? MainAxisSize.min : MainAxisSize.max,
            children: [
              Icon(
                section.icon,
                size: 16,
                color: ios && selected
                    ? p.accentInk
                    : ios || selected
                    ? (material ? p.accentHi : p.accent)
                    : (s.hovered ? p.ink2 : p.ink3),
              ),
              if (iconOnly)
                const SizedBox.shrink()
              else ...[
                const SizedBox(width: 10),
                if (dense)
                  Text(
                    section.label,
                    style: kStyle(
                      13.5,
                      weight: 560,
                      color: ios && selected
                          ? p.accentInk
                          : material && selected
                          ? p.accentHi
                          : selected || s.hovered
                          ? p.ink
                          : p.ink2,
                    ),
                  )
                else
                  Expanded(
                    child: Text(
                      section.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: kStyle(
                        ios ? 15 : (material ? 14 : 13.5),
                        weight: ios ? 400 : 560,
                        color: ios && selected
                            ? p.accentInk
                            : material && selected
                            ? p.accentHi
                            : selected || s.hovered
                            ? p.ink
                            : p.ink2,
                      ),
                    ),
                  ),
                if (badge > 0) ...[
                  const SizedBox(width: 8),
                  ColectoBadge(text: '$badge', accent: true),
                ],
              ],
            ],
          ),
        ),
      ),
    );
  }
}
