import 'dart:convert';

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:kogi_webview/kogi_webview.dart';

/// `--dart-define=KOGI_SMOKE=true` loads a page of known colours and prints
/// `KOGI_SMOKE_READY {...}` with where to sample them (see tool/).
const _smoke = bool.fromEnvironment('KOGI_SMOKE');

const _bg = Color(0xFF15181A);
const _panel = Color(0xFF20252A);
const _ink = Color(0xFFE8ECEF);
const _muted = Color(0xFF94A0A8);
const _accent = Color(0xFF6FD3A0);

void main() => runApp(const ExampleApp());

class ExampleApp extends StatelessWidget {
  const ExampleApp({super.key});

  @override
  Widget build(BuildContext context) => WidgetsApp(
    color: _accent,
    debugShowCheckedModeBanner: false,
    textStyle: const TextStyle(color: _ink, fontSize: 14, height: 1.4),
    pageRouteBuilder: <T>(settings, builder) => PageRouteBuilder<T>(
      settings: settings,
      pageBuilder: (c, _, _) => builder(c),
    ),
    home: const ReaderPage(),
  );
}

class ReaderPage extends StatefulWidget {
  const ReaderPage({super.key});

  @override
  State<ReaderPage> createState() => _ReaderPageState();
}

class _ReaderPageState extends State<ReaderPage> {
  final _slot = GlobalKey();
  double _height = 400;
  String _status = 'Right-click, select, click links, scroll, resize.';
  int _toastClicks = 0;
  bool _smokeReported = false;

  void _say(String s) => setState(() => _status = s);

  void _onHeight(double h) {
    setState(() => _height = h);
    if (_smoke && !_smokeReported) {
      _smokeReported = true;
      // Two frames: one to resize the slot, one to place the native view.
      SchedulerBinding.instance.addPostFrameCallback((_) {
        SchedulerBinding.instance.addPostFrameCallback((_) {
          final box = _slot.currentContext!.findRenderObject()! as RenderBox;
          final r = box.localToGlobal(Offset.zero) & box.size;
          // ignore: avoid_print
          print(
            'KOGI_SMOKE_READY ${jsonEncode({'x': r.left, 'y': r.top, 'w': r.width, 'h': r.height, 'dpr': View.of(context).devicePixelRatio})}',
          );
        });
        SchedulerBinding.instance.scheduleFrame();
      });
    }
  }

  void _openPopup() {
    Navigator.of(context).push(
      PageRouteBuilder<void>(
        opaque: false,
        barrierColor: const Color(0x99000000),
        barrierDismissible: true,
        pageBuilder: (context, _, _) => Center(
          child: Container(
            width: 360,
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: _panel,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: _muted),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'A route above the view',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 8),
                const Text(
                  'The page underneath is dimmed and ignores clicks.',
                  style: TextStyle(color: _muted),
                ),
                const SizedBox(height: 14),
                _Button('Close', () => Navigator.of(context).pop()),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      // Opaque on purpose: the view must punch through it.
      color: _bg,
      child: Stack(
        children: [
          Column(
            children: [
              Container(
                height: 52,
                color: _panel,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  children: [
                    const Text(
                      'kogi_webview',
                      style: TextStyle(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Text(
                        _status,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: _muted),
                      ),
                    ),
                    _Button('Open dialog', _openPopup),
                  ],
                ),
              ),
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Text(
                        'Flutter content above the view',
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 16),
                      SizedBox(
                        key: _slot,
                        height: _height,
                        child: KogiWebView(
                          html: _smoke ? _smokeHtml : _demoHtml,
                          background: const Color(0xFFFFFFFF),
                          onContentHeight: _onHeight,
                          onLinkTap: (url) => _say('Link: $url'),
                          onContextMenu: (m) {
                            if (m.hasSelection) m.copySelection();
                            _say(
                              'Context menu at ${m.globalPosition.dx.round()},'
                              '${m.globalPosition.dy.round()}'
                              '${m.link != null ? ' on ${m.link}' : ''}'
                              '${m.hasSelection ? ' (selection copied)' : ''}',
                            );
                          },
                        ),
                      ),
                      const SizedBox(height: 16),
                      const SizedBox(
                        height: 600,
                        child: Text(
                          'Flutter content below the view',
                          style: TextStyle(color: _muted),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
          // A non-route overlay floating above the view.
          Positioned(
            right: 24,
            bottom: 24,
            child: KogiWebViewOccluder(
              child: Container(
                key: const ValueKey('toast'),
                width: 260,
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: const Color(0xFF00C853),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    Expanded(child: Text('Toast clicks: $_toastClicks')),
                    _Button(
                      '+1',
                      () => setState(() => _toastClicks++),
                      color: _bg,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Button extends StatelessWidget {
  const _Button(this.label, this.onTap, {this.color = _accent});

  final String label;
  final VoidCallback onTap;
  final Color color;

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: onTap,
    child: MouseRegion(
      cursor: SystemMouseCursors.click,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          border: Border.all(color: color),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(label, style: TextStyle(color: color)),
      ),
    ),
  );
}

/// Two solid bands the smoke test samples: red on top, blue below.
const _smokeHtml = '''<!doctype html><html><body style="margin:0">
<div style="height:300px;background:#e00000"></div>
<div style="height:300px;background:#0044ee"></div>
</body></html>''';

const _demoHtml = '''<!doctype html><html><head><meta charset="utf-8"><style>
body{margin:0;font:15px/1.6 system-ui,sans-serif;color:#1d2327;background:#f2f4f3}
.card{max-width:560px;margin:24px auto;background:#fff;border-radius:8px;padding:28px}
a.btn{display:inline-block;background:#1f7a52;color:#fff;padding:12px 22px;border-radius:6px;text-decoration:none}
</style></head><body><div class="card">
<h1 style="margin-top:0">Hello from WebKitGTK</h1>
<p>This document is live: select text, right-click it, or follow the link.
Remote loads like the image below are blocked by default.</p>
<p><img src="https://example.com/tracker.png" alt="(blocked remote image)"></p>
<p><a class="btn" href="https://example.com/">Open example.com</a></p>
<p>Lorem ipsum dolor sit amet, consectetur adipiscing elit. Integer posuere erat a ante venenatis dapibus posuere velit aliquet. Cras mattis consectetur purus sit amet fermentum. Donec ullamcorper nulla non metus auctor fringilla.</p>
<p>Vestibulum id ligula porta felis euismod semper. Aenean lacinia bibendum nulla sed consectetur. Curabitur blandit tempus porttitor. Etiam porta sem malesuada magna mollis euismod.</p>
</div></body></html>''';
