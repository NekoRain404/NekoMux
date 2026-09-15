import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:neko_mux/core/i18n/data/de.dart';
import 'package:neko_mux/core/i18n/data/en.dart';
import 'package:neko_mux/core/i18n/data/es.dart';
import 'package:neko_mux/core/i18n/data/fr.dart';
import 'package:neko_mux/core/i18n/data/ja.dart';
import 'package:neko_mux/core/i18n/data/ko.dart';
import 'package:neko_mux/core/i18n/data/ru.dart';
import 'package:neko_mux/core/i18n/data/zh.dart';
import 'package:neko_mux/core/i18n/strings.dart';

/// Guards the translation table against the two ways it has silently rotted
/// before: a language falling behind the others, and a convenience getter
/// pointing at a key that nobody ever added. The second one shipped real
/// validation text to users as bare identifiers such as `must_enter_name`.
///
/// 守护翻译表曾静默腐化的两种方式：某语言落后于其他语言，以及便捷 getter
/// 指向了从未添加的键——后者曾把 `must_enter_name` 这样的裸标识符展示给用户。
///
/// The per-language tables are imported directly rather than read through
/// `AppStrings`: presence and emptiness cannot be asserted through the public
/// API, because a missing key returns the key name itself, which is
/// indistinguishable from a translation that legitimately equals its own key
/// (`sec` is `'sec'` in English).
/// 直接导入各语言表而不经由 `AppStrings`：缺失的键会返回键名本身，与“译文恰好
/// 等于键名”（如英文 `sec` 就是 `'sec'`）无法区分，因此公开 API 断言不了缺失与空值。
const Map<String, Map<String, String>> byLanguage = {
  'zh': zhStrings,
  'en': enStrings,
  'ja': jaStrings,
  'ko': koStrings,
  'fr': frStrings,
  'de': deStrings,
  'ru': ruStrings,
  'es': esStrings,
};

/// One file per language under `lib/core/i18n/data/`.
List<File> languageFiles() {
  final dir = Directory('lib/core/i18n/data');
  expect(dir.existsSync(), isTrue, reason: '${dir.path} is missing');
  return dir
      .listSync()
      .whereType<File>()
      .where((f) => f.path.endsWith('.dart'))
      .toList();
}

/// The facade that declares the getters and wires the tables together.
File facadeFile() => File('lib/core/i18n/strings.dart');

void main() {
  // The active language is global mutable state; every test here picks its own
  // and leaves the default behind.
  setUp(() => AppStrings.setLang('zh'));
  tearDown(() => AppStrings.setLang('zh'));

  group('translation table', () {
    test('declares the same key set for every language', () {
      final reference = byLanguage['zh']!.keys.toSet();
      expect(reference, isNotEmpty);

      byLanguage.forEach((lang, table) {
        expect(
          table.keys.toSet(),
          reference,
          reason: 'language "$lang" does not declare the same keys as "zh"',
        );
      });
    });

    test('has no blank or missing translation', () {
      byLanguage.forEach((lang, table) {
        table.forEach((key, text) {
          expect(text.trim(), isNotEmpty, reason: '$lang / $key is empty');
        });
      });
    });

    test('has no duplicate key inside a language file', () {
      final keyLine = RegExp(r"^\s*'([a-z0-9_]+)':", multiLine: true);
      var scanned = 0;

      for (final file in languageFiles()) {
        final seen = <String>{};
        for (final match in keyLine.allMatches(file.readAsStringSync())) {
          final key = match.group(1)!;
          scanned++;
          expect(
            seen.add(key),
            isTrue,
            reason: 'duplicate key "$key" in ${file.path}',
          );
        }
      }

      // A const map is already a compile error when a key repeats, but the
      // scan is what makes the intent explicit — and it must not pass by
      // finding nothing at all.
      expect(scanned, greaterThan(0), reason: 'key scan matched nothing');
    });

    test('matches AppStrings.supportedLanguages exactly', () {
      expect(
        byLanguage.keys.toSet(),
        AppStrings.supportedLanguages.keys.toSet(),
        reason: 'data files and supportedLanguages disagree',
      );

      AppStrings.supportedLanguages.forEach((lang, displayName) {
        expect(displayName.trim(), isNotEmpty, reason: '$lang has no label');
      });

      final fileLanguages = languageFiles()
          .map((f) => f.uri.pathSegments.last.replaceAll('.dart', ''))
          .toSet();
      expect(
        fileLanguages,
        AppStrings.supportedLanguages.keys.toSet(),
        reason: 'a language file exists that supportedLanguages does not list',
      );
    });
  });

  group('lookup', () {
    test('serves every key in every language through the public API', () {
      for (final lang in AppStrings.supportedLanguages.keys) {
        final table = byLanguage[lang];
        expect(table, isNotNull, reason: 'no table for language "$lang"');

        AppStrings.setLang(lang);
        table!.forEach((key, expected) {
          expect(
            AppStrings.get(key),
            expected,
            reason: 'AppStrings.get("$key") is wrong for "$lang"',
          );
        });
      }
    });

    test('falls back to the key name for an unknown key', () {
      expect(AppStrings.get('__no_such_key__'), '__no_such_key__');
      expect(t('__no_such_key__'), '__no_such_key__');
    });

    test('falls back to the key name for an unknown language', () {
      AppStrings.setLang('xx');
      expect(AppStrings.get('save'), 'save');
    });

    test('t() is a shorthand for AppStrings.get', () {
      for (final key in byLanguage['zh']!.keys) {
        expect(t(key), AppStrings.get(key), reason: key);
      }
    });

    test('every convenience getter resolves to a defined key', () {
      final source = facadeFile().readAsStringSync();
      final getters = RegExp(
        r"static String get (\w+)\s*=>\s*get\('([^']+)'\)",
      ).allMatches(source).toList();

      // Guard the scan itself: a getter split over two lines must still be
      // found, and a silently empty match would make the loop below vacuous.
      final declared = RegExp('static String get ').allMatches(source).length;
      expect(getters.length, declared, reason: 'getter scan missed a getter');
      expect(getters.length, greaterThan(100));

      final zh = byLanguage['zh']!;
      for (final match in getters) {
        final name = match.group(1)!;
        final key = match.group(2)!;
        expect(
          zh.containsKey(key),
          isTrue,
          reason: 'getter $name points at undefined key "$key"',
        );
        expect(
          AppStrings.get(key),
          zh[key],
          reason: 'getter $name does not resolve for "$key"',
        );
      }
    });
  });
}
