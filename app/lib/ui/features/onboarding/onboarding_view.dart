import 'dart:async';
import 'dart:math' as math;

import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:material_ui/material_ui.dart';

import '../../../domain/models/account_models.dart';
import '../../core/kit/kit.dart';
import '../../core/theme/colecto_palette.dart';
import '../../core/widgets/colecto_mark.dart';
import '../settings/account_wizard.dart';
import '../shell/mail_controller.dart';

enum _Step { welcome, account, done }

/// First run: a welcome, the account wizard, and "You're all set". It
/// stays in the shell rather than Settings because it bootstraps the app.
class OnboardingView extends StatefulWidget {
  const OnboardingView({super.key, required this.controller});

  final MailController controller;

  @override
  State<OnboardingView> createState() => _OnboardingViewState();
}

class _OnboardingViewState extends State<OnboardingView> {
  _Step _step = _Step.welcome;
  String _added = '';
  String? _addedId;
  bool _finishing = false;

  MailController get c => widget.controller;

  Future<void> _finish({bool demo = false}) async {
    setState(() => _finishing = true);
    await c.finishOnboarding(account: _addedId, demo: demo);
  }

  void _saved(AccountInfo account, String name) => setState(() {
    _added = name;
    _addedId = account.id;
    _step = _Step.done;
  });

  @override
  Widget build(BuildContext context) {
    final p = ColectoPalette.of(context);
    final size = MediaQuery.sizeOf(context);
    final phone = size.width < 600;
    final Widget body = switch (_step) {
      _Step.welcome => _welcome(context),
      _Step.account =>
        phone
            ? _wizard()
            : Center(
                child: _Rise(
                  index: 0,
                  child: Container(
                    width: math.min(560, size.width - 32),
                    constraints: BoxConstraints(
                      maxHeight: math.min(700, size.height - 48),
                    ),
                    decoration: BoxDecoration(
                      color: p.float,
                      border: Border.all(color: p.line),
                      borderRadius: BorderRadius.circular(
                        colectoRadius(context) + 8,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: p.shadow.withValues(
                            alpha: p.isDark ? 0.75 : 0.18,
                          ),
                          blurRadius: 80,
                          spreadRadius: -20,
                          offset: const Offset(0, 30),
                        ),
                      ],
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: _wizard(),
                  ),
                ),
              ),
      _Step.done => _done(context),
    };
    return Material(
      color: p.ground,
      child: Stack(
        children: [
          const Positioned.fill(child: _Glow()),
          Positioned.fill(
            child: SafeArea(
              top: _step != _Step.account || !phone,
              bottom: _step != _Step.account || !phone,
              child: AnimatedSwitcher(
                duration: ColectoMotion.of(
                  context,
                  const Duration(milliseconds: 220),
                ),
                child: KeyedSubtree(key: ValueKey(_step), child: body),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _wizard() => AccountWizard(
    controller: c,
    title: 'Add your account',
    description:
        'Start with your email address; Colecto looks up the server '
        'settings.',
    submitLabel: 'Connect account',
    onClose: () => setState(() => _step = _Step.welcome),
    onSaved: _saved,
  );

  Widget _welcome(BuildContext context) {
    final p = ColectoPalette.of(context);
    return _Centered(
      children: [
        const _Rise(index: 0, child: _FloatingMark()),
        const SizedBox(height: 20),
        _Rise(
          index: 1,
          child: Semantics(
            header: true,
            child: Text(
              'Welcome to Colecto',
              textAlign: TextAlign.center,
              style: kStyle(26, weight: 640, width: 106, color: p.ink),
            ),
          ),
        ),
        const SizedBox(height: 12),
        _Rise(
          index: 2,
          child: Text(
            'A calm mail client for IMAP and JMAP. Add your first account to '
            'get started; your password stays on this device.',
            textAlign: TextAlign.center,
            style: kStyle(14.5, color: p.ink2, height: 1.55),
          ),
        ),
        const SizedBox(height: 24),
        _Rise(
          index: 3,
          child: Column(
            children: [
              ColectoButton(
                label: 'Add your first account',
                trailingIcon: LucideIcons.arrowRight,
                variant: ColectoButtonVariant.primary,
                onPressed: () => setState(() => _step = _Step.account),
              ),
              const SizedBox(height: 10),
              ColectoButton(
                label: 'Explore with sample mail first',
                variant: ColectoButtonVariant.text,
                onPressed: _finishing ? null : () => _finish(demo: true),
              ),
            ],
          ),
        ),
        const SizedBox(height: 28),
        const _Rise(
          index: 4,
          child: _StepDots(labels: ['Welcome', 'Account', 'Inbox']),
        ),
      ],
    );
  }

  Widget _done(BuildContext context) {
    final p = ColectoPalette.of(context);
    return _Centered(
      children: [
        const _DrawnCheck(),
        const SizedBox(height: 20),
        _Rise(
          index: 1,
          child: Semantics(
            header: true,
            child: Text(
              'You’re all set',
              textAlign: TextAlign.center,
              style: kStyle(26, weight: 640, width: 106, color: p.ink),
            ),
          ),
        ),
        const SizedBox(height: 12),
        _Rise(
          index: 2,
          child: Text.rich(
            TextSpan(
              children: [
                TextSpan(
                  text: _added,
                  style: kStyle(14.5, weight: 600, color: p.ink),
                ),
                const TextSpan(
                  text:
                      ' is added. Colecto fetches your mail in the '
                      'background; it shows up in your Inbox as it arrives.',
                ),
              ],
            ),
            textAlign: TextAlign.center,
            style: kStyle(14.5, color: p.ink2, height: 1.55),
          ),
        ),
        const SizedBox(height: 24),
        _Rise(
          index: 3,
          child: ColectoButton(
            label: _finishing ? 'Opening…' : 'Open Inbox',
            trailingIcon: LucideIcons.arrowRight,
            variant: ColectoButtonVariant.primary,
            onPressed: _finishing ? null : _finish,
          ),
        ),
      ],
    );
  }
}

class _Centered extends StatelessWidget {
  const _Centered({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Center(
    child: SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Column(mainAxisSize: MainAxisSize.min, children: children),
      ),
    ),
  );
}

/// Content arrives in a short stagger: each item fades up 8 px, 70 ms
/// after the one before.
class _Rise extends StatefulWidget {
  const _Rise({required this.index, required this.child});

  final int index;
  final Widget child;

  @override
  State<_Rise> createState() => _RiseState();
}

class _RiseState extends State<_Rise> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 520),
  );
  Timer? _delay;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_c.isAnimating || _c.isCompleted || _delay != null) return;
    if (MediaQuery.disableAnimationsOf(context)) {
      _c.value = 1;
    } else {
      _delay = Timer(Duration(milliseconds: 70 * widget.index), _c.forward);
    }
  }

  @override
  void dispose() {
    _delay?.cancel();
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = CurvedAnimation(parent: _c, curve: ColectoMotion.easeOut);
    return FadeTransition(
      opacity: t,
      child: AnimatedBuilder(
        animation: t,
        child: widget.child,
        builder: (_, child) => Transform.translate(
          offset: Offset(0, 8 * (1 - t.value)),
          child: child,
        ),
      ),
    );
  }
}

/// The mark, bobbing gently over a soft accent halo.
class _FloatingMark extends StatefulWidget {
  const _FloatingMark();

  @override
  State<_FloatingMark> createState() => _FloatingMarkState();
}

class _FloatingMarkState extends State<_FloatingMark>
    with SingleTickerProviderStateMixin {
  late final _c = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 3),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      _c.stop();
    } else if (!_c.isAnimating) {
      _c.repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = ColectoPalette.of(context);
    return SizedBox(
      width: 112,
      height: 112,
      child: AnimatedBuilder(
        animation: _c,
        builder: (_, _) {
          final t = Curves.easeInOut.transform(_c.value);
          return Stack(
            alignment: Alignment.center,
            children: [
              Transform.scale(
                scale: 1 + 0.06 * t,
                child: Container(
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: RadialGradient(
                      colors: [
                        p.accent.withValues(alpha: 0.18 - 0.07 * t),
                        p.accent.withValues(alpha: 0),
                      ],
                    ),
                  ),
                ),
              ),
              Transform.translate(
                offset: Offset(0, -4 * t),
                child: Transform.rotate(
                  angle: -0.026 * t,
                  child: const ColectoMark(size: 64),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// A faint accent wash behind everything.
class _Glow extends StatelessWidget {
  const _Glow();

  @override
  Widget build(BuildContext context) {
    final p = ColectoPalette.of(context);
    return IgnorePointer(
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: RadialGradient(
            center: const Alignment(0, -0.25),
            radius: 0.9,
            colors: [
              p.accent.withValues(alpha: p.isDark ? 0.09 : 0.12),
              p.accent.withValues(alpha: 0),
            ],
          ),
        ),
      ),
    );
  }
}

class _StepDots extends StatelessWidget {
  const _StepDots({required this.labels});

  final List<String> labels;

  @override
  Widget build(BuildContext context) {
    final p = ColectoPalette.of(context);
    return Semantics(
      label: 'Step 1 of ${labels.length}',
      excludeSemantics: true,
      child: Wrap(
        alignment: WrapAlignment.center,
        spacing: 18,
        children: [
          for (final (i, label) in labels.indexed)
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 6,
                  height: 6,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: i == 0 ? p.accent : p.line,
                  ),
                ),
                const SizedBox(width: 6),
                Text(label, style: kStyle(12, color: i == 0 ? p.ink2 : p.ink3)),
              ],
            ),
        ],
      ),
    );
  }
}

/// A ring that draws itself, then a tick.
class _DrawnCheck extends StatelessWidget {
  const _DrawnCheck();

  @override
  Widget build(BuildContext context) {
    final p = ColectoPalette.of(context);
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: ColectoMotion.of(context, const Duration(milliseconds: 800)),
      curve: ColectoMotion.easeOut,
      builder: (_, t, _) => CustomPaint(
        size: const Size.square(64),
        painter: _CheckPainter(t, p.accent),
      ),
    );
  }
}

class _CheckPainter extends CustomPainter {
  const _CheckPainter(this.t, this.color);

  final double t;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final ring = (t / 0.85).clamp(0.0, 1.0);
    final tick = ((t - 0.45) / 0.55).clamp(0.0, 1.0);
    final s = size.width / 64;
    canvas.drawArc(
      Rect.fromCircle(center: Offset(32 * s, 32 * s), radius: 28 * s),
      -math.pi / 2,
      2 * math.pi * ring,
      false,
      paint..color = color.withValues(alpha: 0.45),
    );
    final path = Path()
      ..moveTo(20 * s, 33.5 * s)
      ..lineTo(28 * s, 41.5 * s)
      ..lineTo(44 * s, 24.5 * s);
    for (final metric in path.computeMetrics()) {
      canvas.drawPath(
        metric.extractPath(0, metric.length * tick),
        paint..color = color,
      );
    }
  }

  @override
  bool shouldRepaint(_CheckPainter old) => old.t != t || old.color != color;
}
