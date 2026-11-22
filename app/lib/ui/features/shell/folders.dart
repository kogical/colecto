import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:flutter/widgets.dart';

import '../../../domain/models/mail_models.dart';

IconData folderIcon(FolderRole role) => switch (role) {
  FolderRole.inbox => LucideIcons.inbox,
  FolderRole.sent => LucideIcons.send,
  FolderRole.drafts => LucideIcons.fileText,
  FolderRole.archive => LucideIcons.archive,
  FolderRole.trash => LucideIcons.trash2,
  FolderRole.junk => LucideIcons.octagonAlert,
  FolderRole.other => LucideIcons.folder,
};

/// Human-friendly folder label: normalizes IMAP's uppercase `INBOX` to `Inbox`.
String folderDisplayName(Folder folder) =>
    folder.name.toUpperCase() == 'INBOX' ? 'Inbox' : folder.name;

/// Counts cap at "999+" so badges never blow out.
String countLabel(int n) => n > 999 ? '999+' : '$n';

/// The folders Colecto shows as tabs: Inbox, Drafts and Sent. Every other
/// folder sits under More.
List<Folder> primaryFolders(List<Folder> folders) {
  Folder? byRole(FolderRole r) => folders.where((f) => f.role == r).firstOrNull;
  return [
    for (final r in const [
      FolderRole.inbox,
      FolderRole.drafts,
      FolderRole.sent,
    ])
      ?byRole(r),
  ];
}
