import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neko_mux/widgets/quick_key_bar.dart';

/// Guards the terminal's quick key table.
/// 守护终端快捷按键表。
///
/// A key whose `sequence` is empty looks perfectly normal in the bar and does
/// nothing when tapped, and a control key written with the wrong escape
/// (`\x0B` instead of `\x15`, say) looks equally normal and sends the wrong
/// control character to a live shell — where it can do real damage. Neither is
/// visible in a screenshot, so both are pinned here.
/// `sequence` 为空的按键在栏里看起来完全正常，点下去却什么也不做；而转义写错的
/// 控制键（比如把 `\x15` 写成 `\x0B`）同样看不出异常，却会把错误的控制字符发给
/// 真实的 shell——那是可能造成实际破坏的。两者都无法从截图上看出来，因此在这里
/// 钉死。
void main() {
  group('QuickKeyBar key table', () {
    test('every key has a label and a non-empty escape sequence', () {
      expect(QuickKeyBar.keyGroups, isNotEmpty);
      expect(QuickKeyBar.allKeys, isNotEmpty);

      for (final group in QuickKeyBar.keyGroups) {
        expect(group, isNotEmpty, reason: 'empty key group');
        for (final key in group) {
          expect(key.label.trim(), isNotEmpty, reason: 'key without a label');
          expect(
            key.sequence,
            isNotEmpty,
            reason: '${key.label} sends nothing when tapped',
          );
        }
      }
    });

    test('no two keys send the same bytes', () {
      final seen = <String, String>{};
      for (final key in QuickKeyBar.allKeys) {
        final previous = seen[key.sequence];
        expect(previous, isNull, reason: '${key.label} duplicates $previous');
        seen[key.sequence] = key.label;
      }
    });

    test('every C-x key sends the control byte for that letter', () {
      final labelPattern = RegExp(r'^C-([a-zA-Z])$');

      for (final key in QuickKeyBar.allKeys) {
        final match = labelPattern.firstMatch(key.label);
        if (match == null) continue;

        final letter = match.group(1)!.toLowerCase().codeUnitAt(0);
        expect(
          key.sequence.length,
          1,
          reason: '${key.label} should send exactly one byte',
        );
        expect(
          key.sequence.codeUnitAt(0),
          letter - 0x60,
          reason:
              '${key.label} should send Ctrl+${match.group(1)} (0x${(letter - 0x60).toRadixString(16)})',
        );
      }
    });

    test('the keys the terminal already had keep their exact sequences', () {
      final byLabel = <String, String>{
        for (final key in QuickKeyBar.allKeys) key.label: key.sequence,
      };

      expect(byLabel['Tab'], '\t');
      expect(byLabel['↑'], '\x1B[A');
      expect(byLabel['↓'], '\x1B[B');
      expect(byLabel['←'], '\x1B[D');
      expect(byLabel['→'], '\x1B[C');
      expect(byLabel['Home'], '\x1B[H');
      expect(byLabel['End'], '\x1B[F');
      expect(byLabel['PgUp'], '\x1B[5~');
      expect(byLabel['PgDn'], '\x1B[6~');
      expect(byLabel['Esc'], '\x1B');
      expect(byLabel['C-c'], '\x03');
      expect(byLabel['C-d'], '\x04');
      expect(byLabel['C-z'], '\x1A');
      expect(byLabel['/'], '/');
      expect(byLabel['|'], '|');
    });

    test('the readline line-editing keys are present', () {
      final labels = QuickKeyBar.allKeys.map((k) => k.label).toSet();

      expect(
        labels,
        containsAll(<String>['C-a', 'C-e', 'C-u', 'C-w', 'C-k', 'C-l', 'C-r']),
      );
    });
  });

  group('QuickKeyBar', () {
    /// Keys are laid out in one long scrollable row, so a realistic phone width
    /// only shows the first handful; the tests below tap keys from every group.
    /// 按键排成一条很长的可滚动行，真实手机宽度只能看到最前面几个；下面的测试会
    /// 点击每个分组中的按键。
    void useWideSurface(WidgetTester tester) {
      tester.view.physicalSize = const Size(2600, 400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
    }

    testWidgets('tapping a key reports its label and escape sequence', (
      tester,
    ) async {
      useWideSurface(tester);
      final taps = <String, String>{};

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: QuickKeyBar(
              onKeyTap: (label, sequence) => taps[label] = sequence,
            ),
          ),
        ),
      );

      for (final label in <String>['Tab', 'C-c', 'C-a', 'C-r', '~']) {
        await tester.tap(find.text(label));
      }

      expect(taps, <String, String>{
        'Tab': '\t',
        'C-c': '\x03',
        'C-a': '\x01',
        'C-r': '\x12',
        '~': '~',
      });
      expect(tester.takeException(), isNull);
    });

    testWidgets('the snippets pill appears only when it has a callback', (
      tester,
    ) async {
      useWideSurface(tester);
      var snippetsTaps = 0;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: QuickKeyBar(onSnippetsTap: () => snippetsTaps++),
          ),
        ),
      );

      await tester.tap(find.text('{}'));
      expect(snippetsTaps, 1);

      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: QuickKeyBar())),
      );
      expect(find.text('{}'), findsNothing);
    });

    testWidgets('the paste pill appears only when it has a callback', (
      tester,
    ) async {
      // Same shape as the snippets pill above, and for the same reason: a pill
      // drawn without a callback is a key that looks tappable and does nothing,
      // and this one is hidden while the shell is disconnected precisely
      // because pasting into nothing has no visible outcome.
      useWideSurface(tester);
      var pasteTaps = 0;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: QuickKeyBar(onPasteTap: () => pasteTaps++)),
        ),
      );

      await tester.tap(find.text('📋'));
      expect(pasteTaps, 1);

      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: QuickKeyBar())),
      );
      expect(find.text('📋'), findsNothing);
    });

    testWidgets('a bar with no callbacks still renders and ignores taps', (
      tester,
    ) async {
      useWideSurface(tester);

      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: QuickKeyBar())),
      );

      await tester.tap(find.text('Tab'));
      expect(tester.takeException(), isNull);
    });
  });
}
