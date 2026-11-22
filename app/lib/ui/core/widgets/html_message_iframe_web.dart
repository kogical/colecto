import 'dart:js_interop';
import 'dart:ui_web' as ui_web;

import 'package:flutter/widgets.dart';
import 'package:web/web.dart' as web;

import 'html_message_document.dart';

const _kIframeViewType = 'colecto-html-frame';
bool _factoryRegistered = false;

void _ensureFactoryRegistered() {
  if (_factoryRegistered) return;
  _factoryRegistered = true;
  ui_web.platformViewRegistry.registerViewFactory(_kIframeViewType, (
    int _, {
    Object? params,
  }) {
    final map = params is Map ? params : const <Object?, Object?>{};
    final html = map['html'] as String? ?? '';
    final designed = map['designed'] == true;
    final ink = map['ink'] as String? ?? '#dce3de';
    final link = map['link'] as String? ?? '#a2d6b1';

    final iframe = web.HTMLIFrameElement()
      ..sandbox.add('allow-popups')
      ..sandbox.add('allow-popups-to-escape-sandbox')
      ..referrerPolicy = 'no-referrer'
      ..title = 'Message content'
      ..style.border = 'none'
      ..style.width = '100%'
      ..style.height = '100%'
      ..style.borderRadius = designed ? '6px' : '0'
      ..style.background = designed ? '#ffffff' : 'transparent'
      ..style.opacity = '0'
      ..style.transition = 'opacity 180ms cubic-bezier(0.23, 1, 0.32, 1)'
      ..srcdoc = buildSandboxedEmailDocument(
        html,
        designed: designed,
        ink: ink,
        link: link,
      ).toJS;
    iframe.style.setProperty('color-scheme', designed ? 'light' : 'normal');
    // Fade in once the frame has painted instead of flashing a blank sheet.
    iframe.onload = ((web.Event _) {
      iframe.style.opacity = '1';
    }).toJS;
    return iframe;
  });
}

/// Renders Rust-sanitized HTML inside a real `<iframe sandbox>` on Flutter Web
/// (`AGENTS.md` rule 5). Uses a single registered platform view factory with
/// `creationParams` so opened emails never accumulate in a global map.
Widget? buildWebSandboxedHtmlIframe(
  String sanitizedHtml, {
  required bool designed,
  required String ink,
  required String link,
  required double height,
}) {
  _ensureFactoryRegistered();
  return SizedBox(
    height: height,
    child: HtmlElementView(
      key: ValueKey(Object.hash(designed, ink, link, sanitizedHtml)),
      viewType: _kIframeViewType,
      creationParams: <String, Object>{
        'html': sanitizedHtml,
        'designed': designed,
        'ink': ink,
        'link': link,
      },
    ),
  );
}
