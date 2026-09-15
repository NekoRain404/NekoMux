import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neko_mux/core/i18n/strings.dart';
import 'package:neko_mux/models/snippet.dart';
import 'package:neko_mux/pages/snippet_list_page.dart';
import 'package:neko_mux/providers/providers.dart';

/// The add/edit snippet dialog creates a `TextEditingController` per field on
/// every invocation. They used to be created and never released, so each open —
/// on any of the four ways out of the dialog — leaked the controllers along
/// with everything typed into them.
/// 新增/编辑快捷指令的对话框每次调用都为每个输入框新建一个 `TextEditingController`，
/// 过去只创建、从不释放：无论以四种方式中的哪一种退出，每次打开都会连同用户输入过的
/// 文本一起泄漏这些控制器。

/// Snippet notifier serving a fixed list and recording insertions, so the tests
/// never touch the database.
/// 返回固定列表并记录新增操作的快捷指令通知器，测试因此不接触数据库。
class _FixedSnippets extends SnippetListNotifier {
  _FixedSnippets(this.rows);

  final List<Snippet> rows;

  @override
  Future<List<Snippet>> build() async => rows;

  @override
  Future<void> addItem(Snippet snippet) async => added.add(snippet);
}

/// Snippets passed to `addItem` since the last reset.
/// 自上次重置以来传给 `addItem` 的快捷指令。
final List<Snippet> added = <Snippet>[];

Widget _app() {
  return ProviderScope(
    overrides: [
      snippetListProvider.overrideWith(() => _FixedSnippets(const <Snippet>[])),
    ],
    child: const MaterialApp(home: SnippetListPage()),
  );
}

/// Opens the add-snippet dialog and types into both fields.
/// 打开新增快捷指令对话框，并在两个输入框中输入内容。
Future<void> _openDialog(WidgetTester tester) async {
  await tester.tap(find.text(t('add')));
  await tester.pumpAndSettle();
  await tester.enterText(find.byType(TextFormField).first, 'deploy');
  await tester.enterText(find.byType(TextFormField).last, 'make deploy');
  await tester.pump();
}

/// Counts the `TextEditingController`s that are created while it is installed
/// and still alive when it is removed.
/// 统计在安装期间创建、到移除时仍然存活的 `TextEditingController` 数量。
class _ControllerLeaks {
  final Set<Object> _created = <Object>{};
  final Set<Object> _disposed = <Object>{};
  int _seen = 0;

  void _track(ObjectEvent event) {
    if (event.object is! TextEditingController) return;
    if (event is ObjectCreated) {
      _created.add(event.object);
      _seen++;
    } else if (event is ObjectDisposed) {
      _disposed.add(event.object);
    }
  }

  void start() => FlutterMemoryAllocations.instance.addListener(_track);

  void stop() => FlutterMemoryAllocations.instance.removeListener(_track);

  /// Controllers created since [start], which are the ones this test owns.
  /// 自 [start] 以来创建的控制器，即本测试负责的那些。
  Set<Object> get created => _created;

  Set<Object> get leaked => _created.difference(_disposed);

  int get seen => _seen;
}

void main() {
  setUp(() {
    AppStrings.setLang('en');
    added.clear();
  });
  tearDown(() => AppStrings.setLang('zh'));

  testWidgets('releases the controllers when the dialog is cancelled', (
    tester,
  ) async {
    final leaks = _ControllerLeaks();
    leaks.start();
    addTearDown(leaks.stop);

    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();
    await _openDialog(tester);

    await tester.tap(find.text(t('cancel')));
    await tester.pumpAndSettle();

    expect(find.byType(TextFormField), findsNothing);
    expect(tester.takeException(), isNull);

    expect(
      leaks.created,
      hasLength(2),
      reason: 'the dialog owns one controller per field',
    );
    expect(
      leaks.leaked,
      isEmpty,
      reason: 'the dialog left controllers alive after it closed',
    );
  });

  testWidgets('releases the controllers when the snippet is saved', (
    tester,
  ) async {
    final leaks = _ControllerLeaks();
    leaks.start();
    addTearDown(leaks.stop);

    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();
    await _openDialog(tester);

    await tester.tap(find.text(t('save')));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(leaks.created, hasLength(2));
    expect(leaks.leaked, isEmpty);
  });

  testWidgets('releases them on every opening, not just the first', (
    tester,
  ) async {
    final leaks = _ControllerLeaks();
    leaks.start();
    addTearDown(leaks.stop);

    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();

    for (var i = 0; i < 3; i++) {
      await _openDialog(tester);
      await tester.tap(find.text(t('cancel')));
      await tester.pumpAndSettle();
    }

    expect(leaks.created, hasLength(6));
    expect(leaks.leaked, isEmpty);
  });

  testWidgets('still saves what was typed', (tester) async {
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();
    await _openDialog(tester);

    await tester.tap(find.text(t('save')));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(added, hasLength(1));
    expect(added.single.title, 'deploy');
    expect(added.single.command, 'make deploy');
  });

  testWidgets('still refuses an empty form', (tester) async {
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();

    await tester.tap(find.text(t('add')));
    await tester.pumpAndSettle();
    await tester.tap(find.text(t('save')));
    await tester.pumpAndSettle();

    expect(find.byType(TextFormField), findsNWidgets(2));
    expect(added, isEmpty);
    expect(find.text(t('must_enter_snippet_title')), findsOneWidget);
    expect(find.text(t('must_enter_snippet_command')), findsOneWidget);
  });
}
