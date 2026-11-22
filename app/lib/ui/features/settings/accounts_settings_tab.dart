import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:material_ui/material_ui.dart';

import '../../../domain/models/account_models.dart';
import '../../../domain/models/preferences_models.dart';
import '../../core/kit/kit.dart';
import '../../core/theme/colecto_palette.dart';
import '../shell/mail_controller.dart';
import 'account_wizard.dart';

/// Settings → Accounts: the mail accounts with Add account (the three-step
/// wizard in a modal), then credential protection.
class AccountsSettingsTab extends StatefulWidget {
  const AccountsSettingsTab({super.key, required this.controller});

  final MailController controller;

  @override
  State<AccountsSettingsTab> createState() => _AccountsSettingsTabState();
}

class _AccountsSettingsTabState extends State<AccountsSettingsTab> {
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  String? _checking;
  bool _working = false;
  bool _changing = false;

  @override
  void dispose() {
    _password.dispose();
    _confirm.dispose();
    super.dispose();
  }

  MailController get c => widget.controller;

  /// The second line names what the first does not: the address under a
  /// name, otherwise the server.
  String _detail(AccountInfo a) {
    final s = a.settings;
    if (a.id == 'demo' || s == null) {
      return 'Sample mail, stored on this device';
    }
    if (s.name.trim().isNotEmpty) return s.address;
    if (s.protocol == MailProtocol.jmap) {
      return Uri.tryParse(s.sessionUrl)?.host ?? s.sessionUrl;
    }
    return s.imapHost;
  }

  ({String text, bool on, bool warn}) _status(AccountInfo a) {
    if (!c.preferences.accountEnabled(a.id)) {
      return (text: 'Off', on: false, warn: false);
    }
    if (a.id == 'demo') return (text: 'Sample', on: false, warn: false);
    if (c.security.locked) return (text: 'Locked', on: false, warn: true);
    if (!a.configured) return (text: 'Signed out', on: false, warn: true);
    return a.connected
        ? (text: 'Connected', on: true, warn: false)
        : (text: 'Not connected', on: false, warn: false);
  }

  Future<void> _reconnect(AccountInfo a) async {
    if (!a.configured) return showAccountWizard(context, c, account: a);
    setState(() => _checking = a.id);
    final ok = await c.reconnectAccount(a.id);
    if (!mounted) return;
    setState(() => _checking = null);
    if (ok) c.showToast('${a.displayName} is connected');
  }

  Future<void> _remove(AccountInfo a) async {
    final ok = await showColectoConfirm(
      context: context,
      title: 'Remove ${a.displayName}?',
      message:
          'Its saved password, cached mail and local drafts are deleted from '
          'this device. Nothing changes on the mail server.',
      confirmLabel: 'Remove account',
      danger: true,
    );
    if (ok) await c.removeAccount(a.id);
  }

  Future<void> _protect(String action) async {
    if (action == 'protect' && _password.text != _confirm.text) {
      c.showToast('Master passwords do not match', isError: true);
      return;
    }
    if (action == 'reset') {
      final ok = await showColectoConfirm(
        context: context,
        title: 'Forget all saved credentials?',
        message: 'You must reconnect every account. Local drafts will be kept.',
        confirmLabel: 'Reset credentials',
        danger: true,
      );
      if (!ok) return;
    }
    setState(() => _working = true);
    await c.runSecurityAction(action, password: _password.text);
    if (!mounted) return;
    _password.clear();
    _confirm.clear();
    setState(() {
      _working = false;
      _changing = false;
    });
    await c.reloadAccounts();
  }

  @override
  Widget build(BuildContext context) {
    final p = ColectoPalette.of(context);
    final sec = c.security;
    final locked = sec.locked;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const ColectoPageHead(
          title: 'Accounts & security',
          description:
              'Each account keeps its own mail and drafts. Credentials stay '
              'in your system’s credential store unless you protect them '
              'with a master password.',
        ),
        ColectoSection(
          title: 'Mail accounts',
          children: [
            for (var i = 0; i < c.accounts.length; i++)
              _row(context, c.accounts[i], index: i, total: c.accounts.length),
            const SizedBox(height: 10),
            Align(
              alignment: Alignment.centerLeft,
              child: ColectoButton(
                label: 'Add account',
                icon: LucideIcons.plus,
                onPressed: locked || _working
                    ? null
                    : () => showAccountWizard(context, c),
              ),
            ),
            if (locked) ...[
              const SizedBox(height: 8),
              const ColectoParagraph(
                'Unlock credentials below to add or change accounts.',
                small: true,
                tone: ColectoTone.muted,
              ),
            ],
          ],
        ),
        Container(
          height: 1,
          margin: const EdgeInsets.only(bottom: 26),
          color: p.lineSoft,
        ),
        ColectoSection(
          title: 'Credential protection',
          children: [
            ColectoText(
              sec.cleanupPending
                  ? 'Credential cleanup pending'
                  : sec.protected
                  ? (locked
                        ? 'Credentials locked'
                        : 'Password protection enabled')
                  : 'System credential store',
              role: ColectoTextRole.bodyStrong,
            ),
            const SizedBox(height: 6),
            const ColectoParagraph(
              'By default, passwords and tokens stay in your system '
              'credential store. Optionally protect them with a master '
              'password.',
              small: true,
              tone: ColectoTone.secondary,
            ),
            const SizedBox(height: 6),
            const ColectoParagraph(
              'Protects credentials only. Local emails and drafts remain '
              'unencrypted. A forgotten master password cannot be recovered.',
              small: true,
              tone: ColectoTone.muted,
            ),
            const SizedBox(height: 16),
            if (sec.cleanupPending) ...[
              const ColectoErrorBox(
                message:
                    'The new credential storage is saved, but the previous '
                    'system entry still needs removal. Unlock your system '
                    'keychain and retry.',
              ),
              const SizedBox(height: 10),
              Align(
                alignment: Alignment.centerLeft,
                child: ColectoButton(
                  label: 'Finish credential cleanup',
                  onPressed: _working ? null : () => _protect('cleanup'),
                ),
              ),
              const SizedBox(height: 16),
            ],
            if (!sec.protected || locked || _changing)
              ..._passwordForm(sec)
            else
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  ColectoButton(
                    label: 'Lock credentials',
                    icon: LucideIcons.lock,
                    onPressed: _working ? null : () => _protect('lock'),
                  ),
                  ColectoButton(
                    label: 'Change master password',
                    variant: ColectoButtonVariant.ghost,
                    onPressed: () => setState(() => _changing = true),
                  ),
                  ColectoButton(
                    label: 'Use system credential store',
                    variant: ColectoButtonVariant.text,
                    onPressed: _working ? null : () => _protect('unprotect'),
                  ),
                ],
              ),
            if (sec.protected) ...[
              const SizedBox(height: 18),
              const ColectoText(
                'Forgot your master password?',
                role: ColectoTextRole.label,
              ),
              const SizedBox(height: 4),
              const ColectoParagraph(
                'Reset saved credentials and reconnect your accounts. Local '
                'drafts will be kept.',
                small: true,
                tone: ColectoTone.muted,
              ),
              Align(
                alignment: Alignment.centerLeft,
                child: ColectoButton(
                  label: 'Reset saved credentials',
                  variant: ColectoButtonVariant.text,
                  onPressed: _working ? null : () => _protect('reset'),
                ),
              ),
            ],
          ],
        ),
      ],
    );
  }

  List<Widget> _passwordForm(SecurityInfo sec) {
    final unlocking = sec.locked;
    final ready = unlocking
        ? _password.text.isNotEmpty
        : _password.text.length >= 12 && _confirm.text.isNotEmpty;
    return [
      Align(
        alignment: Alignment.centerLeft,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 400),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ColectoTextField(
                controller: _password,
                labelText: _changing
                    ? 'New master password'
                    : 'Master password',
                obscureText: true,
                autofillHints: [
                  unlocking
                      ? AutofillHints.password
                      : AutofillHints.newPassword,
                ],
                helperText: unlocking ? null : 'At least 12 characters.',
                onChanged: (_) => setState(() {}),
                onSubmitted: unlocking ? (_) => _protect('unlock') : null,
              ),
              if (!unlocking) ...[
                const SizedBox(height: 12),
                ColectoTextField(
                  controller: _confirm,
                  labelText: _changing
                      ? 'Confirm new master password'
                      : 'Confirm master password',
                  obscureText: true,
                  autofillHints: const [AutofillHints.newPassword],
                  onChanged: (_) => setState(() {}),
                ),
              ],
            ],
          ),
        ),
      ),
      const SizedBox(height: 14),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          ColectoButton(
            label: _working
                ? 'Working…'
                : unlocking
                ? 'Unlock'
                : _changing
                ? 'Change password'
                : 'Enable password protection',
            variant: ColectoButtonVariant.primary,
            onPressed: !ready || _working
                ? null
                : () => _protect(unlocking ? 'unlock' : 'protect'),
          ),
          if (_changing)
            ColectoButton(
              label: 'Cancel',
              variant: ColectoButtonVariant.ghost,
              onPressed: () => setState(() {
                _changing = false;
                _password.clear();
                _confirm.clear();
              }),
            ),
        ],
      ),
    ];
  }

  Widget _row(
    BuildContext context,
    AccountInfo a, {
    required int index,
    required int total,
  }) {
    final p = ColectoPalette.of(context);
    final on = c.preferences.accountEnabled(a.id);
    final state = _status(a);
    final real = a.id != 'demo' && a.settings != null;
    final busy = _working || c.security.locked;
    final narrow = MediaQuery.sizeOf(context).width < 600;
    final canMoveUp = index > 0;
    final canMoveDown = index < total - 1;
    final actions = [
      if (canMoveUp)
        ColectoMenuItem(
          label: 'Move up',
          icon: LucideIcons.arrowUp,
          onSelected: () => c.reorderAccounts(index, index - 1),
        ),
      if (canMoveDown)
        ColectoMenuItem(
          label: 'Move down',
          icon: LucideIcons.arrowDown,
          onSelected: () => c.reorderAccounts(index, index + 2),
        ),
      if (real && (canMoveUp || canMoveDown)) const ColectoMenuItem.divider(),
      if (real) ...[
        ColectoMenuItem(
          label: a.configured ? 'Reconnect' : 'Sign in again',
          icon: LucideIcons.refreshCw,
          onSelected: () => _reconnect(a),
        ),
        ColectoMenuItem(
          label: 'Edit',
          icon: LucideIcons.pencil,
          onSelected: () => showAccountWizard(context, c, account: a),
        ),
        const ColectoMenuItem.divider(),
        ColectoMenuItem(
          label: 'Remove…',
          icon: LucideIcons.trash2,
          danger: true,
          onSelected: () => _remove(a),
        ),
      ],
    ];
    return AnimatedOpacity(
      duration: ColectoMotion.hover,
      opacity: on ? 1 : 0.6,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          children: [
            ColectoAvatar(name: a.displayName, hueKey: a.displayName, size: 32),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: ColectoText(
                          a.displayName,
                          role: ColectoTextRole.bodyStrong,
                          maxLines: 1,
                        ),
                      ),
                      if (real) ...[
                        const SizedBox(width: 8),
                        ColectoBadge(
                          text: a.settings!.protocol == MailProtocol.jmap
                              ? 'JMAP'
                              : 'IMAP',
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      ColectoStatusDot(on: state.on),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text.rich(
                          TextSpan(
                            children: [
                              TextSpan(
                                text: state.text,
                                style: TextStyle(
                                  color: state.warn ? p.star : null,
                                ),
                              ),
                              TextSpan(text: '  ·  ${_detail(a)}'),
                            ],
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: colectoType(
                            context,
                            ColectoTextRole.caption,
                          ).copyWith(color: p.ink3),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            if (!narrow && total > 1) ...[
              ColectoIconButton(
                icon: LucideIcons.chevronUp,
                tooltip: 'Move ${a.displayName} up',
                onPressed: _working || !canMoveUp
                    ? null
                    : () => c.reorderAccounts(index, index - 1),
              ),
              ColectoIconButton(
                icon: LucideIcons.chevronDown,
                tooltip: 'Move ${a.displayName} down',
                onPressed: _working || !canMoveDown
                    ? null
                    : () => c.reorderAccounts(index, index + 2),
              ),
            ],
            if (real && !narrow) ...[
              ColectoIconButton(
                icon: _checking == a.id
                    ? LucideIcons.loaderCircle
                    : LucideIcons.refreshCw,
                tooltip: a.configured ? 'Reconnect' : 'Sign in again',
                onPressed: busy || _checking != null
                    ? null
                    : () => _reconnect(a),
              ),
              ColectoIconButton(
                icon: LucideIcons.pencil,
                tooltip: 'Edit',
                onPressed: busy
                    ? null
                    : () => showAccountWizard(context, c, account: a),
              ),
              ColectoIconButton(
                icon: LucideIcons.trash2,
                tooltip: 'Remove',
                danger: true,
                onPressed: busy ? null : () => _remove(a),
              ),
              const SizedBox(width: 6),
            ] else if (actions.isNotEmpty)
              Builder(
                builder: (ctx) => ColectoIconButton(
                  icon: LucideIcons.ellipsis,
                  tooltip: 'More',
                  onPressed: busy
                      ? null
                      : () {
                          if (colectoTouch(ctx)) {
                            showColectoModalPicker(
                              context: ctx,
                              title: a.displayName,
                              items: actions,
                            );
                          } else {
                            showColectoMenu(
                              context: ctx,
                              anchor: colectoRectOf(ctx),
                              items: actions,
                              alignRight: true,
                            );
                          }
                        },
                ),
              ),
            ColectoSwitch(
              value: on,
              semanticLabel: 'Use ${a.displayName}',
              onChanged: _working
                  ? null
                  : (v) => c.updatePreferences(
                      PreferencesPatch(accountsEnabled: {a.id: v}),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
