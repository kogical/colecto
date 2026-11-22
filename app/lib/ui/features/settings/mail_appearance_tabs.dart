import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:material_ui/material_ui.dart';

import '../../../domain/models/preferences_models.dart';
import '../../core/kit/kit.dart';
import '../../core/theme/colecto_palette.dart';
import '../../core/widgets/corner_picker.dart';
import '../shell/mail_controller.dart';

/// Settings → Mail: how Colecto keeps mail ready to read.
class MailSettingsTab extends StatelessWidget {
  const MailSettingsTab({super.key, required this.controller});

  final MailController controller;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final prefetch = c.preferences.prefetch;
    void set(PrefetchPreferences v) =>
        c.updatePreferences(PreferencesPatch(prefetch: v));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const ColectoPageHead(
          title: 'Mail',
          description: 'How Colecto keeps your mail ready to read.',
        ),
        ColectoSection(
          title: 'Ready to read',
          children: [
            ColectoSettingRow(
              title: 'Download recent mail ahead of time',
              description:
                  'After each refresh, the newest messages are saved so they '
                  'open instantly, even offline. This never marks them as '
                  'read.',
              trailing: ColectoSwitch(
                value: prefetch.enabled,
                onChanged: (v) => set(prefetch.copyWith(enabled: v)),
              ),
            ),
            if (prefetch.enabled) ...[
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerLeft,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 400),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          const Expanded(
                            child: ColectoText(
                              'Messages to keep ready',
                              role: ColectoTextRole.bodyStrong,
                            ),
                          ),
                          ColectoText(
                            '${prefetch.count}',
                            role: ColectoTextRole.label,
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      const ColectoParagraph(
                        'The newest messages in your Inbox. More uses more '
                        'storage and bandwidth; messages over 10 MB still open '
                        'on demand.',
                        small: true,
                        tone: ColectoTone.secondary,
                      ),
                      const SizedBox(height: 10),
                      ColectoSlider(
                        value: prefetch.count.clamp(10, 100),
                        min: 10,
                        max: 100,
                        divisions: 9,
                        semanticLabel: 'Messages to keep ready',
                        onChanged: (n) => set(prefetch.copyWith(count: n)),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ],
        ),
      ],
    );
  }
}

/// Settings → Appearance: text, colour, the message list, then the theme,
/// design and zoom.
class AppearanceSettingsTab extends StatefulWidget {
  const AppearanceSettingsTab({super.key, required this.controller});

  final MailController controller;

  @override
  State<AppearanceSettingsTab> createState() => _AppearanceSettingsTabState();
}

class _AppearanceSettingsTabState extends State<AppearanceSettingsTab> {
  static const _defaultAccent = '#a2d6b1';

  // Light, low-chroma tones that stay readable as text and as a fill.
  static const _presets = <(String, String)>[
    (_defaultAccent, 'Mint'),
    ('#8ec5f0', 'Sky'),
    ('#a9b4f5', 'Periwinkle'),
    ('#c9a8f0', 'Lilac'),
    ('#f0a8c0', 'Rose'),
    ('#f2b09a', 'Coral'),
    ('#ecc98a', 'Amber'),
    ('#c4dd8f', 'Lime'),
  ];

  static const _fonts = <(String, String)>[
    ('', 'Platform default'),
    ('mona', 'Mona Sans'),
    ('inter', 'Inter'),
    ('geist', 'Geist'),
    ('plex', 'IBM Plex Sans'),
    ('atkinson', 'Atkinson Hyperlegible Next'),
  ];

  static const _sizes = <(int, String)>[
    (13, 'Small'),
    (14, 'Default'),
    (16, 'Large'),
    (18, 'Larger'),
  ];

  // More room around letters, words, lines and paragraphs helps many
  // readers with dyslexia.
  static const _spacings = [
    ('Letter spacing', 'Space between characters.'),
    ('Word spacing', 'Space between words.'),
    ('Line height', 'Space between lines.'),
    (
      'Paragraph spacing',
      'Space between paragraphs, in mail and descriptions.',
    ),
  ];

  final _hex = TextEditingController();

  @override
  void dispose() {
    _hex.dispose();
    super.dispose();
  }

  void _setAccent(String hex) =>
      widget.controller.updatePreferences(PreferencesPatch(accent: hex));

  void _customAccent(String v) {
    final hex = (v.startsWith('#') ? v : '#$v').toLowerCase();
    if (ColectoPalette.parseHexColor(hex) != null) {
      _hex.clear();
      _setAccent(hex == _defaultAccent ? '' : hex);
    } else {
      widget.controller.showToast(
        'That isn’t a colour',
        detail: 'Use six hex digits, like #a2d6b1.',
        isError: true,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = ColectoPalette.of(context);
    final c = widget.controller;
    final prefs = c.preferences;
    final spacing = prefs.textSpacing;
    final spacingValues = [
      spacing.letter,
      spacing.word,
      spacing.line,
      spacing.paragraph,
    ];
    TextSpacing withSpacing(int i, int v) => switch (i) {
      0 => spacing.copyWith(letter: v),
      1 => spacing.copyWith(word: v),
      2 => spacing.copyWith(line: v),
      _ => spacing.copyWith(paragraph: v),
    };
    final textChanged =
        (prefs.font ?? '').isNotEmpty ||
        (prefs.fontSize ?? 14) != 14 ||
        spacingValues.any((v) => v != 0);
    final accent = (prefs.accent ?? '').toLowerCase();
    final materialYou = c.design == ColectoPlatformStyle.android;
    final systemColors = materialYou && accent.isEmpty;
    final current = accent.isEmpty ? _defaultAccent : accent;
    final custom = !_presets.any((e) => e.$1 == current);
    final size = _sizes.any((e) => e.$1 == prefs.fontSize)
        ? prefs.fontSize!
        : 14;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const ColectoPageHead(
          title: 'Appearance',
          description:
              'Choose how text looks, the accent used for selection, focus '
              'and primary buttons, and how the message list is laid out.',
        ),
        ColectoSection(
          title: 'Text',
          children: [
            ColectoSettingRow(
              title: 'Font',
              description:
                  'Bundled fonts work offline on every device. Platform '
                  'default uses your system’s interface font.',
              trailing: ColectoSelect<String>(
                value: prefs.font ?? '',
                minWidth: 220,
                options: _fonts,
                onChanged: (f) =>
                    c.updatePreferences(PreferencesPatch(font: f)),
              ),
            ),
            ColectoSettingRow(
              title: 'Text size',
              description: 'Scales text across the app.',
              trailing: ColectoSegmented<int>(
                value: size,
                options: _sizes,
                onChanged: (v) =>
                    c.updatePreferences(PreferencesPatch(fontSize: v)),
              ),
            ),
            for (final (i, (name, text)) in _spacings.indexed)
              ColectoSettingRow(
                title: name,
                description: text,
                trailing: ColectoSegmented<int>(
                  value: spacingValues[i],
                  options: const [(0, 'Normal'), (1, 'More'), (2, 'Most')],
                  onChanged: (v) => c.updatePreferences(
                    PreferencesPatch(textSpacing: withSpacing(i, v)),
                  ),
                ),
              ),
            if (textChanged)
              Align(
                alignment: Alignment.centerLeft,
                child: ColectoButton(
                  label: 'Reset text to defaults',
                  variant: ColectoButtonVariant.text,
                  onPressed: () => c.updatePreferences(
                    const PreferencesPatch(
                      font: '',
                      fontSize: 14,
                      textSpacing: TextSpacing(),
                    ),
                  ),
                ),
              ),
          ],
        ),
        ColectoSection(
          title: 'Colour',
          children: [
            if (materialYou)
              ColectoSettingRow(
                title: 'Use system colours',
                description:
                    'Match Android’s Material You palette. Turn off to pick '
                    'your own accent.',
                trailing: ColectoSwitch(
                  value: systemColors,
                  onChanged: (on) =>
                      _setAccent(on ? '' : ColectoPalette.toHex(p.accent)),
                ),
              ),
            if (!systemColors) ...[
              const SizedBox(height: 8),
              const ColectoText('Accent', role: ColectoTextRole.bodyStrong),
              const SizedBox(height: 4),
              const ColectoParagraph(
                'Used for selection, focus and primary buttons. Pick a '
                'preset or any colour.',
                small: true,
                tone: ColectoTone.secondary,
              ),
              const SizedBox(height: 14),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  for (final (hex, name) in _presets)
                    _Swatch(
                      color: ColectoPalette.parseHexColor(hex)!,
                      name: name,
                      selected: current == hex,
                      onTap: () => _setAccent(hex == _defaultAccent ? '' : hex),
                    ),
                  if (custom)
                    _Swatch(
                      color: ColectoPalette.parseHexColor(current) ?? p.accent,
                      name: 'Custom colour $current',
                      selected: true,
                      onTap: () {},
                    ),
                  SizedBox(
                    width: 130,
                    child: ColectoTextField(
                      controller: _hex,
                      hintText: 'Custom #hex',
                      onSubmitted: _customAccent,
                    ),
                  ),
                ],
              ),
              if (accent.isNotEmpty)
                Align(
                  alignment: Alignment.centerLeft,
                  child: Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: ColectoButton(
                      label: 'Restore the default mint',
                      variant: ColectoButtonVariant.text,
                      onPressed: () => _setAccent(''),
                    ),
                  ),
                ),
            ],
          ],
        ),
        ColectoSection(
          title: 'Message list',
          children: [
            ColectoSettingRow(
              title: 'Density',
              description:
                  'Full shows a preview line, Medium is shorter, Compact fits '
                  'each message on one line.',
              trailing: ColectoSegmented<ListDensity>(
                value: prefs.listDensity,
                options: [for (final d in ListDensity.values) (d, d.label)],
                onChanged: (d) =>
                    c.updatePreferences(PreferencesPatch(listDensity: d)),
              ),
            ),
            ColectoSettingRow(
              title: 'Date headings',
              description:
                  'Group messages under Today, Yesterday and month names.',
              trailing: ColectoSwitch(
                value: prefs.dateGroups,
                onChanged: (v) =>
                    c.updatePreferences(PreferencesPatch(dateGroups: v)),
              ),
            ),
            ColectoSettingRow(
              title: 'Load older messages on scroll',
              description:
                  'Fetch the next batch at the bottom of the list. When off, '
                  'a Load more button appears instead.',
              trailing: ColectoSwitch(
                value: prefs.autoLoadMore,
                onChanged: (v) =>
                    c.updatePreferences(PreferencesPatch(autoLoadMore: v)),
              ),
            ),
          ],
        ),
        ColectoSection(
          title: 'Window',
          children: [
            ColectoSettingRow(
              title: 'Theme',
              description: 'System follows your device.',
              trailing: ColectoSegmented<ThemeMode>(
                value: c.themeMode,
                options: const [
                  (ThemeMode.system, 'System'),
                  (ThemeMode.dark, 'Dark'),
                  (ThemeMode.light, 'Light'),
                ],
                onChanged: c.setThemeMode,
              ),
            ),
            ColectoSettingRow(
              title: 'Design',
              description: c.designForcedByLaunch
                  ? 'Set by COLECTO_DESIGN for this launch. Your choice here '
                        'is saved and used next time.'
                  : 'Each platform gets its own controls by default, but any '
                        'design works anywhere.',
              trailing: ColectoSelect<ColectoPlatformStyle>(
                value: c.design,
                minWidth: 220,
                options: [
                  for (final d in ColectoPlatformStyle.values)
                    (
                      d,
                      d == ColectoPlatformStyle.native()
                          ? '${d.label} · native'
                          : d.label,
                    ),
                ],
                onChanged: c.setDesign,
              ),
            ),
            ColectoSettingRow(
              title: colectoTouch(context) ? 'Interface size' : 'Zoom',
              description: colectoTouch(context)
                  ? 'Make everything on screen bigger or smaller.'
                  : 'Make everything bigger or smaller. '
                        '${colectoModKey(context)} +, '
                        '${colectoModKey(context)} − and '
                        '${colectoModKey(context)} 0 work anywhere.',
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ColectoIconButton(
                    icon: LucideIcons.minus,
                    tooltip: 'Zoom out',
                    onPressed: c.zoom <= 0.5 ? null : c.zoomOut,
                  ),
                  SizedBox(
                    width: 52,
                    child: ColectoText(
                      '${(c.zoom * 100).round()}%',
                      role: ColectoTextRole.bodyStrong,
                      align: TextAlign.center,
                    ),
                  ),
                  ColectoIconButton(
                    icon: LucideIcons.plus,
                    tooltip: 'Zoom in',
                    onPressed: c.zoom >= 2 ? null : c.zoomIn,
                  ),
                  const SizedBox(width: 4),
                  ColectoButton(
                    label: 'Reset',
                    variant: ColectoButtonVariant.ghost,
                    onPressed: c.zoom == 1 ? null : c.resetZoom,
                  ),
                ],
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _Swatch extends StatelessWidget {
  const _Swatch({
    required this.color,
    required this.name,
    required this.selected,
    required this.onTap,
  });

  final Color color;
  final String name;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = ColectoPalette.of(context);
    return ColectoPressable(
      onTap: onTap,
      tooltip: name,
      semanticLabel: name,
      selected: selected,
      pressScale: 0.92,
      focusRadius: 999,
      builder: (context, s) => AnimatedContainer(
        duration: ColectoMotion.hover,
        width: 34,
        height: 34,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          boxShadow: selected
              ? [
                  BoxShadow(color: p.bg, spreadRadius: 2),
                  BoxShadow(color: color, spreadRadius: 4),
                ]
              : null,
        ),
        child: AnimatedOpacity(
          opacity: selected ? 1 : 0,
          duration: ColectoMotion.hover,
          child: Icon(
            LucideIcons.check,
            size: 16,
            color: Color.lerp(const Color(0xFF000000), color, 0.14),
          ),
        ),
      ),
    );
  }
}

/// Settings → Notifications: whether Colecto shows them, and how.
class NotificationsSettingsTab extends StatelessWidget {
  const NotificationsSettingsTab({super.key, required this.controller});

  final MailController controller;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final n = c.preferences.notifications;
    void set(NotificationPreferences v) =>
        c.updatePreferences(PreferencesPatch(notifications: v));
    final changed =
        n.system || n.position != const NotificationPreferences().position;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const ColectoPageHead(
          title: 'Notifications',
          description:
              'Colecto tells you about new mail and automation waiting for '
              'your approval. Notifications show over everything in the '
              'window, Settings included.',
        ),
        ColectoSection(
          children: [
            ColectoSettingRow(
              title: 'Show notifications',
              description:
                  'Turn every in-app and desktop notification on or off. '
                  'Errors always show.',
              trailing: ColectoSwitch(
                value: n.enabled,
                onChanged: (v) => set(n.copyWith(enabled: v)),
              ),
            ),
          ],
        ),
        ColectoSection(
          title: 'Delivery',
          children: [
            ColectoSettingRow(
              title: colectoTouch(context)
                  ? 'System notifications'
                  : 'Desktop notifications',
              description: colectoTouch(context)
                  ? 'Also alert your device, but only while Colecto is in '
                        'the background.'
                  : 'Also alert your desktop, but only while Colecto is in '
                        'the background.',
              trailing: ColectoSwitch(
                value: n.system,
                onChanged: n.enabled ? (v) => set(n.copyWith(system: v)) : null,
              ),
            ),
            const SizedBox(height: 14),
            const ColectoText('Position', role: ColectoTextRole.bodyStrong),
            const SizedBox(height: 4),
            ColectoParagraph(
              'Where notifications appear in the window: '
              '${n.position.label.toLowerCase()}.',
              small: true,
              tone: ColectoTone.secondary,
            ),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerLeft,
              child: CornerPicker(
                value: n.position,
                onChanged: (corner) => set(n.copyWith(position: corner)),
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 12,
              children: [
                ColectoButton(
                  label: 'Show a test notification',
                  variant: ColectoButtonVariant.text,
                  onPressed: () => c.showToast(
                    'This is where notifications appear',
                    detail: 'Pick another spot above to move them.',
                  ),
                ),
                if (changed)
                  ColectoButton(
                    label: 'Reset to defaults',
                    variant: ColectoButtonVariant.text,
                    onPressed: () =>
                        set(NotificationPreferences(enabled: n.enabled)),
                  ),
              ],
            ),
          ],
        ),
      ],
    );
  }
}

/// Settings → Privacy.
class PrivacySettingsTab extends StatelessWidget {
  const PrivacySettingsTab({super.key, required this.controller});

  final MailController controller;

  @override
  Widget build(BuildContext context) {
    final prefs = controller.preferences;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const ColectoPageHead(
          title: 'Privacy',
          description:
              'Choose what Colecto fetches from other servers when you open '
              'a message.',
        ),
        ColectoSection(
          children: [
            ColectoSettingRow(
              title: 'Load remote images automatically',
              description:
                  'Senders can use remote images to see when and where you '
                  'open their mail. When this is off, each message asks '
                  'first.',
              trailing: ColectoSwitch(
                value: prefs.remoteImages,
                onChanged: (v) => controller.updatePreferences(
                  PreferencesPatch(remoteImages: v),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// Settings → Connection: the mail service this app uses, and another one
/// to switch to.
class ServersSettingsTab extends StatefulWidget {
  const ServersSettingsTab({super.key, required this.controller});

  final MailController controller;

  @override
  State<ServersSettingsTab> createState() => _ServersSettingsTabState();
}

class _ServersSettingsTabState extends State<ServersSettingsTab> {
  late final _url = TextEditingController(
    text: widget.controller.backendKind == BackendKind.remoteHttp
        ? widget.controller.daemonUrl
        : '',
  );
  final _token = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _url.dispose();
    _token.dispose();
    super.dispose();
  }

  void _open() {
    final c = widget.controller;
    final value = _url.text.trim();
    final url = Uri.tryParse(value);
    final loopback = const {
      'localhost',
      '127.0.0.1',
      '::1',
    }.contains(url?.host);
    String? error;
    if (url == null || !url.hasScheme || url.host.isEmpty) {
      error = 'Enter an address like https://mail.example.com.';
    } else if (url.scheme != 'https' && !(url.scheme == 'http' && loopback)) {
      error = 'Use HTTPS. Plain HTTP works only on this computer (localhost).';
    } else if (url.userInfo.isNotEmpty || url.hasQuery || url.hasFragment) {
      error = 'Leave credentials and tokens out of the address.';
    } else if (_token.text.trim().isEmpty &&
        !(c.backendKind == BackendKind.remoteHttp &&
            c.daemonUrl == url.origin)) {
      error = 'Enter the server’s access token.';
    }
    setState(() => _error = error);
    if (error != null) return;
    c.authenticateDaemon(
      url!.origin,
      _token.text.trim().isEmpty ? c.daemonToken : _token.text.trim(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = ColectoPalette.of(context);
    final c = widget.controller;
    final ver = c.version;
    final kind = c.backendKind;
    final (icon, title, detail) = switch (kind) {
      BackendKind.remoteHttp => (
        LucideIcons.globe,
        'Remote server',
        c.daemonUrl,
      ),
      BackendKind.localFfi => (LucideIcons.monitor, 'This app', 'This device'),
      BackendKind.demo => (
        LucideIcons.flaskConical,
        'Demo mail',
        'Sample mail, kept in memory',
      ),
    };
    final canUseLocal = !kIsWeb && kind != BackendKind.localFfi;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const ColectoPageHead(
          title: 'Connection',
          description:
              'Accounts and drafts belong to the mail service you are '
              'connected to.',
        ),
        ColectoSection(
          children: [
            Wrap(
              spacing: 16,
              runSpacing: 12,
              crossAxisAlignment: WrapCrossAlignment.center,
              alignment: WrapAlignment.spaceBetween,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                        color: p.raise,
                        borderRadius: BorderRadius.circular(
                          colectoRadius(context) + 2,
                        ),
                      ),
                      child: Icon(icon, size: 18, color: p.ink2),
                    ),
                    const SizedBox(width: 12),
                    Flexible(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          ColectoText(title, role: ColectoTextRole.bodyStrong),
                          const SizedBox(height: 2),
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              ColectoStatusDot(on: !c.authRequired),
                              const SizedBox(width: 6),
                              Flexible(
                                child: ColectoText.caption(
                                  '${c.authRequired ? 'Not connected' : 'Connected'}'
                                  '  ·  $detail',
                                  maxLines: 1,
                                ),
                              ),
                            ],
                          ),
                          if (ver != null)
                            ColectoText.caption(
                              '${ver.name} ${ver.version} · API ${ver.api}'
                              '${ver.commit != null ? ' · ${ver.commit}' : ''}',
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
                if (canUseLocal)
                  ColectoButton(
                    label: 'Use this app instead',
                    onPressed: () =>
                        c.switchBackend(kind: BackendKind.localFfi),
                  ),
              ],
            ),
          ],
        ),
        ColectoSection(
          title: 'Use another server',
          description:
              'Connect to a Colecto daemon by its HTTPS address and access '
              'token. Your credentials stay on that server.',
          children: [
            Align(
              alignment: Alignment.centerLeft,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 480),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    ColectoTextField(
                      controller: _url,
                      labelText: 'Server address',
                      hintText: 'https://mail.example.com',
                      keyboardType: TextInputType.url,
                      onChanged: (_) => setState(() => _error = null),
                    ),
                    const SizedBox(height: 12),
                    ColectoTextField(
                      controller: _token,
                      labelText: 'Access token',
                      hintText: kind == BackendKind.remoteHttp
                          ? 'Unchanged'
                          : null,
                      obscureText: true,
                      onSubmitted: (_) => _open(),
                    ),
                  ],
                ),
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              ColectoErrorBox(message: _error!),
            ],
            const SizedBox(height: 14),
            Wrap(
              spacing: 12,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                ColectoButton(label: 'Connect', onPressed: _open),
                if (kind == BackendKind.remoteHttp)
                  ColectoButton(
                    label: 'Forget this session’s access token',
                    variant: ColectoButtonVariant.text,
                    onPressed: c.forgetSessionToken,
                  ),
                if (kind != BackendKind.demo)
                  ColectoButton(
                    label: 'Explore the demo mail',
                    variant: ColectoButtonVariant.text,
                    onPressed: () => c.switchBackend(kind: BackendKind.demo),
                  ),
              ],
            ),
          ],
        ),
      ],
    );
  }
}
