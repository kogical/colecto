/// Builds the complete HTML5 document loaded into a sandboxed email viewer
/// (Web `<iframe sandbox>`, Linux WebKitGTK 4.1, and Win/macOS/Android/iOS
/// `InAppWebView`).
///
/// The sanitized email markup (which may begin with a Rust-sanitized `<style>`
/// block) is placed after Colecto's base stylesheet so the email's own safe
/// layout rules win while plain/minimal HTML inherits Colecto's palette.
String buildSandboxedEmailDocument(
  String sanitizedHtml, {
  required bool designed,
  required String ink,
  required String link,
  String bg = 'transparent',
}) =>
    '''
<!doctype html>
<html>
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<base target="_blank">
<style>
  html { color-scheme: ${designed ? 'light' : 'dark light'}; }
  body {
    margin: 0;
    padding: ${designed ? '16px' : '2px 0 24px'};
    font: 15px/1.6 system-ui, -apple-system, "Segoe UI", Roboto, sans-serif;
    color: ${designed ? '#111111' : ink};
    background: ${designed ? '#ffffff' : bg};
    overflow-wrap: break-word;
  }
  a { color: ${designed ? '#0b57d0' : link}; text-underline-offset: 3px; }
  img { max-width: 100%; height: auto; }
  table { max-width: 100%; }
  blockquote { margin: 8px 0 8px 4px; padding-left: 12px; border-left: 2px solid rgba(127,127,127,.35); }
  pre, code { font: 13px/1.5 ui-monospace, "SF Mono", monospace; white-space: pre-wrap; }
</style>
</head>
<body>$sanitizedHtml</body>
</html>
''';
