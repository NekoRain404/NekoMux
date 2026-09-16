import 'package:flutter/material.dart';

/// The NekoMux mark: two cat ears over a shell prompt.
///
/// The same drawing as `assets/icon/icon_foreground.svg`, which is what the
/// launcher icon is rendered from. It is painted rather than shipped as a PNG so
/// it can take its colours from the theme: the launcher's sage green on a light
/// theme would be barely visible, and a bitmap cannot follow the theme the way
/// this can.
///
/// Two representations of one mark is a drift risk, and `test/brand_mark_test.dart`
/// is what removes it: the test reads the SVG and asserts every coordinate below
/// matches. Change the artwork in one place and the test fails until both agree.
///
/// The geometry lives in the SVG's own coordinate space — a 108×108 canvas whose
/// centre is (54, 54) — and is scaled to whatever size the caller asks for. See
/// `icon_foreground.svg` for why every point sits inside the adaptive-icon safe
/// circle, which is also what keeps the mark comfortable inside a circular
/// avatar here.
class BrandMark extends StatelessWidget {
  /// Width and height of the square the mark is drawn in.
  final double size;

  /// Colour of the ears and the prompt chevron. Defaults to the theme's primary.
  final Color? color;

  /// Colour of the cursor block. Defaults to the theme's secondary.
  final Color? cursorColor;

  const BrandMark({
    super.key,
    this.size = 28,
    this.color,
    this.cursorColor,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: _BrandMarkPainter(
          ink: color ?? cs.primary,
          cursor: cursorColor ?? cs.secondary,
        ),
        // The mark is decorative: the app's name sits beside it in every place
        // it is used, so announcing it would only repeat that.
        isComplex: false,
      ),
    );
  }
}

/// Draws [BrandMark]'s geometry, scaled from the SVG's 108-unit canvas.
class _BrandMarkPainter extends CustomPainter {
  final Color ink;
  final Color cursor;

  const _BrandMarkPainter({required this.ink, required this.cursor});

  /// The canvas the coordinates are expressed in, matching the SVG's viewBox.
  static const double canvas = 108;

  // --- Geometry, identical to assets/icon/icon_foreground.svg ---------------
  // Left ear's outer edge is vertical and its inner edge slopes inward; the
  // right ear mirrors it.
  static const Offset leftEarOuterTop = Offset(30, 28);
  static const Offset leftEarOuterBase = Offset(30, 46);
  static const Offset leftEarInnerBase = Offset(46, 46);
  static const Offset rightEarOuterTop = Offset(78, 28);
  static const Offset rightEarOuterBase = Offset(78, 46);
  static const Offset rightEarInnerBase = Offset(62, 46);

  // The prompt chevron, as three points of a stroked polyline.
  static const Offset chevronStart = Offset(33, 57);
  static const Offset chevronTip = Offset(46, 67);
  static const Offset chevronEnd = Offset(33, 77);
  static const double chevronStroke = 8;

  // The cursor block.
  static const double cursorLeft = 56;
  static const double cursorTop = 74;
  static const double cursorWidth = 22;
  static const double cursorHeight = 6;
  static const double cursorRadius = 3;

  @override
  void paint(Canvas canvasSize, Size size) {
    final s = size.width / canvas;
    canvasSize.save();
    canvasSize.scale(s);

    final fill = Paint()..color = ink;
    final stroke = Paint()
      ..color = ink
      ..style = PaintingStyle.stroke
      ..strokeWidth = chevronStroke
      // Round in both places, as the SVG asks: a mitre at this stroke width
      // grows a spike past the safe circle at the chevron's point.
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    void ear(Offset top, Offset outerBase, Offset innerBase) {
      final path = Path()
        ..moveTo(top.dx, top.dy)
        ..lineTo(outerBase.dx, outerBase.dy)
        ..lineTo(innerBase.dx, innerBase.dy)
        ..close();
      canvasSize.drawPath(path, fill);
    }

    ear(leftEarOuterTop, leftEarOuterBase, leftEarInnerBase);
    ear(rightEarOuterTop, rightEarOuterBase, rightEarInnerBase);

    canvasSize.drawPath(
      Path()
        ..moveTo(chevronStart.dx, chevronStart.dy)
        ..lineTo(chevronTip.dx, chevronTip.dy)
        ..lineTo(chevronEnd.dx, chevronEnd.dy),
      stroke,
    );

    canvasSize.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(cursorLeft, cursorTop, cursorWidth, cursorHeight),
        const Radius.circular(cursorRadius),
      ),
      Paint()..color = cursor,
    );

    canvasSize.restore();
  }

  @override
  bool shouldRepaint(_BrandMarkPainter old) =>
      old.ink != ink || old.cursor != cursor;
}
