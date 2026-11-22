import 'package:flutter/widgets.dart';

/// Non-IO stub for native platform WebView rendering (used on Web, where
/// `html_message_iframe_web.dart` renders a real `<iframe sandbox>` instead).
Widget? buildPlatformSandboxedWebView({
  required String sanitizedHtml,
  required bool designed,
  required String ink,
  required String link,
  required String bg,
  required double height,
  required Widget fallback,
  bool allowRemoteContent = false,
  ValueChanged<String>? onOpenUrl,
}) => null;
