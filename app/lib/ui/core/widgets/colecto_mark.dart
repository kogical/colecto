import 'package:flutter/widgets.dart';

import '../theme/colecto_palette.dart';

/// The mark, shared with Colecto (`docs/branding/logo-square.svg`): an open
/// mint C with a paper plane flying through it. Drawn from the SVG's own
/// geometry so it stays crisp at every size without an SVG renderer.
class ColectoMark extends StatelessWidget {
  const ColectoMark({super.key, this.size = 24});

  final double size;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      image: true,
      label: 'Colecto',
      child: SizedBox.square(
        dimension: size,
        child: const RepaintBoundary(
          child: CustomPaint(painter: _MarkPainter()),
        ),
      ),
    );
  }
}

class _MarkPainter extends CustomPainter {
  const _MarkPainter();

  static const _tile = Color(0xFF1C211E);
  static const _mint = Color(0xFFA2D6B1);
  static const _planeLight = Color(0xFFE7EDE8);
  static const _planeShade = Color(0xFFB7C6BB);

  static final _tileRect = RRect.fromLTRBR(
    6,
    6,
    114,
    114,
    const Radius.circular(28),
  );
  static final _tilePaint = Paint()..color = _tile;
  static final _mintArcPaint = Paint()
    ..style = PaintingStyle.stroke
    ..strokeCap = StrokeCap.round
    ..strokeWidth = 10
    ..color = _mint;
  static final _cutoutArcPaint = Paint()
    ..style = PaintingStyle.stroke
    ..strokeCap = StrokeCap.round
    ..strokeWidth = 14.4
    ..color = _tile;
  static final _planeOutlineStroke = Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = 6.8
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round
    ..color = _tile;
  static final _lightWingFill = Paint()..color = _planeLight;
  static final _lightWingStroke = Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = 2.4
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round
    ..color = _planeLight;
  static final _shadeWingFill = Paint()..color = _planeShade;
  static final _shadeWingStroke = Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = 2.4
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round
    ..color = _planeShade;

  static final _topArc = Path()
    ..moveTo(84, 36)
    ..arcToPoint(
      const Offset(36, 36),
      radius: const Radius.circular(34),
      largeArc: false,
      clockwise: false,
    );
  static final _planeOutline = Path()
    ..moveTo(100, 30)
    ..lineTo(26.4, 54.5)
    ..lineTo(54.8, 63.8)
    ..lineTo(55.8, 93.7)
    ..close();
  static final _lightWing = Path()
    ..moveTo(100, 30)
    ..lineTo(26.4, 54.5)
    ..lineTo(54.8, 63.8)
    ..close();
  static final _shadeWing = Path()
    ..moveTo(100, 30)
    ..lineTo(55.8, 93.7)
    ..lineTo(54.8, 63.8)
    ..close();
  static final _cutoutArc = Path()
    ..moveTo(40.5, 32.1)
    ..arcToPoint(
      const Offset(84, 84),
      radius: const Radius.circular(34),
      largeArc: true,
      clockwise: false,
    );
  static final _frontArc = Path()
    ..moveTo(46.7, 28.7)
    ..arcToPoint(
      const Offset(84, 84),
      radius: const Radius.circular(34),
      largeArc: true,
      clockwise: false,
    );

  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(size.width / 120);
    canvas.drawRRect(_tileRect, _tilePaint);
    canvas.drawPath(_topArc, _mintArcPaint);
    canvas.drawPath(_planeOutline, _tilePaint);
    canvas.drawPath(_planeOutline, _planeOutlineStroke);
    canvas.drawPath(_lightWing, _lightWingFill);
    canvas.drawPath(_lightWing, _lightWingStroke);
    canvas.drawPath(_shadeWing, _shadeWingFill);
    canvas.drawPath(_shadeWing, _shadeWingStroke);
    canvas.drawPath(_cutoutArc, _cutoutArcPaint);
    canvas.drawPath(_frontArc, _mintArcPaint);
  }

  @override
  bool shouldRepaint(_MarkPainter old) => false;
}

/// Mark plus the name, used in the top bar.
class ColectoBrand extends StatelessWidget {
  const ColectoBrand({super.key, this.markSize = 22});

  final double markSize;

  @override
  Widget build(BuildContext context) {
    final p = ColectoPalette.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        ColectoMark(size: markSize),
        const SizedBox(width: 8),
        Text(
          'Colecto',
          style: kStyle(
            14.5,
            weight: 660,
            width: 108,
            color: p.ink,
            height: 1.0,
            letterSpacing: -0.2,
          ),
        ),
      ],
    );
  }
}
