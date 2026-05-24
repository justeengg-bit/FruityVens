import 'dart:math' as math;

import 'package:flutter/material.dart';

enum _FruitMarkShape {
  apple,
  citrus,
  banana,
  mango,
  grapes,
  papaya,
  watermelon,
  pineapple,
  avocado,
  coconut,
  dragonFruit,
  durian,
  mangosteen,
  rambutan,
  atis,
  starApple,
  tamarind,
  melon,
  pear,
  strawberry,
  guava,
}

class _FruitMarkSpec {
  const _FruitMarkSpec({
    required this.shape,
    required this.stroke,
    required this.fill,
    required this.accent,
  });

  final _FruitMarkShape shape;
  final Color stroke;
  final Color fill;
  final Color accent;
}

class _FruitMarkCatalog {
  const _FruitMarkCatalog._();

  static const _FruitMarkSpec fallback = _FruitMarkSpec(
    shape: _FruitMarkShape.mango,
    stroke: Color(0xFFFFB74D),
    fill: Color(0xFFFFCC80),
    accent: Color(0xFF81C784),
  );

  static _FruitMarkSpec specFor(String fruitName) {
    return switch (fruitName) {
      'Apple' => const _FruitMarkSpec(
        shape: _FruitMarkShape.apple,
        stroke: Color(0xFFE53935),
        fill: Color(0xFFFFCDD2),
        accent: Color(0xFF7CB342),
      ),
      'Orange' => const _FruitMarkSpec(
        shape: _FruitMarkShape.citrus,
        stroke: Color(0xFFFF9800),
        fill: Color(0xFFFFCC80),
        accent: Color(0xFF81C784),
      ),
      'Lemon' => const _FruitMarkSpec(
        shape: _FruitMarkShape.citrus,
        stroke: Color(0xFFFDD835),
        fill: Color(0xFFFFF59D),
        accent: Color(0xFF9CCC65),
      ),
      'Calamansi' => const _FruitMarkSpec(
        shape: _FruitMarkShape.citrus,
        stroke: Color(0xFF66BB6A),
        fill: Color(0xFFC8E6C9),
        accent: Color(0xFFFFD54F),
      ),
      'Pomelo' => const _FruitMarkSpec(
        shape: _FruitMarkShape.citrus,
        stroke: Color(0xFFFFB74D),
        fill: Color(0xFFFFE0B2),
        accent: Color(0xFFF48FB1),
      ),
      'Dalandan' => const _FruitMarkSpec(
        shape: _FruitMarkShape.citrus,
        stroke: Color(0xFFFFA726),
        fill: Color(0xFFFFCC80),
        accent: Color(0xFF66BB6A),
      ),
      'Santol' => const _FruitMarkSpec(
        shape: _FruitMarkShape.citrus,
        stroke: Color(0xFFD7A85C),
        fill: Color(0xFFFFE0B2),
        accent: Color(0xFF8BC34A),
      ),
      'Banana' || 'Langkatan' => const _FruitMarkSpec(
        shape: _FruitMarkShape.banana,
        stroke: Color(0xFFFBC02D),
        fill: Color(0xFFFFF59D),
        accent: Color(0xFF7CB342),
      ),
      'Mango' || 'Mango Carabao' || 'Indian Mango' => const _FruitMarkSpec(
        shape: _FruitMarkShape.mango,
        stroke: Color(0xFFFFB300),
        fill: Color(0xFFFFE082),
        accent: Color(0xFFFF7043),
      ),
      'Chico' => const _FruitMarkSpec(
        shape: _FruitMarkShape.mango,
        stroke: Color(0xFFB9804A),
        fill: Color(0xFFD7B07A),
        accent: Color(0xFF8D6E63),
      ),
      'Grapes' => const _FruitMarkSpec(
        shape: _FruitMarkShape.grapes,
        stroke: Color(0xFFAB47BC),
        fill: Color(0xFFE1BEE7),
        accent: Color(0xFF81C784),
      ),
      'Lanzones' => const _FruitMarkSpec(
        shape: _FruitMarkShape.grapes,
        stroke: Color(0xFFD7A85C),
        fill: Color(0xFFFFECB3),
        accent: Color(0xFF8BC34A),
      ),
      'Papaya' => const _FruitMarkSpec(
        shape: _FruitMarkShape.papaya,
        stroke: Color(0xFFFF8A00),
        fill: Color(0xFFFFCC80),
        accent: Color(0xFF263238),
      ),
      'Guyabano' => const _FruitMarkSpec(
        shape: _FruitMarkShape.papaya,
        stroke: Color(0xFF8BC34A),
        fill: Color(0xFFC5E1A5),
        accent: Color(0xFF2E7D32),
      ),
      'Watermelon' => const _FruitMarkSpec(
        shape: _FruitMarkShape.watermelon,
        stroke: Color(0xFF66BB6A),
        fill: Color(0xFFFF8A80),
        accent: Color(0xFF263238),
      ),
      'Pineapple' => const _FruitMarkSpec(
        shape: _FruitMarkShape.pineapple,
        stroke: Color(0xFFFFC107),
        fill: Color(0xFFFFECB3),
        accent: Color(0xFF66BB6A),
      ),
      'Jackfruit' => const _FruitMarkSpec(
        shape: _FruitMarkShape.durian,
        stroke: Color(0xFFDDAA42),
        fill: Color(0xFFFFE0B2),
        accent: Color(0xFF66BB6A),
      ),
      'Durian' => const _FruitMarkSpec(
        shape: _FruitMarkShape.durian,
        stroke: Color(0xFFC8A646),
        fill: Color(0xFFFFECB3),
        accent: Color(0xFF8BC34A),
      ),
      'Avocado' => const _FruitMarkSpec(
        shape: _FruitMarkShape.avocado,
        stroke: Color(0xFF66BB6A),
        fill: Color(0xFFC5E1A5),
        accent: Color(0xFFA1887F),
      ),
      'Coconut' => const _FruitMarkSpec(
        shape: _FruitMarkShape.coconut,
        stroke: Color(0xFFB9804A),
        fill: Color(0xFFD7B07A),
        accent: Color(0xFFFFF3E0),
      ),
      'Dragon Fruit' => const _FruitMarkSpec(
        shape: _FruitMarkShape.dragonFruit,
        stroke: Color(0xFFEC407A),
        fill: Color(0xFFF8BBD0),
        accent: Color(0xFF66BB6A),
      ),
      'Mangosteen' => const _FruitMarkSpec(
        shape: _FruitMarkShape.mangosteen,
        stroke: Color(0xFF8E24AA),
        fill: Color(0xFFD1C4E9),
        accent: Color(0xFF66BB6A),
      ),
      'Rambutan' => const _FruitMarkSpec(
        shape: _FruitMarkShape.rambutan,
        stroke: Color(0xFFE53935),
        fill: Color(0xFFFFCDD2),
        accent: Color(0xFF7CB342),
      ),
      'Atis' => const _FruitMarkSpec(
        shape: _FruitMarkShape.atis,
        stroke: Color(0xFF8BC34A),
        fill: Color(0xFFC5E1A5),
        accent: Color(0xFF2E7D32),
      ),
      'Star Apple' => const _FruitMarkSpec(
        shape: _FruitMarkShape.starApple,
        stroke: Color(0xFF7E57C2),
        fill: Color(0xFFD1C4E9),
        accent: Color(0xFFFFF3E0),
      ),
      'Tamarind' => const _FruitMarkSpec(
        shape: _FruitMarkShape.tamarind,
        stroke: Color(0xFF8D6E63),
        fill: Color(0xFFD7B07A),
        accent: Color(0xFFFFCC80),
      ),
      'Melon' => const _FruitMarkSpec(
        shape: _FruitMarkShape.melon,
        stroke: Color(0xFF9CCC65),
        fill: Color(0xFFE6EE9C),
        accent: Color(0xFFFFCC80),
      ),
      'Pear' => const _FruitMarkSpec(
        shape: _FruitMarkShape.pear,
        stroke: Color(0xFFAED581),
        fill: Color(0xFFE6EE9C),
        accent: Color(0xFF7CB342),
      ),
      'Guava' => const _FruitMarkSpec(
        shape: _FruitMarkShape.guava,
        stroke: Color(0xFF8BC34A),
        fill: Color(0xFFC5E1A5),
        accent: Color(0xFFFF8A80),
      ),
      'Strawberries' || 'Strawberry' => const _FruitMarkSpec(
        shape: _FruitMarkShape.strawberry,
        stroke: Color(0xFFE53935),
        fill: Color(0xFFFF8A80),
        accent: Color(0xFF66BB6A),
      ),
      _ => fallback,
    };
  }
}

class FruitMark extends StatelessWidget {
  const FruitMark({
    super.key,
    required this.name,
    this.size = 32,
    this.muted = false,
  });

  final String name;
  final double size;
  final bool muted;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: '$name fruit',
      image: true,
      child: Center(
        child: SizedBox.square(
          dimension: size,
          child: CustomPaint(
            painter: _FruitMarkPainter(
              _FruitMarkCatalog.specFor(name),
              muted ? 0.52 : 1,
            ),
          ),
        ),
      ),
    );
  }
}

class _FruitMarkPainter extends CustomPainter {
  const _FruitMarkPainter(this.spec, this.opacity);

  final _FruitMarkSpec spec;
  final double opacity;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    final double side = math.min(size.width, size.height);
    canvas.translate((size.width - side) / 2, (size.height - side) / 2);
    canvas.scale(side / 100);

    final Paint stroke = Paint()
      ..color = spec.stroke.withValues(alpha: opacity)
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..strokeWidth = 5.8;
    final Paint fill = Paint()
      ..color = spec.fill.withValues(alpha: 0.25 * opacity)
      ..style = PaintingStyle.fill;
    final Paint accent = Paint()
      ..color = spec.accent.withValues(alpha: opacity)
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..strokeWidth = 4.8;
    final Paint accentFill = Paint()
      ..color = spec.accent.withValues(alpha: 0.34 * opacity)
      ..style = PaintingStyle.fill;

    switch (spec.shape) {
      case _FruitMarkShape.apple:
        _drawApple(canvas, stroke, fill, accent, accentFill);
      case _FruitMarkShape.citrus:
        _drawCitrus(canvas, stroke, fill, accent, accentFill);
      case _FruitMarkShape.banana:
        _drawBanana(canvas, stroke, fill, accent);
      case _FruitMarkShape.mango:
        _drawMango(canvas, stroke, fill, accent, accentFill);
      case _FruitMarkShape.grapes:
        _drawGrapes(canvas, stroke, fill, accent, accentFill);
      case _FruitMarkShape.papaya:
        _drawPapaya(canvas, stroke, fill, accent, accentFill);
      case _FruitMarkShape.watermelon:
        _drawWatermelon(canvas, stroke, fill, accent, accentFill);
      case _FruitMarkShape.pineapple:
        _drawPineapple(canvas, stroke, fill, accent, accentFill);
      case _FruitMarkShape.avocado:
        _drawAvocado(canvas, stroke, fill, accent, accentFill);
      case _FruitMarkShape.coconut:
        _drawCoconut(canvas, stroke, fill, accent, accentFill);
      case _FruitMarkShape.dragonFruit:
        _drawDragonFruit(canvas, stroke, fill, accent, accentFill);
      case _FruitMarkShape.durian:
        _drawDurian(canvas, stroke, fill, accent, accentFill);
      case _FruitMarkShape.mangosteen:
        _drawMangosteen(canvas, stroke, fill, accent, accentFill);
      case _FruitMarkShape.rambutan:
        _drawRambutan(canvas, stroke, fill, accent);
      case _FruitMarkShape.atis:
        _drawAtis(canvas, stroke, fill, accent);
      case _FruitMarkShape.starApple:
        _drawStarApple(canvas, stroke, fill, accent, accentFill);
      case _FruitMarkShape.tamarind:
        _drawTamarind(canvas, stroke, fill, accent);
      case _FruitMarkShape.melon:
        _drawMelon(canvas, stroke, fill, accent);
      case _FruitMarkShape.pear:
        _drawPear(canvas, stroke, fill, accent, accentFill);
      case _FruitMarkShape.strawberry:
        _drawStrawberry(canvas, stroke, fill, accent, accentFill);
      case _FruitMarkShape.guava:
        _drawGuava(canvas, stroke, fill, accent, accentFill);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_FruitMarkPainter oldDelegate) {
    return oldDelegate.spec != spec || oldDelegate.opacity != opacity;
  }

  void _drawApple(
    Canvas canvas,
    Paint stroke,
    Paint fill,
    Paint accent,
    Paint accentFill,
  ) {
    final Path body = Path()
      ..moveTo(50, 30)
      ..cubicTo(39, 18, 19, 29, 21, 52)
      ..cubicTo(23, 78, 39, 89, 50, 79)
      ..cubicTo(61, 89, 77, 78, 79, 52)
      ..cubicTo(81, 29, 61, 18, 50, 30)
      ..close();
    canvas.drawPath(body, fill);
    canvas.drawPath(body, stroke);
    canvas.drawLine(const Offset(51, 29), const Offset(55, 16), accent);
    final Path leaf = Path()
      ..moveTo(56, 18)
      ..cubicTo(65, 6, 80, 9, 78, 24)
      ..cubicTo(69, 27, 62, 25, 56, 18)
      ..close();
    canvas.drawPath(leaf, accentFill);
    canvas.drawPath(leaf, accent);
  }

  void _drawCitrus(
    Canvas canvas,
    Paint stroke,
    Paint fill,
    Paint accent,
    Paint accentFill,
  ) {
    canvas.drawOval(const Rect.fromLTWH(22, 25, 56, 56), fill);
    canvas.drawOval(const Rect.fromLTWH(22, 25, 56, 56), stroke);
    canvas.drawArc(
      const Rect.fromLTWH(33, 35, 34, 34),
      -0.85,
      1.7,
      false,
      accent,
    );
    canvas.drawLine(const Offset(50, 52), const Offset(66, 52), accent);
    canvas.drawLine(const Offset(50, 52), const Offset(39, 39), accent);
    final Path leaf = Path()
      ..moveTo(57, 24)
      ..cubicTo(66, 13, 78, 16, 78, 29)
      ..cubicTo(69, 32, 62, 30, 57, 24)
      ..close();
    canvas.drawPath(leaf, accentFill);
    canvas.drawPath(leaf, accent);
  }

  void _drawBanana(Canvas canvas, Paint stroke, Paint fill, Paint accent) {
    final Path banana = Path()
      ..moveTo(24, 63)
      ..cubicTo(43, 80, 74, 73, 84, 41)
      ..cubicTo(69, 57, 45, 58, 28, 43)
      ..cubicTo(27, 51, 25, 58, 24, 63)
      ..close();
    canvas.drawPath(banana, fill);
    canvas.drawPath(banana, stroke);
    canvas.drawLine(const Offset(27, 43), const Offset(20, 38), accent);
    canvas.drawLine(const Offset(84, 41), const Offset(89, 34), accent);
  }

  void _drawMango(
    Canvas canvas,
    Paint stroke,
    Paint fill,
    Paint accent,
    Paint accentFill,
  ) {
    final Path mango = Path()
      ..moveTo(62, 18)
      ..cubicTo(84, 27, 83, 61, 62, 79)
      ..cubicTo(41, 96, 17, 80, 21, 52)
      ..cubicTo(24, 28, 43, 10, 62, 18)
      ..close();
    canvas.drawPath(mango, fill);
    canvas.drawPath(mango, stroke);
    canvas.drawPath(
      Path()
        ..moveTo(39, 71)
        ..cubicTo(48, 57, 54, 41, 59, 23),
      accent,
    );
    final Path leaf = Path()
      ..moveTo(59, 21)
      ..cubicTo(67, 8, 82, 10, 80, 25)
      ..cubicTo(71, 28, 64, 26, 59, 21)
      ..close();
    canvas.drawPath(leaf, accentFill);
    canvas.drawPath(leaf, accent);
  }

  void _drawGrapes(
    Canvas canvas,
    Paint stroke,
    Paint fill,
    Paint accent,
    Paint accentFill,
  ) {
    const List<Offset> grapes = <Offset>[
      Offset(43, 31),
      Offset(57, 31),
      Offset(35, 47),
      Offset(50, 47),
      Offset(65, 47),
      Offset(42, 63),
      Offset(58, 63),
      Offset(50, 78),
    ];
    for (final Offset grape in grapes) {
      canvas.drawCircle(grape, 10.5, fill);
      canvas.drawCircle(grape, 10.5, stroke);
    }
    canvas.drawLine(const Offset(50, 21), const Offset(50, 12), accent);
    final Path leaf = Path()
      ..moveTo(53, 21)
      ..cubicTo(62, 9, 76, 13, 74, 28)
      ..cubicTo(65, 30, 58, 27, 53, 21)
      ..close();
    canvas.drawPath(leaf, accentFill);
    canvas.drawPath(leaf, accent);
  }

  void _drawPapaya(
    Canvas canvas,
    Paint stroke,
    Paint fill,
    Paint accent,
    Paint accentFill,
  ) {
    final Path body = Path()
      ..moveTo(53, 15)
      ..cubicTo(78, 26, 82, 67, 56, 84)
      ..cubicTo(35, 95, 20, 74, 24, 48)
      ..cubicTo(27, 26, 39, 11, 53, 15)
      ..close();
    canvas.drawPath(body, fill);
    canvas.drawPath(body, stroke);
    final Path center = Path()
      ..moveTo(52, 31)
      ..cubicTo(65, 39, 66, 64, 53, 74)
      ..cubicTo(41, 64, 40, 40, 52, 31)
      ..close();
    canvas.drawPath(center, accentFill);
    canvas.drawPath(center, accent);
    _drawSeedDots(canvas, accent, const <Offset>[
      Offset(51, 44),
      Offset(55, 54),
      Offset(49, 62),
    ]);
  }

  void _drawWatermelon(
    Canvas canvas,
    Paint stroke,
    Paint fill,
    Paint accent,
    Paint accentFill,
  ) {
    final Path wedge = Path()
      ..moveTo(18, 66)
      ..quadraticBezierTo(50, 21, 82, 66)
      ..quadraticBezierTo(50, 82, 18, 66)
      ..close();
    canvas.drawPath(wedge, fill);
    canvas.drawPath(wedge, stroke);
    canvas.drawPath(
      Path()
        ..moveTo(23, 67)
        ..quadraticBezierTo(50, 77, 77, 67),
      accent,
    );
    _drawSeedDots(canvas, accentFill, const <Offset>[
      Offset(39, 58),
      Offset(50, 50),
      Offset(61, 58),
    ]);
  }

  void _drawPineapple(
    Canvas canvas,
    Paint stroke,
    Paint fill,
    Paint accent,
    Paint accentFill,
  ) {
    final Path crown = Path()
      ..moveTo(50, 25)
      ..lineTo(39, 9)
      ..lineTo(49, 16)
      ..lineTo(56, 5)
      ..lineTo(58, 18)
      ..lineTo(72, 13)
      ..lineTo(62, 28);
    canvas.drawPath(crown, accentFill);
    canvas.drawPath(crown, accent);
    final Path body = Path()
      ..moveTo(31, 32)
      ..cubicTo(20, 47, 25, 80, 50, 88)
      ..cubicTo(75, 80, 80, 47, 69, 32)
      ..cubicTo(58, 25, 42, 25, 31, 32)
      ..close();
    canvas.drawPath(body, fill);
    canvas.drawPath(body, stroke);
    canvas.drawLine(const Offset(35, 43), const Offset(63, 75), accent);
    canvas.drawLine(const Offset(65, 43), const Offset(37, 75), accent);
    canvas.drawLine(const Offset(31, 58), const Offset(69, 58), accent);
  }

  void _drawAvocado(
    Canvas canvas,
    Paint stroke,
    Paint fill,
    Paint accent,
    Paint accentFill,
  ) {
    final Path body = Path()
      ..moveTo(51, 16)
      ..cubicTo(73, 24, 79, 50, 68, 73)
      ..cubicTo(58, 92, 34, 91, 25, 71)
      ..cubicTo(15, 48, 28, 21, 51, 16)
      ..close();
    canvas.drawPath(body, fill);
    canvas.drawPath(body, stroke);
    canvas.drawCircle(const Offset(50, 62), 13, accentFill);
    canvas.drawCircle(const Offset(50, 62), 13, accent);
  }

  void _drawCoconut(
    Canvas canvas,
    Paint stroke,
    Paint fill,
    Paint accent,
    Paint accentFill,
  ) {
    canvas.drawOval(const Rect.fromLTWH(22, 24, 56, 56), fill);
    canvas.drawOval(const Rect.fromLTWH(22, 24, 56, 56), stroke);
    canvas.drawArc(
      const Rect.fromLTWH(31, 30, 38, 45),
      -2.1,
      1.1,
      false,
      accent,
    );
    _drawSeedDots(canvas, accentFill, const <Offset>[
      Offset(43, 43),
      Offset(57, 43),
      Offset(50, 55),
    ]);
  }

  void _drawDragonFruit(
    Canvas canvas,
    Paint stroke,
    Paint fill,
    Paint accent,
    Paint accentFill,
  ) {
    final Path body = Path()
      ..moveTo(50, 16)
      ..cubicTo(72, 25, 82, 54, 64, 79)
      ..cubicTo(44, 93, 19, 76, 23, 49)
      ..cubicTo(25, 29, 36, 18, 50, 16)
      ..close();
    final List<Path> fins = <Path>[
      Path()
        ..moveTo(35, 35)
        ..lineTo(18, 29)
        ..lineTo(29, 47),
      Path()
        ..moveTo(65, 40)
        ..lineTo(84, 33)
        ..lineTo(73, 54),
      Path()
        ..moveTo(47, 72)
        ..lineTo(36, 90)
        ..lineTo(57, 81),
    ];
    for (final Path fin in fins) {
      canvas.drawPath(fin, accentFill);
      canvas.drawPath(fin, accent);
    }
    canvas.drawPath(body, fill);
    canvas.drawPath(body, stroke);
    _drawSeedDots(canvas, accent, const <Offset>[
      Offset(46, 42),
      Offset(57, 51),
      Offset(43, 62),
      Offset(58, 68),
    ]);
  }

  void _drawDurian(
    Canvas canvas,
    Paint stroke,
    Paint fill,
    Paint accent,
    Paint accentFill,
  ) {
    final Path spikes = Path()
      ..moveTo(50, 13)
      ..lineTo(57, 27)
      ..lineTo(74, 22)
      ..lineTo(72, 40)
      ..lineTo(87, 50)
      ..lineTo(72, 60)
      ..lineTo(75, 78)
      ..lineTo(57, 74)
      ..lineTo(50, 89)
      ..lineTo(43, 74)
      ..lineTo(25, 78)
      ..lineTo(28, 60)
      ..lineTo(13, 50)
      ..lineTo(28, 40)
      ..lineTo(26, 22)
      ..lineTo(43, 27)
      ..close();
    canvas.drawPath(spikes, fill);
    canvas.drawPath(spikes, stroke);
    canvas.drawOval(const Rect.fromLTWH(33, 30, 34, 42), accentFill);
    canvas.drawOval(const Rect.fromLTWH(33, 30, 34, 42), accent);
  }

  void _drawMangosteen(
    Canvas canvas,
    Paint stroke,
    Paint fill,
    Paint accent,
    Paint accentFill,
  ) {
    canvas.drawOval(const Rect.fromLTWH(22, 29, 56, 54), fill);
    canvas.drawOval(const Rect.fromLTWH(22, 29, 56, 54), stroke);
    final Path crown = Path()
      ..moveTo(35, 30)
      ..quadraticBezierTo(43, 14, 50, 29)
      ..quadraticBezierTo(57, 14, 65, 30);
    canvas.drawPath(crown, accent);
    final Path star = _starPath(const Offset(50, 58), 15, 6, 5);
    canvas.drawPath(star, accentFill);
    canvas.drawPath(star, accent);
  }

  void _drawRambutan(Canvas canvas, Paint stroke, Paint fill, Paint accent) {
    for (int i = 0; i < 18; i += 1) {
      final double angle = (math.pi * 2 * i / 18) - math.pi / 2;
      final Offset inner = Offset(
        50 + math.cos(angle) * 28,
        52 + math.sin(angle) * 28,
      );
      final Offset outer = Offset(
        50 + math.cos(angle) * 39,
        52 + math.sin(angle) * 39,
      );
      canvas.drawLine(inner, outer, accent);
    }
    canvas.drawOval(const Rect.fromLTWH(23, 25, 54, 54), fill);
    canvas.drawOval(const Rect.fromLTWH(23, 25, 54, 54), stroke);
  }

  void _drawAtis(Canvas canvas, Paint stroke, Paint fill, Paint accent) {
    final Path body = Path()
      ..moveTo(50, 17)
      ..cubicTo(74, 25, 82, 56, 65, 78)
      ..cubicTo(48, 93, 24, 80, 20, 54)
      ..cubicTo(18, 31, 33, 19, 50, 17)
      ..close();
    canvas.drawPath(body, fill);
    canvas.drawPath(body, stroke);
    for (final double y in <double>[36, 49, 62]) {
      canvas.drawPath(
        Path()
          ..moveTo(30, y)
          ..quadraticBezierTo(50, y + 8, 70, y),
        accent,
      );
    }
    canvas.drawLine(const Offset(39, 29), const Offset(35, 73), accent);
    canvas.drawLine(const Offset(55, 25), const Offset(58, 79), accent);
  }

  void _drawStarApple(
    Canvas canvas,
    Paint stroke,
    Paint fill,
    Paint accent,
    Paint accentFill,
  ) {
    canvas.drawOval(const Rect.fromLTWH(22, 24, 56, 56), fill);
    canvas.drawOval(const Rect.fromLTWH(22, 24, 56, 56), stroke);
    final Path star = _starPath(const Offset(50, 52), 18, 7, 5);
    canvas.drawPath(star, accentFill);
    canvas.drawPath(star, accent);
  }

  void _drawTamarind(Canvas canvas, Paint stroke, Paint fill, Paint accent) {
    final Path pod = Path()
      ..moveTo(20, 62)
      ..cubicTo(31, 30, 60, 28, 80, 48)
      ..cubicTo(65, 71, 38, 82, 20, 62)
      ..close();
    canvas.drawPath(pod, fill);
    canvas.drawPath(pod, stroke);
    canvas.drawLine(const Offset(38, 44), const Offset(33, 70), accent);
    canvas.drawLine(const Offset(55, 40), const Offset(55, 69), accent);
    canvas.drawLine(const Offset(70, 48), const Offset(63, 64), accent);
  }

  void _drawMelon(Canvas canvas, Paint stroke, Paint fill, Paint accent) {
    canvas.drawOval(const Rect.fromLTWH(20, 22, 60, 60), fill);
    canvas.drawOval(const Rect.fromLTWH(20, 22, 60, 60), stroke);
    for (final double x in <double>[39, 50, 61]) {
      canvas.drawPath(
        Path()
          ..moveTo(x, 27)
          ..cubicTo(x - 8, 43, x - 8, 61, x, 77),
        accent,
      );
    }
  }

  void _drawPear(
    Canvas canvas,
    Paint stroke,
    Paint fill,
    Paint accent,
    Paint accentFill,
  ) {
    final Path pear = Path()
      ..moveTo(50, 18)
      ..cubicTo(64, 22, 66, 39, 58, 49)
      ..cubicTo(76, 59, 72, 86, 50, 88)
      ..cubicTo(28, 86, 24, 59, 42, 49)
      ..cubicTo(34, 39, 36, 22, 50, 18)
      ..close();
    canvas.drawPath(pear, fill);
    canvas.drawPath(pear, stroke);
    canvas.drawLine(const Offset(50, 18), const Offset(53, 8), accent);
    final Path leaf = Path()
      ..moveTo(54, 14)
      ..cubicTo(63, 5, 75, 8, 74, 20)
      ..cubicTo(66, 23, 59, 20, 54, 14)
      ..close();
    canvas.drawPath(leaf, accentFill);
    canvas.drawPath(leaf, accent);
  }

  void _drawStrawberry(
    Canvas canvas,
    Paint stroke,
    Paint fill,
    Paint accent,
    Paint accentFill,
  ) {
    final Path berry = Path()
      ..moveTo(50, 26)
      ..cubicTo(75, 20, 82, 43, 67, 68)
      ..cubicTo(58, 83, 50, 89, 50, 89)
      ..cubicTo(50, 89, 42, 83, 33, 68)
      ..cubicTo(18, 43, 25, 20, 50, 26)
      ..close();
    final Path leaves = Path()
      ..moveTo(32, 27)
      ..lineTo(43, 30)
      ..lineTo(50, 18)
      ..lineTo(57, 30)
      ..lineTo(68, 27);
    canvas.drawPath(leaves, accentFill);
    canvas.drawPath(leaves, accent);
    canvas.drawPath(berry, fill);
    canvas.drawPath(berry, stroke);
    _drawSeedDots(canvas, accent, const <Offset>[
      Offset(40, 45),
      Offset(57, 45),
      Offset(49, 58),
      Offset(39, 69),
      Offset(60, 69),
    ]);
  }

  void _drawGuava(
    Canvas canvas,
    Paint stroke,
    Paint fill,
    Paint accent,
    Paint accentFill,
  ) {
    canvas.drawOval(const Rect.fromLTWH(23, 24, 54, 58), fill);
    canvas.drawOval(const Rect.fromLTWH(23, 24, 54, 58), stroke);
    canvas.drawOval(const Rect.fromLTWH(35, 38, 30, 30), accentFill);
    canvas.drawOval(const Rect.fromLTWH(35, 38, 30, 30), accent);
    _drawSeedDots(canvas, stroke, const <Offset>[
      Offset(46, 49),
      Offset(55, 49),
      Offset(50, 58),
    ]);
  }

  void _drawSeedDots(Canvas canvas, Paint paint, List<Offset> seeds) {
    final Paint dotPaint = Paint()
      ..color = paint.color
      ..style = PaintingStyle.fill;
    for (final Offset seed in seeds) {
      canvas.drawCircle(seed, 2.5, dotPaint);
    }
  }

  Path _starPath(Offset center, double outer, double inner, int points) {
    final Path path = Path();
    for (int i = 0; i < points * 2; i += 1) {
      final double radius = i.isEven ? outer : inner;
      final double angle = -math.pi / 2 + i * math.pi / points;
      final Offset point = Offset(
        center.dx + math.cos(angle) * radius,
        center.dy + math.sin(angle) * radius,
      );
      if (i == 0) {
        path.moveTo(point.dx, point.dy);
      } else {
        path.lineTo(point.dx, point.dy);
      }
    }
    return path..close();
  }
}
