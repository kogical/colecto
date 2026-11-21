part of 'kit.dart';

/// A settings page head: a 24 px wide-width title and a short lead.
class ColectoPageHead extends StatelessWidget {
  const ColectoPageHead({
    super.key,
    required this.title,
    this.description,
    this.action,
  });

  final String title;
  final String? description;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 24),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ColectoText.title(title),
                if (description != null) ...[
                  const SizedBox(height: 8),
                  ColectoParagraph(description!),
                ],
              ],
            ),
          ),
          if (action != null) ...[const SizedBox(width: 16), action!],
        ],
      ),
    );
  }
}

/// Colecto's `.settings-card`: not a card at all, but a section divided from
/// the one above by a hairline.
class ColectoSection extends StatelessWidget {
  const ColectoSection({
    super.key,
    this.title,
    this.description,
    this.trailing,
    required this.children,
  });

  final String? title;
  final String? description;
  final Widget? trailing;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final p = ColectoPalette.of(context);
    return Container(
      padding: const EdgeInsets.only(top: 22, bottom: 24),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: p.lineSoft)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (title != null)
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      ColectoText.heading(title!),
                      if (description != null) ...[
                        const SizedBox(height: 6),
                        ColectoParagraph(description!),
                      ],
                    ],
                  ),
                ),
                if (trailing != null) ...[
                  const SizedBox(width: 24),
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: trailing!,
                  ),
                ],
              ],
            ),
          if (title != null && children.isNotEmpty) const SizedBox(height: 16),
          ...children,
        ],
      ),
    );
  }
}

/// Colecto's `.setting-row`: a title and description with the control on
/// the right. In a narrow page a wide control (segmented, select) moves
/// under the text; a switch stays on the right.
class ColectoSettingRow extends StatelessWidget {
  const ColectoSettingRow({
    super.key,
    required this.title,
    this.description,
    required this.trailing,
  });

  final String title;
  final String? description;
  final Widget trailing;

  @override
  Widget build(BuildContext context) {
    final text = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ColectoText(title, role: ColectoTextRole.bodyStrong),
        if (description != null) ...[
          const SizedBox(height: 4),
          ColectoParagraph(
            description!,
            small: true,
            tone: ColectoTone.secondary,
          ),
        ],
      ],
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: _SettingRowLayout(
        keepBeside: trailing is ColectoSwitch,
        children: [text, trailing],
      ),
    );
  }
}

/// Lays a setting's text and control side by side, or the control under
/// the text when the text would get narrower than [_minText].
class _SettingRowLayout extends MultiChildRenderObjectWidget {
  const _SettingRowLayout({required this.keepBeside, required super.children});

  final bool keepBeside;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderSettingRow(keepBeside);

  @override
  void updateRenderObject(BuildContext context, _RenderSettingRow r) =>
      r.keepBeside = keepBeside;
}

class _SettingRowData extends ContainerBoxParentData<RenderBox> {}

class _RenderSettingRow extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, _SettingRowData>,
        RenderBoxContainerDefaultsMixin<RenderBox, _SettingRowData> {
  _RenderSettingRow(this._keepBeside);

  static const _gap = 24.0;
  static const _minText = 220.0;

  bool _keepBeside;
  set keepBeside(bool v) {
    if (v == _keepBeside) return;
    _keepBeside = v;
    markNeedsLayout();
  }

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _SettingRowData) {
      child.parentData = _SettingRowData();
    }
  }

  @override
  void performLayout() {
    final text = firstChild!;
    final control = childAfter(text)!;
    final width = constraints.maxWidth;
    // The control takes its natural width (never more than the row).
    control.layout(BoxConstraints(maxWidth: width), parentUsesSize: true);
    final beside = _keepBeside || width - control.size.width - _gap >= _minText;
    final textData = text.parentData! as _SettingRowData;
    final controlData = control.parentData! as _SettingRowData;
    if (beside) {
      text.layout(
        BoxConstraints(
          maxWidth: math.max(0, width - control.size.width - _gap),
        ),
        parentUsesSize: true,
      );
      final h = math.max(text.size.height, control.size.height);
      textData.offset = Offset(0, (h - text.size.height) / 2);
      controlData.offset = Offset(
        width - control.size.width,
        (h - control.size.height) / 2,
      );
      size = constraints.constrain(Size(width, h));
    } else {
      text.layout(BoxConstraints(maxWidth: width), parentUsesSize: true);
      textData.offset = Offset.zero;
      controlData.offset = Offset(0, text.size.height + 10);
      size = constraints.constrain(
        Size(width, text.size.height + 10 + control.size.height),
      );
    }
  }

  @override
  void paint(PaintingContext context, Offset offset) =>
      defaultPaint(context, offset);

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      defaultHitTestChildren(result, position: position);
}

/// A small field label (Colecto's `legend` / `.row-label`).
class ColectoLabel extends StatelessWidget {
  const ColectoLabel(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: ColectoText.label(text),
    );
  }
}

/// A phone page's bar: back, the title and Close, drawn as the design's
/// own navigation bar (a Cupertino navigation bar with *Done*, a Material
/// top app bar, or Colecto's slim bar).
class ColectoNavBar extends StatelessWidget {
  const ColectoNavBar({
    super.key,
    required this.title,
    this.onBack,
    this.backLabel,
    this.onClose,
  });

  final String title;
  final VoidCallback? onBack;

  /// The page back leads to (iOS shows it beside the chevron).
  final String? backLabel;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    final p = ColectoPalette.of(context);
    switch (colectoPlatformStyle(context)) {
      case ColectoPlatformStyle.ios:
        return CupertinoNavigationBar(
          automaticallyImplyLeading: false,
          automaticallyImplyMiddle: false,
          leading: onBack == null
              ? null
              : CupertinoNavigationBarBackButton(
                  previousPageTitle: backLabel,
                  color: p.accent,
                  onPressed: onBack,
                ),
          middle: Text(title, style: kStyle(17, weight: 600, color: p.ink)),
          trailing: onClose == null
              ? null
              : CupertinoButton(
                  padding: EdgeInsets.zero,
                  onPressed: onClose,
                  child: Text(
                    'Done',
                    style: kStyle(17, weight: 600, color: p.accent),
                  ),
                ),
          backgroundColor: p.bg.withValues(alpha: 0.86),
          border: Border(bottom: BorderSide(color: p.lineSoft, width: 0.5)),
        );
      case ColectoPlatformStyle.android:
        return SizedBox(
          height: 64,
          child: AppBar(
            primary: false,
            automaticallyImplyLeading: false,
            leading: onBack == null
                ? null
                : IconButton(
                    tooltip: 'Back',
                    icon: const Icon(LucideIcons.arrowLeft),
                    onPressed: onBack,
                  ),
            title: Text(title),
            backgroundColor: p.bg,
            surfaceTintColor: const Color(0x00000000),
            actions: [
              if (onClose != null)
                IconButton(
                  tooltip: 'Close',
                  icon: const Icon(LucideIcons.x),
                  onPressed: onClose,
                ),
              const SizedBox(width: 4),
            ],
          ),
        );
      case ColectoPlatformStyle.desktop ||
          ColectoPlatformStyle.fluent ||
          ColectoPlatformStyle.macos:
        return Container(
          height: 54,
          padding: EdgeInsets.only(left: onBack == null ? 16 : 6, right: 8),
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: p.lineSoft)),
          ),
          child: Row(
            children: [
              if (onBack != null)
                ColectoIconButton(
                  icon: LucideIcons.chevronLeft,
                  tooltip: backLabel == null ? 'Back' : 'Back to $backLabel',
                  onPressed: onBack,
                ),
              Expanded(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: kStyle(15, weight: 620, color: p.ink),
                ),
              ),
              if (onClose != null)
                ColectoIconButton(
                  icon: LucideIcons.x,
                  tooltip: 'Close',
                  size: 18,
                  onPressed: onClose,
                ),
            ],
          ),
        );
    }
  }
}

/// One row of a [ColectoNavList].
typedef ColectoNavEntry = ({
  IconData icon,
  String label,
  int badge,
  VoidCallback onTap,
});

/// A list of pages to open, drawn as the design's own: an inset grouped
/// list with chevrons (iOS), Material list items (Android) or Colecto rows.
class ColectoNavList extends StatelessWidget {
  const ColectoNavList({super.key, required this.entries});

  final List<ColectoNavEntry> entries;

  @override
  Widget build(BuildContext context) {
    final p = ColectoPalette.of(context);
    switch (colectoPlatformStyle(context)) {
      case ColectoPlatformStyle.ios:
        return CupertinoListSection.insetGrouped(
          backgroundColor: p.bg,
          decoration: BoxDecoration(
            color: p.raise,
            borderRadius: BorderRadius.circular(10),
          ),
          separatorColor: p.lineSoft,
          children: [
            for (final e in entries)
              CupertinoListTile(
                leading: Icon(e.icon, size: 20, color: p.accent),
                title: Text(e.label, style: kStyle(17, color: p.ink)),
                additionalInfo: e.badge > 0
                    ? ColectoBadge(text: '${e.badge}', accent: true)
                    : null,
                trailing: const CupertinoListTileChevron(),
                onTap: e.onTap,
              ),
          ],
        );
      case ColectoPlatformStyle.android:
        return Column(
          children: [
            for (final e in entries)
              ListTile(
                leading: Icon(e.icon, color: p.ink2),
                title: Text(e.label, style: kStyle(16, color: p.ink)),
                trailing: e.badge > 0
                    ? ColectoBadge(text: '${e.badge}', accent: true)
                    : null,
                minTileHeight: 56,
                onTap: e.onTap,
              ),
          ],
        );
      case ColectoPlatformStyle.desktop ||
          ColectoPlatformStyle.fluent ||
          ColectoPlatformStyle.macos:
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Column(
            children: [
              for (final e in entries)
                ColectoPressable(
                  onTap: e.onTap,
                  semanticLabel: e.label,
                  focusRadius: colectoRadius(context),
                  builder: (context, s) => AnimatedContainer(
                    duration: ColectoMotion.hover,
                    height: 48,
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    decoration: BoxDecoration(
                      color: s.hovered || s.pressed
                          ? p.raise
                          : const Color(0x00000000),
                      borderRadius: BorderRadius.circular(
                        colectoRadius(context),
                      ),
                    ),
                    child: Row(
                      children: [
                        Icon(e.icon, size: 17, color: p.accent),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Text(
                            e.label,
                            style: kStyle(15, weight: 520, color: p.ink),
                          ),
                        ),
                        if (e.badge > 0) ...[
                          ColectoBadge(text: '${e.badge}', accent: true),
                          const SizedBox(width: 8),
                        ],
                        Icon(LucideIcons.chevronRight, size: 16, color: p.ink3),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        );
    }
  }
}
