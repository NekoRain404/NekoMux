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

    // There was a test here that scanned the language files for a duplicate
    // key. It could not fail: every table is a `const Map<String, String>`
    // literal, and a repeated key in a const map literal is a **compile
    // error** — the failing state does not compile, so no run of this suite
    // ever observes it. The compiler owns that rule; a test that only restates
    // it manufactures confidence instead of adding any.
    // 这里原有一条扫描语言文件、检查键重复的测试，它无法失败：每张表都是
    // `const Map<String, String>` 字面量，而 const map 中重复的键是**编译错误**
    // ——失败状态根本无法编译，因此本测试套件的任何一次运行都观察不到它。这条规则
    // 属于编译器；只把它复述一遍的测试不会增加任何约束，只会制造虚假的把握。

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

    test('t() answers with the active language\'s own table value', () {
      // `t` is defined as `AppStrings.get`, so asserting `t(key) ==
      // AppStrings.get(key)` compares a thing with itself and holds for any
      // implementation of `t` that nobody touched. What a caller can actually
      // observe is the value that comes back, against the language's own
      // table: it must be that table's entry, and it must change when the
      // language does.
      // `t` 就定义为 `AppStrings.get`，因此断言 `t(key) == AppStrings.get(key)`
      // 是拿一个东西和它自己比，只要没人改动 `t` 就恒成立。调用方真正能观察到的是
      // 返回值本身：它必须是**当前语言**表里的那一条，并且随语言切换而变化。
      for (final lang in AppStrings.supportedLanguages.keys) {
        AppStrings.setLang(lang);
        expect(t('save'), byLanguage[lang]!['save'], reason: lang);
        expect(t('conn_timeout'), byLanguage[lang]!['conn_timeout'], reason: lang);
      }

      // The documented fallback, through the same entry point.
      expect(t('__no_such_key__'), '__no_such_key__');
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
