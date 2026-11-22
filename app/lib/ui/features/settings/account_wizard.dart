import 'package:file_selector/file_selector.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:material_ui/material_ui.dart';

import '../../../domain/models/account_models.dart';
import '../../core/kit/kit.dart';
import '../../core/theme/colecto_palette.dart';
import '../shell/mail_controller.dart';

/// Opens Add an account (or Edit account for [account]) in the design's own
/// modal: a dialog or sheet on wide screens, a full-screen page on phones.
Future<void> showAccountWizard(
  BuildContext context,
  MailController controller, {
  AccountInfo? account,
}) {
  final phone = MediaQuery.sizeOf(context).width < 600;
  return Navigator.of(context).push(
    colectoModalRoute(
      context,
      fullscreen: phone,
      maxSize: const Size(580, 720),
      fitContent: true,
      builder: (ctx) => AccountWizard(
        controller: controller,
        account: account,
        title: account == null ? 'Add an account' : 'Edit account',
        description:
            '${account == null ? 'Start with your email address; Colecto '
                      'looks up the server settings.' : 'Change servers or sign-in details.'}'
            ' IMAP, SMTP and JMAP; POP3 is not supported.',
        submitLabel: account == null ? 'Save account' : 'Save changes',
        onClose: () => Navigator.of(ctx).maybePop(),
        onSaved: (saved, name) {
          Navigator.of(ctx).pop();
          controller.showToast(
            '$name saved',
            detail: 'Colecto checks the connection in the background.',
          );
        },
      ),
    ),
  );
}

enum _Step { email, servers, review }

enum _Field {
  protocol,
  imapHost,
  imapPort,
  imapStarttls,
  smtpHost,
  smtpPort,
  jmapHost,
  jmapPort,
  username,
}

/// Adding or editing a mail account in three steps: the email address (with
/// a settings lookup), the servers, and a review. Settings → Accounts opens
/// it in a modal; onboarding shows it in its card. Going back never loses
/// what the owner typed: a new address only changes fields a lookup filled.
class AccountWizard extends StatefulWidget {
  const AccountWizard({
    super.key,
    required this.controller,
    required this.title,
    required this.submitLabel,
    required this.onSaved,
    this.description,
    this.onClose,
    this.account,
  });

  final MailController controller;
  final String title;
  final String? description;
  final String submitLabel;
  final VoidCallback? onClose;
  final AccountInfo? account;
  final void Function(AccountInfo saved, String name) onSaved;

  @override
  State<AccountWizard> createState() => _AccountWizardState();
}

class _AccountWizardState extends State<AccountWizard> {
  final _scroll = ScrollController();
  final _address = TextEditingController();
  final _name = TextEditingController();
  final _imapHost = TextEditingController();
  final _smtpHost = TextEditingController();
  final _jmapHost = TextEditingController();
  final _username = TextEditingController();
  final _secret = TextEditingController();
  final _master = TextEditingController();
  final _masterConfirm = TextEditingController();

  _Step _step = _Step.email;
  MailProtocol _protocol = MailProtocol.imap;
  int _imapPort = 993;
  bool _imapStarttls = false;
  int _smtpPort = 587;
  int _jmapPort = 443;
  String _certificate = '';

  /// Fields the owner changed; a lookup never overwrites them.
  final _touched = <_Field>{};

  /// The lookup behind the server values, for the address it ran for.
  ({String address, DiscoveryResult? found, List<_Field> kept})? _lookup;
  bool _looking = false;
  int _attempt = 0;
  final _cache = <String, ({String address, DiscoveryResult? found})>{};

  bool _working = false;
  String? _error;
  bool _needsMaster = false;

  @override
  void initState() {
    super.initState();
    final s = widget.account?.settings;
    if (s != null) {
      _address.text = s.address;
      _name.text = s.name;
      _protocol = s.protocol;
      _imapHost.text = s.imapHost;
      _imapPort = s.imapPort;
      _imapStarttls = s.imapStarttls;
      _smtpHost.text = s.smtpHost;
      _smtpPort = s.smtpPort;
      final jmap = _splitJmap(s.sessionUrl);
      _jmapHost.text = jmap.host;
      _jmapPort = jmap.port;
      _username.text = s.username;
      _certificate = s.tlsCertificate;
      _touched.addAll(_Field.values);
      _lookup = (address: s.address, found: null, kept: const []);
      _step = _Step.servers;
    }
  }

  @override
  void dispose() {
    for (final c in [
      _scroll,
      _address,
      _name,
      _imapHost,
      _smtpHost,
      _jmapHost,
      _username,
      _secret,
      _master,
      _masterConfirm,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  String get _current => _address.text.trim();
  String get _domain => _current.split('@').last.toLowerCase();
  DiscoveryResult? get _found =>
      _lookup?.address == _current ? _lookup!.found : null;
  bool get _limited =>
      _found?.limitation == 'oauth_only' || _found?.limitation == 'no_access';

  void _go(_Step next) {
    setState(() {
      _step = next;
      _error = null;
      _needsMaster = false;
      _master.clear();
      _masterConfirm.clear();
    });
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  void _touch(_Field f) => _touched.add(f);

  bool _validAddress() {
    final at = _current.lastIndexOf('@');
    if (at > 0 && at < _current.length - 1) return true;
    setState(() => _error = 'Enter an email address, like you@example.com.');
    return false;
  }

  Future<void> _findSettings() async {
    if (!_validAddress()) return;
    final current = _current;
    if (_lookup?.address == current) {
      if (!_limited) _go(_Step.servers);
      return;
    }
    var cached = _cache[_domain];
    if (cached == null) {
      final mine = ++_attempt;
      setState(() {
        _looking = true;
        _error = null;
      });
      final result = await widget.controller.discoverAccount(current);
      if (!mounted || mine != _attempt) return;
      cached = (address: current, found: result);
      _cache[_domain] = cached;
      setState(() => _looking = false);
    }
    var found = cached.found;
    // A lookup reused from another address on the same domain carries that
    // address's username.
    String local(String v) => v.substring(0, v.lastIndexOf('@'));
    if (found != null && found.username == cached.address) {
      found = _withUsername(found, current);
    } else if (found?.username != null &&
        found!.username == local(cached.address)) {
      found = _withUsername(found, local(current));
    }
    _apply(current, found);
    if (!_limited) _go(_Step.servers);
  }

  DiscoveryResult _withUsername(DiscoveryResult f, String username) =>
      DiscoveryResult(
        sources: f.sources,
        provider: f.provider,
        imap: f.imap,
        smtp: f.smtp,
        jmap: f.jmap,
        username: username,
        appPassword: f.appPassword,
        limitation: f.limitation,
      );

  /// Fills every field the owner has not changed from a lookup; with
  /// nothing found only an untouched username follows the address.
  void _apply(String address, DiscoveryResult? found) {
    void set(_Field f, void Function() write) {
      if (!_touched.contains(f)) write();
    }

    setState(() {
      if (found != null) {
        if (found.imap != null && found.smtp != null) {
          set(_Field.protocol, () => _protocol = MailProtocol.imap);
          set(_Field.imapHost, () => _imapHost.text = found.imap!.host);
          set(_Field.imapPort, () => _imapPort = found.imap!.port);
          set(
            _Field.imapStarttls,
            () => _imapStarttls =
                found.imap!.security == DiscoverySecurity.starttls,
          );
          set(_Field.smtpHost, () => _smtpHost.text = found.smtp!.host);
          set(_Field.smtpPort, () => _smtpPort = found.smtp!.port);
        } else if (found.jmap != null) {
          set(_Field.protocol, () => _protocol = MailProtocol.jmap);
        }
        if (found.jmap != null) {
          final j = _splitJmap(found.jmap!);
          set(_Field.jmapHost, () => _jmapHost.text = j.host);
          set(_Field.jmapPort, () => _jmapPort = j.port);
        }
      }
      set(_Field.username, () => _username.text = found?.username ?? address);
      _lookup = (
        address: address,
        found: found,
        kept: found == null
            ? const []
            : [
                for (final f in _touched)
                  if (f != _Field.username) f,
              ],
      );
    });
  }

  void _manual() {
    if (!_validAddress()) return;
    _attempt++;
    setState(() => _looking = false);
    if (_lookup?.address != _current) _apply(_current, null);
    _go(_Step.servers);
  }

  String? _serversProblem() {
    if (_protocol == MailProtocol.imap) {
      if (_imapHost.text.trim().isEmpty) return 'Enter the incoming server.';
      if (_smtpHost.text.trim().isEmpty) return 'Enter the outgoing server.';
      if (_username.text.trim().isEmpty) return 'Enter your username.';
    } else if (_jmapHost.text.trim().isEmpty) {
      return 'Enter the JMAP server.';
    }
    if (widget.account == null && _secret.text.isEmpty) {
      return 'Enter your ${_passwordLabel.toLowerCase()}.';
    }
    return null;
  }

  String _jmapSession() {
    final saved = widget.account?.settings;
    if (_protocol != MailProtocol.jmap) return saved?.sessionUrl ?? '';
    final initial = _splitJmap(saved?.sessionUrl ?? '');
    if (saved != null &&
        _jmapHost.text == initial.host &&
        _jmapPort == initial.port) {
      return saved.sessionUrl;
    }
    return _joinJmap(_jmapHost.text, _jmapPort);
  }

  Future<void> _submit() async {
    switch (_step) {
      case _Step.email:
        return _findSettings();
      case _Step.servers:
        final problem = _serversProblem();
        if (problem != null) {
          setState(() => _error = problem);
          return;
        }
        return _go(_Step.review);
      case _Step.review:
        break;
    }
    setState(() {
      _error = null;
      _working = true;
    });
    final c = widget.controller;
    if (_needsMaster) {
      if (_master.text.length < 12) {
        return setState(() {
          _working = false;
          _error = 'Use a master password of at least 12 characters.';
        });
      }
      if (_master.text != _masterConfirm.text) {
        return setState(() {
          _working = false;
          _error = 'Master passwords do not match.';
        });
      }
      await c.runSecurityAction('protect', password: _master.text);
      if (!mounted) return;
      if (!c.security.protected) {
        return setState(() => _working = false);
      }
      _master.clear();
      _masterConfirm.clear();
      _needsMaster = false;
    }
    String? failure;
    final settings = AccountSettings(
      name: _name.text.trim(),
      address: _current,
      protocol: _protocol,
      imapHost: _imapHost.text.trim(),
      imapPort: _imapPort,
      imapStarttls: _imapStarttls,
      smtpHost: _smtpHost.text.trim(),
      smtpPort: _smtpPort,
      username: _username.text.trim(),
      sessionUrl: _jmapSession(),
      tlsCertificate: _certificate,
    );
    final saved = await c.saveAccount(
      AccountInput(
        id: widget.account?.id,
        settings: settings,
        secret: _secret.text,
      ),
      onError: (m) => failure = m,
    );
    if (!mounted) return;
    setState(() => _working = false);
    if (saved != null) {
      _secret.clear();
      widget.onSaved(saved, settings.name.isEmpty ? _current : settings.name);
      return;
    }
    setState(() {
      _error = failure;
      if (failure?.contains('master password') ?? false) _needsMaster = true;
    });
    if (_needsMaster) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scroll.hasClients) {
          _scroll.animateTo(
            _scroll.position.maxScrollExtent,
            duration: const Duration(milliseconds: 260),
            curve: ColectoMotion.easeOut,
          );
        }
      });
    }
  }

  void _back() => _go(_step == _Step.review ? _Step.servers : _Step.email);

  Future<void> _chooseCertificate() async {
    final file = await openFile(
      acceptedTypeGroups: const [
        XTypeGroup(label: 'Certificates', extensions: ['pem', 'crt', 'cer']),
      ],
    );
    if (file == null || !mounted) return;
    final text = await file.length() <= 16384 ? await file.readAsString() : '';
    if (!mounted) return;
    if (text.split('-----BEGIN CERTIFICATE-----').length != 2) {
      setState(
        () => _error =
            'Choose a PEM file with exactly one certificate (BEGIN '
            'CERTIFICATE), at most 16 KB.',
      );
      return;
    }
    setState(() {
      _certificate = text;
      _error = null;
    });
  }

  String get _passwordLabel =>
      _protocol == MailProtocol.jmap && _username.text.trim().isEmpty
      ? 'API token'
      : (_found?.appPassword ?? false)
      ? 'App password'
      : 'Password';

  @override
  Widget build(BuildContext context) {
    final steps = [_Step.email, _Step.servers, _Step.review];
    final masterReady =
        _master.text.length >= 12 && _masterConfirm.text.isNotEmpty;
    final primaryLabel = switch (_step) {
      _Step.email => _looking ? 'Looking up…' : 'Continue',
      _Step.servers => 'Continue',
      _Step.review =>
        _working
            ? 'Saving…'
            : _needsMaster
            ? 'Protect & save'
            : widget.submitLabel,
    };
    return FocusTraversalGroup(
      child: ColectoSheetFrame(
        title: widget.title,
        description: widget.description,
        onClose: _working ? null : widget.onClose,
        bodyController: _scroll,
        strip: ColectoSteps(
          labels: const ['Email', 'Servers', 'Review'],
          current: steps.indexOf(_step),
        ),
        body: AnimatedSwitcher(
          duration: ColectoMotion.of(
            context,
            const Duration(milliseconds: 200),
          ),
          switchInCurve: ColectoMotion.easeOut,
          transitionBuilder: (child, a) => FadeTransition(
            opacity: a,
            child: SlideTransition(
              position: Tween(
                begin: const Offset(0.02, 0),
                end: Offset.zero,
              ).animate(a),
              child: child,
            ),
          ),
          layoutBuilder: (current, previous) => Stack(
            alignment: Alignment.topLeft,
            children: [...previous, ?current],
          ),
          child: KeyedSubtree(
            key: ValueKey(_step),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ...switch (_step) {
                  _Step.email => _emailStep(context),
                  _Step.servers => _serversStep(context),
                  _Step.review => _reviewStep(context),
                },
                if (_error != null) ...[
                  const SizedBox(height: 16),
                  ColectoErrorBox(message: _error!),
                ],
              ],
            ),
          ),
        ),
        actions: [
          if (_step == _Step.email) ...[
            // Phones already have Cancel in the navigation bar.
            if (widget.onClose != null &&
                MediaQuery.sizeOf(context).width >= 600)
              ColectoButton(label: 'Cancel', onPressed: widget.onClose),
          ] else
            ColectoButton(label: 'Back', onPressed: _working ? null : _back),
          ColectoButton(
            label: primaryLabel,
            variant: ColectoButtonVariant.primary,
            onPressed:
                _looking ||
                    _working ||
                    (_step == _Step.review && _needsMaster && !masterReady)
                ? null
                : _submit,
          ),
        ],
      ),
    );
  }

  // ── Step 1: Email ──

  List<Widget> _emailStep(BuildContext context) {
    final p = ColectoPalette.of(context);
    final found = _lookup?.address == _current ? _lookup!.found : null;
    return [
      ColectoTextField(
        controller: _address,
        labelText: 'Email address',
        hintText: 'you@example.com',
        keyboardType: TextInputType.emailAddress,
        autofillHints: const [AutofillHints.email],
        textInputAction: TextInputAction.next,
        autofocus: true,
        readOnly: _looking,
        onChanged: (_) => setState(() => _error = null),
        onSubmitted: (_) => _submit(),
      ),
      const SizedBox(height: 14),
      if (_looking)
        Row(
          children: [
            SizedBox(
              width: 15,
              height: 15,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: p.accent,
                backgroundColor: p.line,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text.rich(
                TextSpan(
                  children: [
                    const TextSpan(text: 'Looking up settings for '),
                    TextSpan(
                      text: _domain,
                      style: kStyle(13.5, weight: 560, color: p.ink),
                    ),
                    const TextSpan(text: '…'),
                  ],
                ),
                style: kStyle(13.5, color: p.ink2),
              ),
            ),
            ColectoButton(
              label: 'Skip',
              variant: ColectoButtonVariant.text,
              onPressed: _manual,
            ),
          ],
        )
      else if (_limited && found != null)
        _Note(
          danger: true,
          icon: LucideIcons.triangleAlert,
          children: [
            Text.rich(
              TextSpan(
                children: found.limitation == 'oauth_only'
                    ? [
                        TextSpan(
                          text:
                              '${found.provider ?? 'This provider'} only '
                              'allows OAuth sign-in.',
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        const TextSpan(
                          text:
                              ' Colecto signs in with a password or app '
                              'password, and does not support OAuth yet.',
                        ),
                      ]
                    : [
                        TextSpan(
                          text:
                              '${found.provider ?? 'This provider'} has no '
                              'IMAP, SMTP or JMAP access',
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        const TextSpan(
                          text: ', so mail apps like Colecto cannot connect.',
                        ),
                      ],
              ),
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: ColectoButton(
                label: 'Enter settings anyway',
                variant: ColectoButtonVariant.text,
                onPressed: () => _go(_Step.servers),
              ),
            ),
          ],
        )
      else ...[
        const ColectoParagraph(
          'Colecto looks up your provider’s server settings from the '
          'address. For lesser-known domains, only the domain is sent to '
          'Thunderbird’s provider database.',
          small: true,
          tone: ColectoTone.muted,
        ),
        const SizedBox(height: 6),
        Align(
          alignment: Alignment.centerLeft,
          child: ColectoButton(
            label: 'Enter settings myself',
            variant: ColectoButtonVariant.text,
            onPressed: _manual,
          ),
        ),
      ],
    ];
  }

  // ── Step 2: Servers ──

  List<Widget> _serversStep(BuildContext context) {
    final found = _found;
    final showFound =
        found != null && (found.imap != null || found.jmap != null);
    final kept = _lookup?.kept ?? const [];
    final keptNames = {
      for (final f in kept)
        if (_fieldNames[f] != null) _fieldNames[f]!,
    }.toList();
    final imap = _protocol == MailProtocol.imap;
    return [
      if (showFound) ...[
        _Note(
          icon: LucideIcons.circleCheck,
          children: [
            Text(
              found.provider != null
                  ? 'Settings found for ${found.provider}'
                  : 'Settings found',
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            Text(
              '${_sourceSentence(found, _domain)} Check them before you '
              'continue.',
            ),
            if (found.limitation == 'bridge')
              Text(
                '${found.provider} works through Proton Mail Bridge. Start '
                'Bridge, then use the password and certificate it shows.',
              ),
            if (keptNames.isNotEmpty)
              Text('Your changes to the ${_list(keptNames)} were kept.'),
          ],
        ),
        const SizedBox(height: 18),
      ],
      const ColectoLabel('Protocol'),
      ColectoSegmented<MailProtocol>(
        value: _protocol,
        options: const [
          (MailProtocol.imap, 'IMAP + SMTP'),
          (MailProtocol.jmap, 'JMAP'),
        ],
        onChanged: (v) => setState(() {
          _protocol = v;
          _touch(_Field.protocol);
        }),
      ),
      if (imap) ...[
        _Block(
          icon: LucideIcons.inbox,
          title: 'Incoming mail',
          children: [
            ColectoTextField(
              controller: _imapHost,
              labelText: 'Incoming (IMAP) server',
              hintText: 'imap.example.com',
              keyboardType: TextInputType.url,
              onChanged: (_) => _touch(_Field.imapHost),
            ),
            const SizedBox(height: 12),
            _PortRow(
              label: 'IMAP port',
              value: _imapPort,
              presets: const [(993, 'TLS'), (143, 'STARTTLS')],
              onPort: (port) => setState(() {
                _imapPort = port;
                _touch(_Field.imapPort);
                if (port == 993 || port == 143) {
                  _imapStarttls = port == 143;
                  _touch(_Field.imapStarttls);
                }
              }),
              security: _imapStarttls,
              onSecurity: (starttls) => setState(() {
                _imapStarttls = starttls;
                if (starttls && _imapPort == 993) _imapPort = 143;
                if (!starttls && _imapPort == 143) _imapPort = 993;
                _touch(_Field.imapStarttls);
                _touch(_Field.imapPort);
              }),
            ),
          ],
        ),
        _Block(
          icon: LucideIcons.send,
          title: 'Outgoing mail',
          children: [
            ColectoTextField(
              controller: _smtpHost,
              labelText: 'Outgoing (SMTP) server',
              hintText: 'smtp.example.com',
              keyboardType: TextInputType.url,
              onChanged: (_) => _touch(_Field.smtpHost),
            ),
            const SizedBox(height: 12),
            // SMTP security follows the port: 465 starts with TLS, every
            // other port requires STARTTLS.
            _PortRow(
              label: 'SMTP port',
              value: _smtpPort,
              presets: const [
                (465, 'TLS'),
                (587, 'STARTTLS'),
                (25, 'STARTTLS'),
              ],
              onPort: (port) => setState(() {
                _smtpPort = port;
                _touch(_Field.smtpPort);
              }),
              security: _smtpPort != 465,
              onSecurity: (starttls) => setState(() {
                if (!starttls) {
                  _smtpPort = 465;
                } else if (_smtpPort == 465) {
                  _smtpPort = 587;
                }
                _touch(_Field.smtpPort);
              }),
            ),
          ],
        ),
      ] else
        _Block(
          icon: LucideIcons.server,
          title: 'JMAP server',
          children: [
            ColectoTextField(
              controller: _jmapHost,
              labelText: 'JMAP server or session URL',
              hintText: 'mail.example.com',
              keyboardType: TextInputType.url,
              onChanged: (_) => _touch(_Field.jmapHost),
            ),
            const SizedBox(height: 12),
            _PortRow(
              label: 'JMAP port',
              value: _jmapPort,
              presets: const [(443, 'HTTPS'), (8443, 'HTTPS')],
              onPort: (port) => setState(() {
                _jmapPort = port;
                _touch(_Field.jmapPort);
              }),
            ),
          ],
        ),
      _Block(
        icon: LucideIcons.keyRound,
        title: 'Sign in',
        children: [
          ColectoTextField(
            controller: _username,
            labelText: imap ? 'Username' : 'Username (optional)',
            autofillHints: const [AutofillHints.username],
            keyboardType: TextInputType.emailAddress,
            onChanged: (_) => setState(() => _touch(_Field.username)),
          ),
          const SizedBox(height: 12),
          ColectoTextField(
            controller: _secret,
            labelText: _passwordLabel,
            hintText: widget.account != null ? 'Unchanged' : null,
            obscureText: true,
            autofillHints: const [AutofillHints.password],
            onChanged: (_) => setState(() => _error = null),
            onSubmitted: (_) => _submit(),
          ),
          if (found?.appPassword == true && imap) ...[
            const SizedBox(height: 8),
            ColectoParagraph(
              '${found!.provider} needs an app password from its security '
              'settings, not your normal password.',
              small: true,
              tone: ColectoTone.muted,
            ),
          ],
          if (!imap) ...[
            const SizedBox(height: 8),
            const ColectoParagraph(
              'Leave the username empty to sign in with an API token '
              'instead of a password.',
              small: true,
              tone: ColectoTone.muted,
            ),
          ],
        ],
      ),
      if (imap)
        _Block(
          icon: LucideIcons.shield,
          title: 'Trusted certificate',
          children: [
            Wrap(
              spacing: 12,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: _certificate.isEmpty
                  ? [
                      ColectoButton(
                        label: 'Choose certificate…',
                        icon: LucideIcons.upload,
                        onPressed: _chooseCertificate,
                      ),
                    ]
                  : [
                      const ColectoText(
                        'Custom certificate in use',
                        role: ColectoTextRole.bodyStrong,
                      ),
                      ColectoButton(
                        label: 'Use system certificates',
                        variant: ColectoButtonVariant.text,
                        onPressed: () => setState(() => _certificate = ''),
                      ),
                    ],
            ),
            const SizedBox(height: 8),
            const ColectoParagraph(
              'For Proton Mail Bridge or a self-signed server. Both servers '
              'must present this certificate, and it replaces your system’s '
              'certificate authorities for this account.',
              small: true,
              tone: ColectoTone.muted,
            ),
          ],
        ),
    ];
  }

  // ── Step 3: Review ──

  List<Widget> _reviewStep(BuildContext context) {
    final p = ColectoPalette.of(context);
    final imap = _protocol == MailProtocol.imap;
    final w = _warnings();
    String security(bool starttls) => starttls ? 'STARTTLS' : 'TLS';
    final who = _name.text.trim().isEmpty ? _current : _name.text.trim();
    return [
      Row(
        children: [
          ColectoAvatar(name: who, hueKey: who, size: 38),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(_current, style: kStyle(15, weight: 600, color: p.ink)),
                ColectoText.caption(
                  imap ? 'IMAP and SMTP account' : 'JMAP account',
                ),
              ],
            ),
          ),
          ColectoButton(
            label: 'Change',
            variant: ColectoButtonVariant.text,
            onPressed: () => _go(_Step.email),
          ),
        ],
      ),
      const SizedBox(height: 16),
      Container(
        decoration: BoxDecoration(
          color: p.sunk,
          border: Border.all(color: p.line),
          borderRadius: BorderRadius.circular(colectoRadius(context) + 4),
        ),
        child: Column(
          children: [
            if (imap) ...[
              _ReviewItem(
                icon: LucideIcons.inbox,
                label: 'Receives mail from',
                value: _imapHost.text.trim(),
                meta: 'IMAP · port $_imapPort · ${security(_imapStarttls)}',
                warnings: w.imap,
                onChange: () => _go(_Step.servers),
                changeLabel: 'Change incoming server',
              ),
              _ReviewItem(
                icon: LucideIcons.send,
                label: 'Sends mail through',
                value: _smtpHost.text.trim(),
                meta: 'SMTP · port $_smtpPort · ${security(_smtpPort != 465)}',
                warnings: w.smtp,
                onChange: () => _go(_Step.servers),
                changeLabel: 'Change outgoing server',
                divided: true,
              ),
            ] else
              _ReviewItem(
                icon: LucideIcons.server,
                label: 'Connects to',
                value: _jmapSession(),
                meta: 'JMAP · port $_jmapPort',
                warnings: w.jmap,
                onChange: () => _go(_Step.servers),
                changeLabel: 'Change JMAP server',
              ),
            _ReviewItem(
              icon: LucideIcons.keyRound,
              label: 'Signs in as',
              value: _username.text.trim().isEmpty
                  ? 'API token (no username)'
                  : _username.text.trim(),
              meta: _secret.text.isNotEmpty
                  ? '$_passwordLabel entered'
                  : widget.account != null
                  ? 'Saved password unchanged'
                  : 'No password yet',
              onChange: () => _go(_Step.servers),
              changeLabel: 'Change sign-in details',
              divided: true,
            ),
            if (imap && _certificate.isNotEmpty)
              const _ReviewItem(
                icon: LucideIcons.shield,
                label: 'Trusts',
                value: 'A custom certificate',
                meta: 'Instead of your system’s certificate authorities',
                divided: true,
              ),
          ],
        ),
      ),
      const SizedBox(height: 18),
      ColectoTextField(
        controller: _name,
        labelText: 'Account name (optional)',
        hintText: 'Work, Personal…',
        onChanged: (_) => setState(() {}),
        onSubmitted: (_) => _submit(),
      ),
      const SizedBox(height: 10),
      const ColectoParagraph(
        'Saving does not test the connection; Colecto checks it in the '
        'background.',
        small: true,
        tone: ColectoTone.muted,
      ),
      if (_needsMaster) ...[
        const SizedBox(height: 16),
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: p.sunk,
            border: Border.all(color: p.line),
            borderRadius: BorderRadius.circular(colectoRadius(context) + 4),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Icon(LucideIcons.shield, size: 15, color: p.accent),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: ColectoText(
                      'Protect credentials with a master password',
                      role: ColectoTextRole.bodyStrong,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              const ColectoParagraph(
                'This device has no system credential store. Protects '
                'credentials only. Local emails and drafts remain '
                'unencrypted. A forgotten master password cannot be '
                'recovered.',
                small: true,
                tone: ColectoTone.secondary,
              ),
              const SizedBox(height: 12),
              ColectoTextField(
                controller: _master,
                labelText: 'Master password',
                obscureText: true,
                autofillHints: const [AutofillHints.newPassword],
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 12),
              ColectoTextField(
                controller: _masterConfirm,
                labelText: 'Confirm master password',
                obscureText: true,
                autofillHints: const [AutofillHints.newPassword],
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 6),
              Align(
                alignment: Alignment.centerLeft,
                child: ColectoButton(
                  label: 'Try system credential store again',
                  variant: ColectoButtonVariant.text,
                  onPressed: () => setState(() {
                    _needsMaster = false;
                    _master.clear();
                    _masterConfirm.clear();
                    _error = null;
                  }),
                ),
              ),
            ],
          ),
        ),
      ],
    ];
  }

  /// Likely mistakes worth a second look. They never block saving.
  ({List<String> imap, List<String> smtp, List<String> jmap}) _warnings() {
    final imap = <String>[], smtp = <String>[], jmap = <String>[];
    final imapHost = _imapHost.text.trim(), smtpHost = _smtpHost.text.trim();
    if (!_imapStarttls && _imapPort == 143) {
      imap.add('Port 143 normally uses STARTTLS, not TLS.');
    }
    if (_imapStarttls && _imapPort == 993) {
      imap.add('Port 993 normally uses TLS, not STARTTLS.');
    }
    if (RegExp(
      r'^(smtp|mail\.smtp|submission)\.',
      caseSensitive: false,
    ).hasMatch(imapHost)) {
      imap.add('This looks like an outgoing (SMTP) server.');
    }
    if (RegExp(r'^(imap|pop3?)\.', caseSensitive: false).hasMatch(smtpHost)) {
      smtp.add('This looks like an incoming server, not SMTP.');
    }
    if (_smtpPort == 25) {
      smtp.add(
        'Many networks block port 25 for apps. Providers usually offer 587 '
        'or 465.',
      );
    }
    if (_smtpPort == 993 || _smtpPort == 143) {
      smtp.add('Port $_smtpPort is an IMAP port.');
    }
    if (RegExp(r'^http://', caseSensitive: false).hasMatch(_jmapHost.text)) {
      jmap.add('Plain HTTP only works for a server on this device.');
    }
    return (imap: imap, smtp: smtp, jmap: jmap);
  }
}

const _fieldNames = {
  _Field.protocol: 'protocol',
  _Field.imapHost: 'incoming server',
  _Field.imapPort: 'incoming port',
  _Field.imapStarttls: 'incoming security',
  _Field.smtpHost: 'outgoing server',
  _Field.smtpPort: 'outgoing port',
  _Field.jmapHost: 'JMAP server',
  _Field.jmapPort: 'JMAP port',
};

String _list(List<String> items) => switch (items.length) {
  0 => '',
  1 => items.first,
  2 => '${items[0]} and ${items[1]}',
  _ => '${items.sublist(0, items.length - 1).join(', ')} and ${items.last}',
};

String _sourceSentence(DiscoveryResult found, String domain) {
  final names = [
    for (final s in found.sources)
      switch (s) {
        'provider_list' => 'Colecto’s built-in provider list',
        'autoconfig' => 'Thunderbird Autoconfig published by $domain',
        'ispdb' => 'Thunderbird’s provider database (ISPDB)',
        'srv' => 'DNS SRV records (RFC 6186)',
        'mx' => 'your domain’s MX record',
        'jmap_well_known' => 'JMAP discovery (RFC 8620)',
        _ => s,
      },
  ];
  return names.isEmpty ? '' : 'Filled in using ${_list(names)}.';
}

/// A JMAP URL as the form shows it: the host plus any path, and the port.
/// Plain HTTP keeps its scheme.
({String host, int port}) _splitJmap(String url) {
  if (url.isEmpty) return (host: '', port: 443);
  final u = Uri.tryParse(url);
  if (u == null || u.host.isEmpty) return (host: url, port: 443);
  final rest = (u.path == '/' || u.path.isEmpty) && !u.hasQuery
      ? ''
      : '${u.path}${u.hasQuery ? '?${u.query}' : ''}';
  final scheme = u.scheme == 'https' ? '' : '${u.scheme}://';
  return (host: '$scheme${u.host}$rest', port: u.port);
}

/// The session URL saved for a JMAP account; the chosen port replaces any
/// typed into the host box.
String _joinJmap(String host, int port) {
  final text = host.trim();
  if (text.isEmpty) return '';
  final http = RegExp(r'^http://', caseSensitive: false).hasMatch(text);
  final bare = text.replaceFirst(
    RegExp(r'^https?://', caseSensitive: false),
    '',
  );
  final u = Uri.tryParse('${http ? 'http' : 'https'}://$bare');
  if (u == null) return text;
  final out = u.replace(port: port).toString();
  return (u.path == '/' || u.path.isEmpty) && !u.hasQuery && out.endsWith('/')
      ? out.substring(0, out.length - 1)
      : out;
}

/// One server group on the Servers step: an icon heading and its fields,
/// ruled off from the group above.
class _Block extends StatelessWidget {
  const _Block({
    required this.icon,
    required this.title,
    required this.children,
  });

  final IconData icon;
  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final p = ColectoPalette.of(context);
    return Container(
      margin: const EdgeInsets.only(top: 18),
      padding: const EdgeInsets.only(top: 16),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: p.lineSoft)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(icon, size: 15, color: p.ink3),
              const SizedBox(width: 8),
              Flexible(
                child: ColectoText(title, role: ColectoTextRole.bodyStrong),
              ),
            ],
          ),
          const SizedBox(height: 12),
          ...children,
        ],
      ),
    );
  }
}

/// A port: the usual ones as choices, a box for any other, and (for IMAP
/// and SMTP) TLS or STARTTLS.
class _PortRow extends StatefulWidget {
  const _PortRow({
    required this.label,
    required this.value,
    required this.presets,
    required this.onPort,
    this.security,
    this.onSecurity,
  });

  final String label;
  final int value;
  final List<(int, String)> presets;
  final ValueChanged<int> onPort;

  /// Whether STARTTLS is on; null hides the security choice.
  final bool? security;
  final ValueChanged<bool>? onSecurity;

  @override
  State<_PortRow> createState() => _PortRowState();
}

class _PortRowState extends State<_PortRow> {
  late final _other = TextEditingController(text: _otherText);

  bool get _preset => widget.presets.any((e) => e.$1 == widget.value);
  String get _otherText => _preset ? '' : '${widget.value}';

  @override
  void didUpdateWidget(_PortRow old) {
    super.didUpdateWidget(old);
    final port = int.tryParse(_other.text);
    if (port != widget.value && _other.text != _otherText) {
      _other.text = _otherText;
    }
  }

  @override
  void dispose() {
    _other.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 16,
      runSpacing: 12,
      crossAxisAlignment: WrapCrossAlignment.end,
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            ColectoLabel(widget.label),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: ColectoSegmented<int>(
                    value: _preset ? widget.value : -1,
                    options: [
                      for (final (port, _) in widget.presets) (port, '$port'),
                    ],
                    onChanged: (port) {
                      _other.clear();
                      widget.onPort(port);
                    },
                  ),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  width: 86,
                  child: ColectoTextField(
                    controller: _other,
                    hintText: 'Other',
                    keyboardType: TextInputType.number,
                    onChanged: (text) {
                      final port = int.tryParse(text);
                      if (port != null && port >= 1 && port <= 65535) {
                        widget.onPort(port);
                      }
                    },
                  ),
                ),
              ],
            ),
          ],
        ),
        if (widget.security != null)
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              const ColectoLabel('Security'),
              ColectoSegmented<bool>(
                value: widget.security!,
                options: const [(false, 'TLS'), (true, 'STARTTLS')],
                onChanged: widget.onSecurity,
              ),
            ],
          ),
      ],
    );
  }
}

/// A tinted note: found settings (accent) or a provider limit (danger).
class _Note extends StatelessWidget {
  const _Note({
    required this.icon,
    required this.children,
    this.danger = false,
  });

  final IconData icon;
  final List<Widget> children;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final p = ColectoPalette.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
      decoration: BoxDecoration(
        color: danger ? p.dangerBg : p.select,
        borderRadius: BorderRadius.circular(colectoRadius(context) + 2),
      ),
      child: DefaultTextStyle.merge(
        style: kStyle(13, color: danger ? p.dangerInk : p.ink2, height: 1.5),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Icon(
                icon,
                size: 16,
                color: danger ? p.dangerInk : p.accent,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: children,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ReviewItem extends StatelessWidget {
  const _ReviewItem({
    required this.icon,
    required this.label,
    required this.value,
    required this.meta,
    this.warnings = const [],
    this.onChange,
    this.changeLabel,
    this.divided = false,
  });

  final IconData icon;
  final String label;
  final String value;
  final String meta;
  final List<String> warnings;
  final VoidCallback? onChange;
  final String? changeLabel;
  final bool divided;

  @override
  Widget build(BuildContext context) {
    final p = ColectoPalette.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
      decoration: divided
          ? BoxDecoration(
              border: Border(top: BorderSide(color: p.lineSoft)),
            )
          : null,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(icon, size: 16, color: p.ink3),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ColectoText.caption(label),
                const SizedBox(height: 2),
                Text(value, style: kStyle(14, weight: 560, color: p.ink)),
                const SizedBox(height: 2),
                Text(meta, style: kStyle(12.5, color: p.ink2)),
                for (final w in warnings)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Icon(
                            LucideIcons.triangleAlert,
                            size: 13,
                            color: p.star,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            w,
                            style: kStyle(12.5, color: p.star, height: 1.45),
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
          if (onChange != null)
            Semantics(
              label: changeLabel,
              child: ColectoButton(
                label: 'Change',
                variant: ColectoButtonVariant.text,
                onPressed: onChange,
              ),
            ),
        ],
      ),
    );
  }
}
