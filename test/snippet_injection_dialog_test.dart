import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neko_mux/core/i18n/strings.dart';
import 'package:neko_mux/pages/snippet_injection_dialog.dart';

/// [SnippetInjectionDialog] builds its `TextEditingController`s up front and
/// releases them once `showDialog`'s future completes. That placement is what
/// the add/edit snippet dialog got wrong — it released the controllers too
/// early and the fields rebuilt into them as the dialog animated out. These
/// tests check the path the injection dialog actually takes, so its release
/// point is verified rather than assumed.
/// [SnippetInjectionDialog] 先建好 `TextEditingController`，再在 `showDialog` 的
/// future 完成时释放它们。新增/编辑快捷指令的对话框恰恰是在这里出的错——它释放得太
/// 早，退场动画期间输入框重建时又碰到了它们。下面的测试走的是注入对话框实际的路径，
/// 因此它的释放时机是被验证过的，而不是被假定的。

/// Opens the dialog from a plain button. The list returned is filled in with
/// the value the dialog pops with, once it does — the dialog outlives this
/// call, so the result cannot be returned by value.
/// 从一个普通按钮打开对话框。返回的列表会在对话框弹出后填入其结果——对话框比本次
/// 调用存活得更久，因此结果无法按值返回。
Future<List<String?>> _openDialog(
  WidgetTester tester, {
  required String command,
}) async {
  final injected = <String?>[];
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              injected.add(await SnippetInjectionDialog.show(context, command));
            },
            child: const Text('go'),
          ),
        ),
      ),
    ),
  );

  await tester.tap(find.text('go'));
  await tester.pumpAndSettle();
  return injected;
}

/// Observes the lifetime of the editors and focus nodes created while it is
/// installed. The same instrument `snippet_dialog_test.dart` uses, extended to
/// [FocusNode]s.
/// 观察安装期间创建的编辑器与焦点节点的生命周期，即 `snippet_dialog_test.dart`
/// 所用的同一套仪器，扩展到 [FocusNode]。
///
/// It is what makes "the dialog releases what it built" observable at all:
/// deleting `dispose()` from the injection dialog leaves the fields gone from
/// the tree and no exception thrown, so the assertions on the widget tree
/// cannot see the leak.
/// 它让「对话框释放了自己创建的东西」真正可观测：把 `dispose()` 从注入对话框删掉
/// 后，输入框照样从树中消失、也不会抛出异常，因此对控件树的断言看不到这次泄漏。
class _ObjectLifetimes {
  final Set<Object> _controllersCreated = <Object>{};
  final Set<Object> _disposed = <Object>{};

  void _track(ObjectEvent event) {
    final object = event.object;
    if (object is! TextEditingController && object is! FocusNode) return;

    if (event is ObjectDisposed) {
      _disposed.add(object);
    } else if (event is ObjectCreated && object is TextEditingController) {
      // Only the controllers are counted: the framework creates focus nodes of
      // its own (shortcuts, traversal groups, the route's scope), so a count of
      // them would be counting Flutter. Their disposal is asserted by identity
      // below instead.
      // 只统计控制器：框架自己会创建焦点节点（快捷键、遍历组、路由作用域），统计
      // 它们等于在统计 Flutter。它们的释放改由下方按同一性断言。
      _controllersCreated.add(object);
    }
  }

  void start() => FlutterMemoryAllocations.instance.addListener(_track);

  void stop() => FlutterMemoryAllocations.instance.removeListener(_track);

  /// Text controllers created since [start].
  /// 自 [start] 以来创建的文本控制器。
  Set<Object> get controllersCreated => _controllersCreated;

  /// Controllers created since [start] and never released.
  /// 自 [start] 以来创建且从未被释放的控制器。
  Set<Object> get leakedControllers =>
      _controllersCreated.difference(_disposed);

  /// Whether [object] has been released since [start].
  /// [object] 自 [start] 以来是否已被释放。
  bool wasDisposed(Object object) => _disposed.contains(object);
}

void main() {
  setUp(() => AppStrings.setLang('en'));
  tearDown(() => AppStrings.setLang('zh'));

  testWidgets('substitutes the typed values into the command', (tester) async {
    final injected = await _openDialog(tester, command: 'ls [dir] [user]');
    expect(find.text('dir'), findsOneWidget);
    expect(find.text('user'), findsOneWidget);

    await tester.enterText(find.byType(TextFormField).first, '/tmp');
    await tester.enterText(find.byType(TextFormField).last, 'root');
    await tester.pump();

    await tester.tap(find.text(t('inject')));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(injected, ['ls /tmp root']);
  });

  testWidgets('returns the command unchanged when it has no placeholders', (
    tester,
  ) async {
    final injected = await _openDialog(tester, command: 'uptime');
    expect(find.byType(TextFormField), findsNothing);
    expect(injected, ['uptime']);
  });

  testWidgets('closes cleanly when the user cancels', (tester) async {
    final lifetimes = _ObjectLifetimes();
    lifetimes.start();
    addTearDown(lifetimes.stop);

    await _openDialog(tester, command: 'ls [dir] [user]');

    /// The editors and focus nodes the dialog handed to its own fields, read
    /// off the tree while it is open. Taken by identity so the assertion below
    /// is about exactly those objects, and not about the framework's own focus
    /// nodes happening to come and go.
    /// 对话框交给自己输入框的编辑器与焦点节点，在它打开时从控件树上读取。按同一性
    /// 取得，因此下面的断言恰好针对这些对象，而不是框架自己那些来去不定的焦点节点。
    final fields = tester.widgetList<TextField>(find.byType(TextField)).toList();
    expect(fields, hasLength(2), reason: 'one field per placeholder');
    final owned = <Object>[
      ...fields.map((field) => field.controller!),
      ...fields.map((field) => field.focusNode!),
    ];

    /// Type into the fields first: an untouched field never exercises the
    /// controller on the way out.
    /// 先往输入框里输内容：从未被碰过的输入框在退场时不会走到控制器。
    await tester.enterText(find.byType(TextFormField).first, '/tmp');
    await tester.enterText(find.byType(TextFormField).last, 'root');
    await tester.pump();

    await tester.tap(find.text(t('cancel')));
    await tester.pumpAndSettle();

    expect(find.byType(TextFormField), findsNothing);
    expect(tester.takeException(), isNull);

    // The fields leaving the tree is not the same as the dialog releasing what
    // it built: deleting `dispose()` from the dialog keeps the two assertions
    // above green while leaking every editor and focus node on every close.
    // 输入框离开控件树，并不等于对话框释放了自己创建的东西：把 `dispose()` 从对话
    // 框里删掉，上面两条断言照样通过，而每次关闭都会泄漏全部编辑器与焦点节点。
    expect(
      lifetimes.controllersCreated,
      hasLength(2),
      reason: 'the dialog owns one controller per placeholder — if this sees '
          'none, the leak check below is vacuous',
    );
    expect(
      lifetimes.leakedControllers,
      isEmpty,
      reason: 'the dialog left controllers alive after it closed',
    );
    for (final object in owned) {
      expect(
        lifetimes.wasDisposed(object),
        isTrue,
        reason:
            'a ${object.runtimeType} the dialog created was never released — '
            'dispose() is what keeps a rebuild during the exit animation from '
            'reaching a dead editor',
      );
    }
  });
}
