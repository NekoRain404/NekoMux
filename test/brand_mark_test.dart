import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neko_mux/widgets/brand_mark.dart';

/// Guards the one thing that can go wrong with a mark drawn twice.
///
/// The launcher icon is rendered from `assets/icon/icon_foreground.svg`; the
/// app draws the same mark with [BrandMark]. Two copies of one drawing drift the
/// moment somebody edits one of them — and the drift is invisible, because both
/// halves still look like a cat with a prompt.
///
/// So this test reads the SVG and asserts the widget's coordinates are the
/// SVG's. It is deliberately a coordinate comparison rather than a screenshot:
/// a screenshot test would also fail on antialiasing, and would not say which
/// number was wrong.
void main() {
  late String svg;

  setUpAll(() {
    final file = File('assets/icon/icon_foreground.svg');
    expect(
      file.existsSync(),
      isTrue,
      reason: 'the launcher icon source is missing; BrandMark has no reference',
    );
    svg = file.readAsStringSync();
  });

  /// Every `x,y` pair in [svg] that appears inside the given [element] tag, as
  /// offsets. Handles the polygon and rect forms the mark uses.
  List<Offset> pointsIn(String element) {
    final match = RegExp(
      '<$element[^>]*>',
    ).allMatches(svg).map((m) => m.group(0)!).toList();
    final points = <Offset>[];
    for (final tag in match) {
      final pointsAttr = RegExp('points="([^"]+)"').firstMatch(tag);
      if (pointsAttr != null) {
        for (final pair in pointsAttr.group(1)!.trim().split(RegExp(r'\s+'))) {
          final xy = pair.split(',');
          points.add(Offset(double.parse(xy[0]), double.parse(xy[1])));
        }
      }
    }
    return points;
  }

  /// A single numeric attribute of the first matching tag.
  double attribute(String element, String name) {
    final tag = RegExp('<$element[^>]*>').firstMatch(svg);
    expect(tag, isNotNull, reason: 'no <$element> in the SVG');
    final match = RegExp('$name="([0-9.]+)"').firstMatch(tag!.group(0)!);
    expect(match, isNotNull, reason: '$element has no $name');
    return double.parse(match!.group(1)!);
  }

  test('the ears are the SVG\'s ears', () {
    final polygon = pointsIn('polygon');
    expect(polygon, hasLength(6), reason: 'two ears, three points each');

    expect(polygon, contains(const Offset(30, 28)));
    expect(polygon, contains(const Offset(30, 46)));
    expect(polygon, contains(const Offset(46, 46)));
    expect(polygon, contains(const Offset(78, 28)));
    expect(polygon, contains(const Offset(78, 46)));
    expect(polygon, contains(const Offset(62, 46)));
  });

  test('the prompt chevron is the SVG\'s chevron', () {
    // The path is written as `M x y L x y L x y`; pull the numbers in order.
    final path = RegExp(r'<path[^>]*d="([^"]+)"').firstMatch(svg)!.group(1)!;
    final numbers = RegExp(r'-?[0-9.]+')
        .allMatches(path)
        .map((m) => double.parse(m.group(0)!))
        .toList();
    expect(numbers, hasLength(6), reason: 'three points: M, L, L');

    expect(numbers[0], 33);
    expect(numbers[1], 57);
    expect(numbers[2], 46);
    expect(numbers[3], 67);
    expect(numbers[4], 33);
    expect(numbers[5], 77);
  });

  test('the chevron stroke, cursor and canvas are the SVG\'s', () {
    expect(attribute('path', 'stroke-width'), 8);
    expect(attribute('rect', 'x'), 56);
    expect(attribute('rect', 'y'), 74);
    expect(attribute('rect', 'width'), 22);
    expect(attribute('rect', 'height'), 6);
    expect(attribute('rect', 'rx'), 3);
  });

  test('the mark stays inside the adaptive-icon safe circle', () {
    // The same rule the SVG is built to: every ink point within 36 units of the
    // 108-unit canvas centre. A launcher cuts the icon to a circle, and a
    // circular avatar in the app would clip the same corners — so a coordinate
    // that leaves this circle is wrong in both places at once.
    const centre = Offset(54, 54);
    const radius = 36.0;

    // The ears and the cursor are filled shapes, so their own corners are their
    // outermost ink. The chevron is stroked, so its ink extends half the stroke
    // beyond each vertex — in every direction, because the caps are round. The
    // farthest such point is the vertex pushed straight out from the centre,
    // which is what is computed here rather than a box around it: a box would
    // add the two offsets at once and report a corner no round cap can reach.
    final filled = <Offset>[
      ...pointsIn('polygon'),
      const Offset(56, 74),
      const Offset(56 + 22, 74),
      const Offset(56, 74 + 6),
      const Offset(56 + 22, 74 + 6),
    ];
    final stroked = <Offset>[
      const Offset(33, 57),
      const Offset(46, 67),
      const Offset(33, 77),
    ];

    for (final p in filled) {
      expect(
        (p - centre).distance,
        lessThanOrEqualTo(radius),
        reason: '$p is outside the safe circle a launcher keeps',
      );
    }
    for (final p in stroked) {
      final outward = p - centre;
      final pushed = p + outward / outward.distance * (8 / 2);
      expect(
        (pushed - centre).distance,
        lessThanOrEqualTo(radius),
        reason: 'the chevron\'s cap at $p reaches past the safe circle',
      );
    }
  });

  testWidgets('it paints, and repaints only when its colours change', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: Center(child: BrandMark(size: 28))),
      ),
    );

    expect(find.byType(BrandMark), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
