import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/kit/kit.dart';
import '../../core/platform/save_file.dart';
import '../shell/mail_controller.dart';

/// Settings → Backup: export a zip of accounts, drafts, labels and settings,
/// optionally locked with a passphrase, and restore one made here, in the
/// app on another device, or by `colecto-daemon`.
class BackupSettingsTab extends StatefulWidget {
  const BackupSettingsTab({super.key, required this.controller});

  final MailController controller;

  @override
  State<BackupSettingsTab> createState() => _BackupSettingsTabState();
}

class _BackupSettingsTabState extends State<BackupSettingsTab> {
  final _passphrase = TextEditingController();
  final _confirm = TextEditingController();
  bool _lock = true;
  bool _exporting = false;
  String? _exportError;
  String? _savedTo;

  MailController get c => widget.controller;

  @override
  void dispose() {
    _passphrase.dispose();
    _confirm.dispose();
    super.dispose();
  }

  String? get _passphraseProblem {
    if (!_lock) return null;
    if (_passphrase.text.characters.length < 8) {
      return 'Use a passphrase of at least 8 characters.';
    }
    if (_passphrase.text != _confirm.text) {
      return 'The passphrases do not match.';
    }
    return null;
  }

  Future<void> _export() async {
    final problem = _passphraseProblem;
    if (problem != null) return setState(() => _exportError = problem);
    setState(() {
      _exporting = true;
      _exportError = null;
      _savedTo = null;
    });
    String? failure;
    final file = await c.exportBackup(
      passphrase: _lock ? _passphrase.text : '',
      onError: (m) => failure = m,
    );
    String? path;
    if (file != null) {
      try {
        path = await saveBytesTo(
          name: file.filename,
          contentType: 'application/zip',
          bytes: file.bytes,
        );
      } catch (e) {
        failure = 'Could not save the backup: $e';
      }
    }
    if (!mounted) return;
    setState(() {
      _exporting = false;
      _exportError = failure;
      _savedTo = path;
      if (path != null) {
        _passphrase.clear();
        _confirm.clear();
      }
    });
  }

  Future<void> _chooseBackup() async {
    final file = await openFile(
      acceptedTypeGroups: const [
        XTypeGroup(label: 'Colecto backups', extensions: ['zip']),
      ],
    );
    if (file == null || !mounted) return;
    final bytes = await file.readAsBytes();
    if (!mounted) return;
    final phone = MediaQuery.sizeOf(context).width < 600;
    await Navigator.of(context).push(
      colectoModalRoute(
        context,
        fullscreen: phone,
        fitContent: true,
        maxSize: const Size(520, 560),
        builder: (ctx) => _RestoreSheet(
          controller: c,
          name: file.name,
          bytes: bytes,
          onClose: () => Navigator.of(ctx).maybePop(),
          onRestored: () => Navigator.of(ctx).pop(),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final mono = colectoType(
      context,
      ColectoTextRole.caption,
    ).copyWith(fontFamily: 'monospace');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const ColectoPageHead(
          title: 'Backup',
          description:
              'Move your accounts, drafts, labels and settings between this '
              'app and a Colecto daemon, or keep a copy somewhere safe. '
              'Message lists and downloaded mail are not included; they come '
              'back from your mail servers.',
        ),
        ColectoSection(
          title: 'Export a backup',
          description:
              'A zip file with your accounts, drafts, labels, settings, API '
              'keys and AI settings.',
          children: [
            ColectoSettingRow(
              title: 'Lock with a passphrase',
              description: _lock
                  ? 'The backup is encrypted and includes your saved '
                        'passwords, so accounts reconnect right away. You '
                        'need the passphrase to restore it; it cannot be '
                        'recovered.'
                  : 'Saved passwords are left out, and restored accounts '
                        'ask you to sign in again.',
              trailing: ColectoSwitch(
                value: _lock,
                onChanged: (v) => setState(() {
                  _lock = v;
                  _exportError = null;
                }),
              ),
            ),
            if (_lock) ...[
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 400),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      ColectoTextField(
                        controller: _passphrase,
                        labelText: 'Backup passphrase',
                        helperText: 'At least 8 characters.',
                        obscureText: true,
                        autofillHints: const [AutofillHints.newPassword],
                        onChanged: (_) => setState(() => _exportError = null),
                      ),
                      const SizedBox(height: 12),
                      ColectoTextField(
                        controller: _confirm,
                        labelText: 'Confirm passphrase',
                        obscureText: true,
                        autofillHints: const [AutofillHints.newPassword],
                        onChanged: (_) => setState(() => _exportError = null),
                        onSubmitted: (_) => _export(),
                      ),
                    ],
                  ),
                ),
              ),
            ],
            if (_exportError != null) ...[
              const SizedBox(height: 14),
              ColectoErrorBox(message: _exportError!),
            ],
            if (_savedTo != null) ...[
              const SizedBox(height: 14),
              ColectoNotice(
                icon: LucideIcons.circleCheck,
                child: Text('Backup saved to $_savedTo'),
              ),
            ],
            const SizedBox(height: 16),
            Align(
              alignment: Alignment.centerLeft,
              child: ColectoButton(
                label: _exporting ? 'Exporting…' : 'Export backup…',
                icon: LucideIcons.download,
                variant: ColectoButtonVariant.primary,
                onPressed: _exporting ? null : _export,
              ),
            ),
          ],
        ),
        ColectoSection(
          title: 'Restore a backup',
          description:
              'Replaces the accounts, drafts, labels and settings here with '
              'the backup’s. Backups from the Colecto app on any device and '
              'from colecto-daemon work the same way.',
          children: [
            Align(
              alignment: Alignment.centerLeft,
              child: ColectoButton(
                label: 'Choose backup…',
                icon: LucideIcons.upload,
                onPressed: _chooseBackup,
              ),
            ),
            const SizedBox(height: 16),
            const ColectoText('On a daemon', role: ColectoTextRole.label),
            const SizedBox(height: 4),
            const ColectoParagraph(
              'Stop it, then run one of these. COLECTO_BACKUP_PASSPHRASE '
              'locks a new backup or opens a locked one.',
              small: true,
              tone: ColectoTone.muted,
            ),
            const SizedBox(height: 6),
            SelectableText(
              'colecto-daemon export backup.zip\n'
              'colecto-daemon import backup.zip',
              style: mono,
            ),
          ],
        ),
      ],
    );
  }
}

/// Confirms a restore and asks for the passphrase of a locked backup.
class _RestoreSheet extends StatefulWidget {
  const _RestoreSheet({
    required this.controller,
    required this.name,
    required this.bytes,
    required this.onClose,
    required this.onRestored,
  });

  final MailController controller;
  final String name;
  final Uint8List bytes;
  final VoidCallback onClose;
  final VoidCallback onRestored;

  @override
  State<_RestoreSheet> createState() => _RestoreSheetState();
}

class _RestoreSheetState extends State<_RestoreSheet> {
  final _passphrase = TextEditingController();
  final _focus = FocusNode();
  bool _working = false;
  String? _error;

  @override
  void dispose() {
    _passphrase.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _restore() async {
    setState(() {
      _working = true;
      _error = null;
    });
    String? failure;
    final ok = await widget.controller.importBackup(
      widget.bytes,
      passphrase: _passphrase.text,
      onError: (m) => failure = m,
    );
    if (!mounted) return;
    if (ok) return widget.onRestored();
    setState(() {
      _working = false;
      _error = failure;
    });
    if (failure?.contains('passphrase') ?? false) _focus.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    return ColectoSheetFrame(
      title: 'Restore backup',
      description: widget.name,
      onClose: _working ? null : widget.onClose,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const ColectoNotice(
            icon: LucideIcons.triangleAlert,
            child: Text(
              'Your accounts, drafts, labels and settings here are replaced '
              'by the backup’s. Mail on your servers is not touched.',
            ),
          ),
          const SizedBox(height: 16),
          ColectoTextField(
            controller: _passphrase,
            focusNode: _focus,
            labelText: 'Backup passphrase',
            helperText: 'Only for a backup locked with one.',
            obscureText: true,
            onSubmitted: (_) => _working ? null : _restore(),
          ),
          if (_error != null) ...[
            const SizedBox(height: 14),
            ColectoErrorBox(message: _error!),
          ],
        ],
      ),
      actions: [
        if (MediaQuery.sizeOf(context).width >= 600)
          ColectoButton(
            label: 'Cancel',
            onPressed: _working ? null : widget.onClose,
          ),
        ColectoButton(
          label: _working ? 'Restoring…' : 'Replace with backup',
          variant: ColectoButtonVariant.danger,
          onPressed: _working ? null : _restore,
        ),
      ],
    );
  }
}
