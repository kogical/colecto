import 'dart:io';

List<String>? _cached;

/// Discovers installed system font families on desktop platforms, cached for
/// the session. Returns an empty list on mobile or if enumeration fails.
Future<List<String>> listSystemFonts() async {
  if (_cached != null) return _cached!;
  final found = <String>{};
  try {
    if (Platform.isLinux) {
      final res = await Process.run('fc-list', [':', 'family']);
      if (res.exitCode == 0) {
        for (final line in (res.stdout as String).split('\n')) {
          final first = line.split(',').first.trim();
          if (first.isNotEmpty && !first.startsWith('.')) {
            found.add(first.replaceAll(r'\-', '-'));
          }
        }
      }
    } else if (Platform.isMacOS) {
      for (final dir in [
        '/System/Library/Fonts',
        '/System/Library/Fonts/Supplemental',
        '/Library/Fonts',
        if (Platform.environment['HOME'] case final home?)
          '$home/Library/Fonts',
      ]) {
        _scanFontDir(dir, found);
      }
    } else if (Platform.isWindows) {
      final root = Platform.environment['WINDIR'] ?? r'C:\Windows';
      _scanFontDir('$root\\Fonts', found);
    }
  } catch (_) {}

  // Exclude bundled fonts (shown in their own section) and emoji/symbol-only
  // families that aren't suitable as an interface typeface.
  found.removeWhere(
    (f) =>
        f.toLowerCase() == 'mona sans' ||
        f.toLowerCase().contains('emoji') ||
        f.toLowerCase().contains('dingbat') ||
        f.toLowerCase().contains('symbol'),
  );
  final sorted = found.toList()
    ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
  _cached = List.unmodifiable(sorted);
  return _cached!;
}

void _scanFontDir(String path, Set<String> out) {
  final dir = Directory(path);
  if (!dir.existsSync()) return;
  for (final entity in dir.listSync(followLinks: false)) {
    if (entity is! File) continue;
    final name = entity.uri.pathSegments.last;
    final lower = name.toLowerCase();
    if (!lower.endsWith('.ttf') &&
        !lower.endsWith('.otf') &&
        !lower.endsWith('.ttc')) {
      continue;
    }
    var base = name.substring(0, name.lastIndexOf('.'));
    if (base.startsWith('.')) continue;
    // Strip common weight/style suffixes so families group cleanly.
    base = base.replaceFirst(
      RegExp(
        r'[-_ ]?(Regular|Bold|Italic|Light|Medium|SemiBold|Thin|Black|Heavy|Oblique|Condensed|Variable|VF).*$',
        caseSensitive: false,
      ),
      '',
    );
    base = base.replaceAll(RegExp(r'[-_]+'), ' ').trim();
    if (base.isNotEmpty) out.add(base);
  }
}
