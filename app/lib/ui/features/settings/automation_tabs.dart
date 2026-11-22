import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:material_ui/material_ui.dart';

import '../../../domain/models/automation_models.dart';
import '../../../domain/models/preferences_models.dart';
import '../../core/kit/kit.dart';
import '../../core/theme/colecto_palette.dart';
import '../shell/mail_controller.dart';

class ApiKeysSettingsTab extends StatefulWidget {
  const ApiKeysSettingsTab({super.key, required this.controller});

  final MailController controller;

  @override
  State<ApiKeysSettingsTab> createState() => _ApiKeysSettingsTabState();
}

class _ApiKeysSettingsTabState extends State<ApiKeysSettingsTab> {
  final _nameCtrl = TextEditingController();
  final Set<String> _accounts = {};
  final Set<MailCapability> _caps = {};

  /// Days until the new key expires; 0 never expires.
  int _expiry = 0;
  String? _secret;

  static const _readOnly = {
    MailCapability.accountRead,
    MailCapability.messagesList,
    MailCapability.messagesRead,
    MailCapability.draftsList,
    MailCapability.draftsRead,
  };

  static const _lifetimes = [
    (0, 'Never'),
    (1, '1 day'),
    (7, '1 week'),
    (30, '30 days'),
    (90, '90 days'),
  ];

  MailController get c => widget.controller;

  @override
  void dispose() {
    _nameCtrl.dispose();
    super.dispose();
  }

  bool get _ready =>
      _nameCtrl.text.trim().isNotEmpty &&
      _accounts.isNotEmpty &&
      _caps.isNotEmpty;

  Future<void> _mint() async {
    final minted = await c.mintApiKey(
      ApiKeyInput(
        name: _nameCtrl.text.trim(),
        accounts: _accounts.toList(),
        capabilities: _caps.toList(),
        expiresAt: _expiry == 0
            ? null
            : DateTime.now().millisecondsSinceEpoch ~/ 1000 + _expiry * 86400,
      ),
    );
    if (mounted && minted != null) {
      _nameCtrl.clear();
      setState(() {
        _secret = minted.secret;
        _accounts.clear();
        _caps.clear();
        _expiry = 0;
      });
    }
  }

  Future<void> _revoke(ApiKeyMetadata key) async {
    final ok = await showColectoConfirm(
      context: context,
      title: 'Revoke “${key.name}”?',
      message: 'Anything using this key loses access immediately.',
      confirmLabel: 'Revoke key',
      danger: true,
    );
    if (ok) await c.revokeApiKey(key.id);
  }

  String _date(int? seconds) => seconds == null
      ? 'Never'
      : MaterialLocalizations.of(
          context,
        ).formatMediumDate(DateTime.fromMillisecondsSinceEpoch(seconds * 1000));

  String _accountName(String id) =>
      c.accounts.where((a) => a.id == id).firstOrNull?.displayName ?? id;

  @override
  Widget build(BuildContext context) {
    final p = ColectoPalette.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const ColectoPageHead(
          title: 'API keys',
          description:
              'Give automation access to selected accounts and operations. '
              'Keys can change only the settings areas you grant them, never '
              'credentials, connections or keys, and sending only asks you '
              'for approval; it never sends directly.',
        ),
        ColectoSection(
          children: [
            ColectoSettingRow(
              title: 'MCP server',
              description:
                  'Lets MCP clients use a key below at /api/v1/mcp and '
                  'through colecto-mcp. Off until you turn it on; keys keep '
                  'working over HTTP either way.',
              trailing: ColectoSwitch(
                value: c.preferences.mcp,
                onChanged: (v) => c.updatePreferences(PreferencesPatch(mcp: v)),
              ),
            ),
          ],
        ),
        if (_secret != null)
          Container(
            margin: const EdgeInsets.only(bottom: 30),
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: p.select,
              borderRadius: BorderRadius.circular(colectoRadius(context) + 4),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Copy your key now',
                  style: kStyle(15, weight: 640, color: p.accentHi),
                ),
                const SizedBox(height: 4),
                const ColectoParagraph(
                  'This secret is shown only here, until you leave or '
                  'dismiss it.',
                  small: true,
                  tone: ColectoTone.secondary,
                ),
                const SizedBox(height: 10),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: p.sunk,
                    border: Border.all(color: p.line),
                    borderRadius: BorderRadius.circular(colectoRadius(context)),
                  ),
                  child: SelectableText(
                    _secret!,
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 13,
                      height: 1.5,
                      color: p.ink,
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 12,
                  runSpacing: 8,
                  children: [
                    ColectoButton(
                      label: 'Copy key',
                      icon: LucideIcons.copy,
                      onPressed: () {
                        Clipboard.setData(ClipboardData(text: _secret!));
                      },
                    ),
                    ColectoButton(
                      label: 'Dismiss secret',
                      variant: ColectoButtonVariant.text,
                      onPressed: () => setState(() => _secret = null),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ColectoSection(
          title: 'New key',
          description:
              'Choose what the key may reach. You see its secret once, right '
              'after it is made.',
          children: [
            Align(
              alignment: Alignment.centerLeft,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 400),
                child: ColectoTextField(
                  controller: _nameCtrl,
                  labelText: 'Key name',
                  hintText: 'Desktop assistant',
                  onChanged: (_) => setState(() {}),
                ),
              ),
            ),
            const SizedBox(height: 16),
            const ColectoLabel('Accounts'),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final acc in c.accounts)
                  ColectoChip(
                    label: acc.displayName,
                    showCheck: true,
                    selected: _accounts.contains(acc.id),
                    onTap: () => setState(() {
                      if (!_accounts.remove(acc.id)) _accounts.add(acc.id);
                    }),
                  ),
              ],
            ),
            const SizedBox(height: 16),
            Row(children: [const Expanded(child: ColectoLabel('Operations'))]),
            Wrap(
              spacing: 14,
              children: [
                ColectoButton(
                  label: 'Read only',
                  variant: ColectoButtonVariant.text,
                  onPressed: () => setState(
                    () => _caps
                      ..clear()
                      ..addAll(_readOnly),
                  ),
                ),
                ColectoButton(
                  label: 'Everything',
                  variant: ColectoButtonVariant.text,
                  onPressed: () => setState(
                    () => _caps
                      ..clear()
                      ..addAll(MailCapability.values),
                  ),
                ),
                if (_caps.isNotEmpty)
                  ColectoButton(
                    label: 'Clear',
                    variant: ColectoButtonVariant.text,
                    onPressed: () => setState(_caps.clear),
                  ),
              ],
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final cap in MailCapability.values)
                  Tooltip(
                    message: cap.wire,
                    child: ColectoChip(
                      label: cap.label,
                      showCheck: true,
                      selected: _caps.contains(cap),
                      onTap: () => setState(() {
                        if (!_caps.remove(cap)) _caps.add(cap);
                      }),
                    ),
                  ),
              ],
            ),
            if (_caps.contains(MailCapability.messagesSend)) ...[
              const SizedBox(height: 8),
              const ColectoParagraph(
                'Sending always waits for your approval in Settings → Send '
                'approvals.',
                small: true,
                tone: ColectoTone.muted,
              ),
            ],
            const SizedBox(height: 16),
            const ColectoLabel('Expires'),
            ColectoSegmented<int>(
              value: _expiry,
              options: _lifetimes,
              onChanged: (v) => setState(() => _expiry = v),
            ),
            const SizedBox(height: 20),
            Align(
              alignment: Alignment.centerLeft,
              child: ColectoButton(
                label: 'Generate API key',
                variant: ColectoButtonVariant.primary,
                onPressed: _ready ? _mint : null,
              ),
            ),
          ],
        ),
        ColectoSection(
          title: 'Issued keys',
          children: [
            if (c.apiKeys.isEmpty)
              const ColectoParagraph(
                'No API keys yet. Your mail is keeping to itself.',
                tone: ColectoTone.muted,
              )
            else
              for (final key in c.apiKeys)
                Container(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  decoration: BoxDecoration(
                    border: Border(top: BorderSide(color: p.lineSoft)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: ColectoText(
                              key.name,
                              role: ColectoTextRole.bodyStrong,
                              maxLines: 1,
                            ),
                          ),
                          if (key.isRevoked) ...[
                            const SizedBox(width: 8),
                            const ColectoBadge(text: 'Revoked', danger: true),
                          ],
                        ],
                      ),
                      const SizedBox(height: 4),
                      ColectoParagraph(
                        key.accounts.map(_accountName).join(', '),
                        small: true,
                        tone: ColectoTone.secondary,
                      ),
                      const SizedBox(height: 6),
                      Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: [
                          for (final cap in key.capabilities)
                            Tooltip(
                              message: cap.label,
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 7,
                                  vertical: 2,
                                ),
                                decoration: BoxDecoration(
                                  color: p.sunk,
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: Text(
                                  cap.wire,
                                  style: TextStyle(
                                    fontFamily: 'monospace',
                                    fontSize: 12,
                                    color: p.ink2,
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      ColectoText.caption(
                        'Created ${_date(key.createdAt)} · Last used '
                        '${_date(key.lastUsedAt)} · Expires '
                        '${_date(key.expiresAt)}'
                        '${key.revokedAt != null ? ' · Revoked ${_date(key.revokedAt)}' : ''}',
                      ),
                      if (!key.isRevoked) ...[
                        const SizedBox(height: 8),
                        ColectoButton(
                          label: 'Revoke key',
                          compact: true,
                          onPressed: () => _revoke(key),
                        ),
                      ],
                    ],
                  ),
                ),
          ],
        ),
      ],
    );
  }
}

class SendApprovalsSettingsTab extends StatelessWidget {
  const SendApprovalsSettingsTab({super.key, required this.controller});

  final MailController controller;

  @override
  Widget build(BuildContext context) {
    final p = ColectoPalette.of(context);
    final requests = controller.sendRequests;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ColectoPageHead(
          title: 'Send approvals',
          description:
              'Automation cannot send until you approve the exact message '
              'below. Requests expire after 10 minutes, and any change needs '
              'a new request.',
          action: ColectoButton(
            label: 'Refresh',
            icon: LucideIcons.refreshCw,
            onPressed: controller.loadSendRequests,
          ),
        ),
        if (requests.isEmpty)
          const ColectoSection(
            children: [
              ColectoParagraph(
                'Nothing waiting for you. Automation is behaving.',
                tone: ColectoTone.muted,
              ),
            ],
          )
        else
          for (final req in requests)
            ColectoSection(
              title: req.snapshot?.subject.isNotEmpty == true
                  ? req.snapshot!.subject
                  : '(No subject)',
              description:
                  '${req.requester} wants to send from ${req.from}'
                  '${req.snapshot != null ? ' to ${req.snapshot!.recipient}' : ''}.',
              trailing: ColectoBadge(
                text: switch (req.status) {
                  ApprovalStatus.pending => 'Waiting',
                  ApprovalStatus.sent => 'Sent',
                  ApprovalStatus.rejected => 'Rejected',
                  _ => req.status.name,
                },
                accent:
                    req.status == ApprovalStatus.pending ||
                    req.status == ApprovalStatus.sent,
                danger:
                    req.status == ApprovalStatus.rejected ||
                    req.status == ApprovalStatus.uncertain,
              ),
              children: [
                if (req.snapshot != null)
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: p.sunk,
                      borderRadius: BorderRadius.circular(
                        colectoRadius(context),
                      ),
                      border: Border.all(color: p.lineSoft),
                    ),
                    child: SelectableText(
                      req.snapshot!.body,
                      style: colectoType(context, ColectoTextRole.body),
                    ),
                  ),
                if (req.status == ApprovalStatus.pending) ...[
                  const SizedBox(height: 14),
                  Wrap(
                    spacing: 8,
                    children: [
                      ColectoButton(
                        label: 'Approve and send',
                        icon: LucideIcons.send,
                        variant: ColectoButtonVariant.primary,
                        onPressed: () =>
                            controller.decideSendRequest(req.id, approve: true),
                      ),
                      ColectoButton(
                        label: 'Reject',
                        variant: ColectoButtonVariant.danger,
                        onPressed: () => controller.decideSendRequest(
                          req.id,
                          approve: false,
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
      ],
    );
  }
}
