import 'package:flutter_widget_from_html_core/flutter_widget_from_html_core.dart';
import 'package:html/dom.dart' as dom;
import 'package:material_ui/material_ui.dart';

import '../../../data/platform/file_io.dart';
import '../theme/colecto_palette.dart';

/// Native Flutter renderer for Rust-sanitized HTML email on Desktop & Mobile.
///
/// Parses the HTML5 DOM and safe inline CSS (tables, nested divs, headings,
/// lists, blockquotes, code blocks, links, `data:`/`cid:` inline images, and
/// opted-in remote images) into native Flutter widgets with **zero WebView
/// RAM**. Relies on the enclosing `ReaderPane` `SelectionArea` for text
/// selection.
class NativeSanitizedHtmlView extends StatelessWidget {
  const NativeSanitizedHtmlView({
    super.key,
    required this.html,
    required this.plainTextFallback,
    this.designed = false,
    this.onOpenUrl,
  });

  final String html;
  final String plainTextFallback;
  final bool designed;
  final ValueChanged<String>? onOpenUrl;

  @override
  Widget build(BuildContext context) {
    final p = ColectoPalette.of(context);
    final themeStyle =
        Theme.of(context).textTheme.bodyMedium ??
        TextStyle(fontSize: 14, color: p.bodyInk, height: 1.5);
    final trimmed = html.trim();
    if (trimmed.isEmpty) {
      return Text(
        plainTextFallback.trim().isNotEmpty ? plainTextFallback : html,
        style: themeStyle.copyWith(color: p.bodyInk),
      );
    }

    final inkColor = designed ? const Color(0xFF111111) : p.bodyInk;
    final linkHex = designed ? '#0b57d0' : ColectoPalette.toHex(p.accent);
    final quoteBorderHex = designed ? '#d0d7de' : ColectoPalette.toHex(p.line);
    final codeBgHex = designed ? '#f6f8fa' : ColectoPalette.toHex(p.sunk);
    final hrHex = designed ? '#d8dee4' : ColectoPalette.toHex(p.lineSoft);

    final baseStyle = themeStyle.copyWith(color: inkColor, height: 1.5);

    final mutedColor = designed ? const Color(0xFF57606A) : p.ink3;
    Widget buildHtml(double maxContentWidth) => HtmlWidget(
      trimmed,
      textStyle: baseStyle,
      onLoadingBuilder: (context, element, loadingProgress) =>
          const SizedBox.shrink(),
      onErrorBuilder: (context, element, error) {
        final alt = element.attributes['alt']?.trim() ?? '';
        if (alt.isEmpty) return const SizedBox.shrink();
        return Text(alt, style: TextStyle(fontSize: 12, color: mutedColor));
      },
      onTapUrl: (url) {
        (onOpenUrl ?? openExternalUrl)(url);
        return true;
      },
      customStylesBuilder: (element) => _customStyles(
        element,
        maxContentWidth: maxContentWidth,
        linkHex: linkHex,
        quoteBorderHex: quoteBorderHex,
        codeBgHex: codeBgHex,
        hrHex: hrHex,
      ),
      customWidgetBuilder: (element) => _customWidget(element),
    );

    final body = LayoutBuilder(
      builder: (context, constraints) {
        final maxWidth =
            constraints.maxWidth.isFinite && constraints.maxWidth > 0
            ? constraints.maxWidth
            : 720.0;
        return buildHtml(maxWidth);
      },
    );

    if (!designed) return body;

    // Designed HTML emails assume a light sheet (matching Web's iframe).
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: ColoredBox(
        color: const Color(0xFFFFFFFF),
        child: Padding(padding: const EdgeInsets.all(16), child: body),
      ),
    );
  }

  static Map<String, String>? _customStyles(
    dom.Element element, {
    required double maxContentWidth,
    required String linkHex,
    required String quoteBorderHex,
    required String codeBgHex,
    required String hrHex,
  }) {
    final tag = element.localName;
    final capPx = '${maxContentWidth.floor()}px';
    if (tag == 'img') {
      // Cap oversized hero banners to the actual reader width even inside
      // fixed-width `<table>` cells, without ever upscaling small icons.
      return {'max-width': capPx, 'height': 'auto'};
    }
    if (tag == 'table') {
      return {'max-width': capPx};
    }
    if (tag == 'a') {
      final inline = (element.attributes['style'] ?? '').toLowerCase();
      final styles = <String, String>{};
      if (!RegExp(r'(?:^|;|\s)color\s*:').hasMatch(inline)) {
        styles['color'] = linkHex;
      }
      if (!inline.contains('text-decoration')) {
        styles['text-decoration'] = 'underline';
      }
      return styles.isEmpty ? null : styles;
    }
    if (tag == 'blockquote') {
      return {
        'margin': '8px 0',
        'padding': '4px 0 4px 12px',
        'border-left': '3px solid $quoteBorderHex',
      };
    }
    if (tag == 'pre') {
      return {
        'background-color': codeBgHex,
        'padding': '10px',
        'border-radius': '6px',
        'font-family': 'monospace',
        'font-size': '13px',
      };
    }
    if (tag == 'code') {
      return {
        'background-color': codeBgHex,
        'font-family': 'monospace',
        'font-size': '0.92em',
      };
    }
    if (tag == 'hr') {
      return {
        'border': 'none',
        'border-top': '1px solid $hrHex',
        'margin': '14px 0',
      };
    }
    return null;
  }

  static Widget? _customWidget(dom.Element element) {
    // Rust's sanitizer strips `src` from blocked remote images, leaving an
    // `<img>` without a source. Hide those cleanly instead of rendering broken
    // image boxes; ReaderPane already shows the blocked-images banner.
    if (element.localName == 'img') {
      final src = element.attributes['src']?.trim() ?? '';
      if (src.isEmpty) {
        return const SizedBox.shrink();
      }
    }
    return null;
  }
}
