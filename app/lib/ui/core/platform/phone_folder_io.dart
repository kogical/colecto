import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// The folder phones save files to: Documents on iOS (shown in the Files
/// app), the app's Download folder on Android.
Future<String> phoneSaveFolder() async {
  final directory = Platform.isAndroid
      ? (await getDownloadsDirectory() ??
            await getApplicationDocumentsDirectory())
      : await getApplicationDocumentsDirectory();
  await directory.create(recursive: true);
  return directory.path;
}
