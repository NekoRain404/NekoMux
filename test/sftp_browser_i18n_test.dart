import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neko_mux/core/i18n/strings.dart';
import 'package:neko_mux/models/file_item.dart';
import 'package:neko_mux/pages/sftp/sftp_bars.dart';
import 'package:neko_mux/pages/sftp/sftp_dialogs.dart';
import 'package:neko_mux/pages/sftp/sftp_file_list.dart';

/// The file browser as an English user sees it.
/// 英文用户看到的文件浏览器。
///
/// The other tests in this area check the building blocks; this one renders the
/// actual widgets the page composes and reads every string back out of the tree,
/// so a label that never reaches the i18n table at all — which is how '文件夹'
/// and '列表读取失败：…' shipped to English users — fails here rather than in a
/// screenshot nobody looked at.
/// 这一带的其它测试检查的是零件；本测试渲染页面真正组合出来的 widget，并把树里的每个
/// 字符串读回来。因此，一个根本没进 i18n 表的标签——「文件夹」和「列表读取失败：…」
/// 当年就是这样到达英文用户眼前的——会在这里失败，而不是在一张没人看的截图里失败。

/// CJK text and CJK/full-width punctuation.
/// 中日韩文字与 CJK／全角标点。
/// U+3000–U+303F, U+4E00–U+9FFF, U+FF00–U+FFEF.
final cjk = RegExp('[\\u3000-\\u303f\\u4e00-\\u9fff\\uff00-\\uffef]');

FileItem item(String name, {bool isDirectory = false, int size = 0}) =>
    FileItem(
      name: name,
      path: '/var/$name',
      isDirectory: isDirectory,
      size: size,
      permissions: 'rw-r--r--',
      modifiedDate: DateTime(2026, 1, 1),
    );

/// The directory the tests browse: one of every label the list can produce.
/// 测试浏览的目录：列表能产生的每一种标签各一个。
final entries = <FileItem>[
  item('logs', isDirectory: true),
  item('index.html', size: 2048),
  item('deploy.py', size: 100),
  item('backup.tar.gz', size: 4096),
  item('photo.png', size: 10),
  item('syslog.log', size: 5),
  item('nginx.conf', size: 7),
  item('lib.rs', size: 3), // the un-translated fallback / 非翻译的兜底显示
];

/// Every string the widget tree is currently showing.
/// 当前 widget 树中显示的所有字符串。
List<String> renderedText(WidgetTester tester) => tester
    .widgetList<Text>(find.byType(Text))
    .map((text) => text.data ?? '')
    .toList();

/// Fails when any rendered string contains CJK.
/// 任一渲染出的字符串含中日韩文字时失败。
void expectNoCjk(List<String> texts) {
  expect(
    texts,
    isNotEmpty,
    reason: 'nothing was rendered — the check is vacuous',
  );
  for (final text in texts) {
    final hit = cjk.firstMatch(text);
    expect(hit, isNull, reason: '"${hit?.group(0)}" in: $text');
  }
}

void main() {
  // The active language is global mutable state; every test here picks its own
  // and leaves the default behind.
  setUp(() => AppStrings.setLang('en'));
  tearDown(() => AppStrings.setLang('zh'));

  testWidgets('the path bar, list and selection bar render in English', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              SftpBreadcrumbBar(
                labels: const ['Root', 'var', 'log'],
                isSelectionMode: false,
                onCancelSelection: () {},
                onCrumbTap: (_) {},
              ),
              Expanded(
                child: SftpFileList(
                  files: entries,
                  isLoading: false,
                  isSelectionMode: false,
                  selectedPaths: const {},
                  onOpenDirectory: (_) {},
                  onTapFile: (_) {},
                  onShowFileActions: (_) {},
                  onToggleSelection: (_) {},
                  onEnterSelectionMode: (_) {},
                  onCreateEntry: () {},
                ),
              ),
              SftpSelectionBar(
                selectedCount: 2,
                onDelete: () {},
                onCancel: () {},
              ),
            ],
          ),
        ),
      ),
    );

    final texts = renderedText(tester);

    // The labels this test exists for, spelled out so a passing run cannot be
    // one that rendered nothing but file names.
    // 本测试真正关心的标签在此写死，避免「只渲染了文件名」的空跑也算通过。
    expect(texts, contains('HTML document'));
    expect(texts, contains('Python script'));
    expect(texts, contains('Archive'));
    expect(texts, contains('Image'));
    expect(texts, contains('Log file'));
    expect(texts, contains('Config file'));
    expect(texts, contains('2 selected'));

    expectNoCjk(texts);

    // `lib.rs` is the last row and sits below the fold in the test viewport;
    // scroll it up so the un-translated fallback is covered too.
    // `lib.rs` 是最后一行，在测试视口里位于折叠线以下；向上滚动以便覆盖未翻译的
    // 兜底显示。
    await tester.drag(find.byType(ListView), const Offset(0, -400));
    await tester.pumpAndSettle();

    final scrolled = renderedText(tester);
    expect(scrolled, contains('RS'));
    expectNoCjk(scrolled);
  });

  testWidgets('the batch-delete confirmation lists names, not 、', (
    tester,
  ) async {
    late BuildContext context;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (ctx) {
            context = ctx;
            return const SizedBox();
          },
        ),
      ),
    );

    final answer = confirmSftpBatchDelete(context, [
      '/var/a.txt',
      '/var/log/b.log',
      '/etc/c.conf',
    ]);
    await tester.pumpAndSettle();

    final message = renderedText(tester).join('\n');
    expect(message, contains('a.txt, b.log, c.conf'));
    expect(message.contains('、'), isFalse, reason: 'ideographic comma');
    expectNoCjk(renderedText(tester));

    await tester.tap(find.text(t('cancel')));
    await tester.pumpAndSettle();
    expect(await answer, isFalse);
  });

  testWidgets('the file actions sheet names the type in English', (
    tester,
  ) async {
    late BuildContext context;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (ctx) {
            context = ctx;
            return const SizedBox();
          },
        ),
      ),
    );

    final answer = showSftpFileActions(
      context,
      item('napisy.html', size: 2048),
      canOpenFile: true,
    );
    await tester.pumpAndSettle();

    final texts = renderedText(tester);
    expect(texts, contains('2.0 KB · HTML document · rw-r--r--'));
    expectNoCjk(texts);

    await tester.tap(find.text(t('delete')));
    await tester.pumpAndSettle();
    expect(await answer, SftpFileAction.delete);
  });
}
