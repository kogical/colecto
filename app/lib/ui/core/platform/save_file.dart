import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';

import 'phone_folder_stub.dart' if (dart.library.io) 'phone_folder_io.dart';

/// Saves bytes where the platform expects them: a browser download on the
/// web, a native Save dialog on desktop, and on phones the app's own folder
/// (Files → On My iPhone → Colecto, or Android/data/…/Download). Returns
/// where the file went, or null when the person cancels.
Future<String?> saveBytesTo({
  required String name,
  required String contentType,
  required Uint8List bytes,
}) async {
  final file = XFile.fromData(bytes, name: name, mimeType: contentType);
  if (kIsWeb) {
    await file.saveTo(name);
    return name;
  }
  if (defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS) {
    final path = '${await phoneSaveFolder()}/$name';
    await file.saveTo(path);
    return path;
  }
  final location = await getSaveLocation(suggestedName: name);
  if (location == null) return null;
  await file.saveTo(location.path);
  return location.path;
}

/// [saveBytesTo], reporting only whether the file was saved.
Future<bool> saveBytes({
  required String name,
  required String contentType,
  required Uint8List bytes,
}) async =>
    await saveBytesTo(name: name, contentType: contentType, bytes: bytes) !=
    null;
