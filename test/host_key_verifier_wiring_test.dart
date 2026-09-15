import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// A tripwire over `lib/`, not over a function: **every `SshConnection`
/// construction the app makes must pass a host-key verifier**.
/// 一条覆盖 `lib/` 而非某个函数的绊线：**应用构造的每一个 `SshConnection` 都必须
/// 传入主机密钥验证回调**。
///
/// `lib/services/host_key_trust.dart` calls itself "the one place that decides
/// whether a presented host key is accepted, so every connection path in the app
/// has to go through it", and all seven call sites do so today. Nothing held
/// that. `dartssh2` treats a *null* callback as trust-anything
/// (`ssh_transport.dart`: `onVerifyHostKey != null ? onVerifyHostKey!(...) :
/// true`), so a page that omitted it would be silently machine-in-the-middle-able
/// — a security defect no test in this suite could see, arriving as an
/// ordinary-looking new file rather than as a mistake.
/// `lib/services/host_key_trust.dart` 自称「决定是否接受主机密钥的唯一入口，应用内
/// 每条连接路径都必须经过它」，而今天七处调用点确实都传了。但没有任何东西守住这一点。
/// `dartssh2` 把 **null** 回调当作无条件信任（`ssh_transport.dart`：
/// `onVerifyHostKey != null ? onVerifyHostKey!(...) : true`），因此一个漏传回调的
/// 页面会在无人察觉的情况下可被中间人攻击——这是本套件中任何测试都看不到的安全缺陷，
/// 而且它是以一个看起来很正常的新文件的形式出现，而不是以一次失误的形式出现。
///
/// A source scan is the only instrument that can see this from a unit test: the
/// guarantee is about *call sites*, which no running code observes. The scanner
/// is self-tested below, so a scan that matched nothing cannot pass for a scan
/// that found everything correct.
/// 源码扫描是单元测试中唯一能看到这一点的工具：这条保证关乎**调用点**，而任何运行的
/// 代码都观察不到调用点。下面的扫描器自带测试，因此「什么都没匹配到」的扫描不可能冒充
/// 「全部正确」的扫描。

/// The Dart files under [root].
/// [root] 之下的各个 Dart 文件。
List<File> dartSources(String root) {
  final dir = Directory(root);
  expect(dir.existsSync(), isTrue, reason: '$root is missing');
  return dir
      .listSync(recursive: true)
      .whereType<File>()
      .where((file) => file.path.endsWith('.dart'))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));
}

/// Whether [source] opens a string literal at [i], and how long its delimiter is.
/// [source] 是否在 [i] 处开启一个字符串字面量，以及其定界符的长度。
int _stringDelimiterAt(String source, int i) {
  final c = source[i];
  if (c != "'" && c != '"') return 0;
  if (i + 2 < source.length && source[i + 1] == c && source[i + 2] == c) {
    return 3;
  }
  return 1;
}

/// [source] with its comments removed, so a doc comment that merely mentions a
/// constructor cannot be mistaken for one — and so a `//` inside a string cannot
/// silently delete the rest of a real line.
/// 去掉注释后的 [source]，使仅仅提到某个构造函数的文档注释不会被误认为真正的构造，
/// 也使字符串里的 `//` 不会静默删掉真实代码行的剩余部分。
String stripComments(String source) {
  final out = StringBuffer();
  var i = 0;
  String? quote; // the open delimiter, 1 or 3 characters long

  while (i < source.length) {
    final c = source[i];

    if (quote != null) {
      if (c == r'\' && quote.length == 1) {
        out.write(source.substring(i, i + 2 <= source.length ? i + 2 : i + 1));
        i += 2;
        continue;
      }
      if (source.startsWith(quote, i)) {
        out.write(quote);
        i += quote.length;
        quote = null;
        continue;
      }
      if (c == '\n') out.write(c); // keep line numbers for the failure message
      i++;
      continue;
    }

    final delimiter = _stringDelimiterAt(source, i);
    if (delimiter > 0) {
      quote = source.substring(i, i + delimiter);
      out.write(quote);
      i += delimiter;
      continue;
    }
    if (c == '/' && source.startsWith('//', i)) {
      while (i < source.length && source[i] != '\n') {
        i++;
      }
      continue;
    }
    if (c == '/' && source.startsWith('/*', i)) {
      i += 2;
      while (i < source.length && !source.startsWith('*/', i)) {
        if (source[i] == '\n') out.write('\n');
        i++;
      }
      i += 2;
      continue;
    }

    out.write(c);
    i++;
  }
  return out.toString();
}

/// The text between the parentheses of the call that opens at [open] — nested
/// calls, strings and all.
/// 在 [open] 处开启的调用的圆括号之间的文本——嵌套调用与字符串都算在内。
String argumentList(String source, int open) {
  var depth = 0;
  String? quote;
  var i = open;

  while (i < source.length) {
    final c = source[i];

    if (quote != null) {
      if (c == r'\' && quote.length == 1) {
        i += 2;
        continue;
      }
      if (source.startsWith(quote, i)) {
        i += quote.length;
        quote = null;
        continue;
      }
      i++;
      continue;
    }

    final delimiter = _stringDelimiterAt(source, i);
    if (delimiter > 0) {
      quote = source.substring(i, i + delimiter);
      i += delimiter;
      continue;
    }
    if (c == '(') depth++;
    if (c == ')') {
      depth--;
      if (depth == 0) return source.substring(open + 1, i);
    }
    i++;
  }
  return '';
}

/// One `SshConnection` construction: where it is, and what it passes.
/// 一处 `SshConnection` 构造：位置，以及它传入了什么。
class Construction {
  Construction(this.line, this.args);

  /// 1-based line of the construction in the scanned source.
  /// 该构造在被扫描源码中的行号（从 1 开始）。
  final int line;

  /// The text between the call's parentheses.
  /// 该调用圆括号之间的文本。
  final String args;

  /// Whether a host-key verifier is among the arguments.
  /// 参数中是否包含主机密钥验证回调。
  bool get passesVerifier =>
      args.contains('onHostKeyVerify:') ||
      args.contains('onHostKeyVerifyTyped:');

  @override
  String toString() =>
      'line $line: SshConnection(${args.trim().split('\n').first.trim()} …)';
}

/// Every `SshConnection` construction in [source] — the constructor's own
/// declaration is not one.
/// [source] 中的每一处 `SshConnection` 构造——构造函数自身的声明不算。
List<Construction> constructionsIn(String source) {
  final code = stripComments(source);
  final found = <Construction>[];
  final declaration = RegExp(r'\bSshConnection\(');

  for (final match in declaration.allMatches(code)) {
    // `SshConnection({` declares the constructor in ssh_service.dart. A call
    // site passes named arguments, so a brace is never the first thing inside a
    // call's parentheses.
    // ssh_service.dart 中的 `SshConnection({` 是构造函数声明。调用点传的是具名参数，
    // 因此调用圆括号内的第一个字符绝不会是花括号。
    if (code.substring(match.end).trimLeft().startsWith('{')) continue;

    final args = argumentList(code, match.end - 1);
    final line = '\n'.allMatches(code.substring(0, match.start)).length + 1;
    found.add(Construction(line, args));
  }
  return found;
}

/// Every construction in [source] that passes no verifier.
/// [source] 中所有未传入验证回调的构造。
List<String> unverifiedConstructions(String source) => constructionsIn(
  source,
).where((construction) => !construction.passesVerifier).map((c) => '$c').toList();

/// What was refused, and why, in the words the reader of a failure needs.
/// 被拒绝的做法及其原因，用失败信息的读者需要的措辞写出。
String get whyItMatters =>
    'dartssh2 treats a null host-key callback as trust-anything '
    '(ssh_transport.dart: `onVerifyHostKey != null ? onVerifyHostKey!(…) : '
    'true`), so this connection would silently accept any host key a '
    'machine-in-the-middle offered, and the rest of this suite would stay '
    'green. Pass `onHostKeyVerify: buildHostKeyVerifier(…)` — see '
    'lib/services/host_key_trust.dart.';

void main() {
  group('the scanner itself', () {
    // Without these, a scan that matched nothing would look exactly like a scan
    // that found every call site correct.
    // 没有这些测试，什么都没匹配到的扫描与「所有调用点都正确」的扫描看起来完全一样。

    test('flags a construction with no verifier, and says where', () {
      const source = '''
        final conn = SshConnection(
          host: host,
          credential: cred,
          connectTimeout: timeout,
        );

        final second = SshConnection(
          host: host,
          onHostKeyVerify: buildHostKeyVerifier(db: db, address: a, port: p),
        );

        final third = SshConnection(host: h, credential: c);
      ''';
      // The flagged lines are reported so that a failure names the place; the
      // compliant construction between them is not flagged.
      // 被标记的行号会一并报告，好让失败信息指出具体位置；两次之间那处合规的构造不会
      // 被标记。
      expect(unverifiedConstructions(source), [
        startsWith('line 1:'),
        startsWith('line 12:'),
      ]);
    });

    test('accepts one that passes either verifier', () {
      const source = '''
        final a = SshConnection(
          host: host,
          onHostKeyVerify: buildHostKeyVerifier(db: db, address: a, port: p),
        );
        final b = SshConnection(
          host: host,
          onHostKeyVerifyTyped: buildHostKeyVerifier(
            db: db, address: a, port: p,
          ),
        );
      ''';
      expect(unverifiedConstructions(source), isEmpty);
    });

    test('does not mistake the declaration for a call site', () {
      // `SshConnection({` in ssh_service.dart declares the constructor; a false
      // positive there would make this tripwire impossible to keep green, and a
      // tripwire everyone learns to ignore protects nothing.
      // ssh_service.dart 中的 `SshConnection({` 是构造函数声明；在那里误报会让这条
      // 绊线永远无法保持绿色，而一条人人都学会忽略的绊线保护不了任何东西。
      const source = '''
        SshConnection({
          required this.host,
          required this.credential,
        });
      ''';
      expect(unverifiedConstructions(source), isEmpty);
    });

    test('ignores mentions in comments', () {
      const source = '''
        // Every path builds an SshConnection(host: h) through the verifier.
        /* was: SshConnection(host: h, credential: c) */
        final c = SshConnection(
          host: h,
          onHostKeyVerify: buildHostKeyVerifier(db: db, address: a, port: 1),
        );
      ''';
      expect(unverifiedConstructions(source), isEmpty);
    });

    test('sees through nested calls and strings', () {
      // The argument list is brace-counted with string awareness, so a nested
      // call or a stray bracket inside a string cannot end it early — and a
      // `//` inside a string cannot truncate the line it sits on.
      // 参数列表按括号计数并识别字符串，因此嵌套调用或字符串里多出来的括号都不会让它
      // 提前结束，字符串里的 `//` 也不会截断它所在的行。
      const source = """
        final url = 'https://example.invalid/x';
        final conn = SshConnection(
          host: host,
          // A comment with a stray bracket ( must not count either.
          credential: cred,
          onHostKeyVerify: buildHostKeyVerifier(
            db: db,
            onPrompt: (f, v) async => show('(not a bracket'),
          ),
        );
      """;
      expect(unverifiedConstructions(source), isEmpty);

      const missing = """
        final conn = SshConnection(host: host, credential: cred);
      """;
      expect(unverifiedConstructions(missing), hasLength(1));
    });
  });

  test('every SshConnection in lib/ passes a host key verifier', () {
    final offenders = <String>[];
    var scanned = 0;
    var constructions = 0;

    for (final file in dartSources('lib')) {
      scanned++;
      final found = constructionsIn(file.readAsStringSync());
      constructions += found.length;
      offenders.addAll(
        found
            .where((construction) => !construction.passesVerifier)
            .map((construction) => '${file.path} $construction'),
      );
    }

    expect(scanned, greaterThan(20), reason: 'the scan read almost nothing');
    // Without this the test would pass by finding nothing, which is the failure
    // mode of every source scan. Zero constructions means either the app no
    // longer opens connections directly — in which case this tripwire has to
    // move to whatever replaced them — or the scan has gone blind.
    // 没有这一条，本测试会因「什么都没找到」而通过，而这是所有源码扫描的失效方式。
    // 零处构造意味着：要么应用不再直接打开连接（那么这条绊线必须迁移到取而代之的
    // 地方），要么扫描已经失明。
    expect(
      constructions,
      greaterThan(0),
      reason:
          'no SshConnection construction was found anywhere in lib/ — this '
          'tripwire is not watching anything',
    );
    expect(
      offenders,
      isEmpty,
      reason:
          'a connection is built without a host-key verifier:\n'
          '${offenders.join('\n')}\n\n$whyItMatters',
    );
  });

  test('no production code uses the accept-anything verifier', () {
    // `acceptAnyHostKeyForTesting` documents itself as test-and-mock only,
    // "named so that a reviewer can grep for it: any production call site is a
    // bug". This is that grep, run on every test run.
    // `acceptAnyHostKeyForTesting` 自我声明仅用于测试与 mock，「特意取了这个名字，
    // 方便审查时直接搜索：任何生产代码里出现它都是缺陷」。本条就是那次搜索，只是每次
    // 测试都会执行。
    final files = <String>[];
    for (final file in dartSources('lib')) {
      if (stripComments(file.readAsStringSync()).contains(
        'acceptAnyHostKeyForTesting',
      )) {
        files.add(file.path);
      }
    }

    expect(
      files,
      ['lib/services/host_key_trust.dart'],
      reason:
          'the accept-anything verifier may be defined in exactly one place '
          '(its own definition) and used nowhere else in lib/ — every other '
          'mention of it in production code is a connection that trusts any '
          'host key',
    );
  });
}
