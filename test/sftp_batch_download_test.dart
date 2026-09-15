import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neko_mux/core/i18n/strings.dart';
import 'package:neko_mux/models/file_item.dart';
import 'package:neko_mux/models/transfer_task.dart';
import 'package:neko_mux/pages/sftp/file_selection.dart';
import 'package:neko_mux/pages/sftp/sftp_bars.dart';
import 'package:neko_mux/pages/transfer/transfer_actions.dart';
import 'package:neko_mux/pages/transfer/transfer_format.dart';
import 'package:neko_mux/pages/transfer/transfer_indicator.dart';
import 'package:neko_mux/pages/transfer/transfer_io.dart';
import 'package:neko_mux/providers/transfer_provider.dart';
import 'package:neko_mux/services/transfer_runner.dart';

import 'transfer_fake_session.dart';

/// Downloading a whole selection from the file manager.
/// 从文件管理器下载整个选中集。
///
/// The pieces are tested where they can be read: the plan is a pure function of a
/// listing and a set of ticked paths, the bar is a widget, and what a batch does
/// to the queue is checked against the real queue with a session that never opens
/// — so nothing here needs a server, and nothing here races one either.
/// 各个零件都在能读懂它们的地方测试：方案是「一份列表 + 一组已勾选路径」的纯函数，操作栏
/// 是一个控件，而批量对队列做了什么，则用一条永不打开的会话对着**真实**队列检验——因此
/// 这里既不需要服务器，也不会与服务器赛跑。

FileItem item(String name, {bool isDirectory = false, int size = 1024}) =>
    FileItem(
      name: name,
      path: '/var/$name',
      isDirectory: isDirectory,
      size: size,
      permissions: 'rw-r--r--',
      modifiedDate: DateTime(2026, 1, 1),
    );

/// CJK text and CJK/full-width punctuation.
/// 中日韩文字与 CJK／全角标点。
final cjk = RegExp('[\\u3000-\\u303f\\u4e00-\\u9fff\\uff00-\\uffef]');

/// A page-less caller of the queueing helpers, standing in for the SFTP page.
/// 一个不依赖页面、代表 SFTP 页面调用入队辅助函数的调用方。
class _Harness extends ConsumerWidget {
  const _Harness({required this.run});

  final void Function(WidgetRef ref) run;

  @override
  Widget build(BuildContext context, WidgetRef ref) => TextButton(
    onPressed: () => run(ref),
    child: const Text('go'),
  );
}

/// A container whose queue can be filled but never runs: its session never
/// opens, so the tasks stay exactly as they were enqueued.
/// 一个可以装入任务却永不运行它们的容器：会话永不打开，因此任务保持入队时的样子。
ProviderContainer idleContainer() => ProviderContainer.test(
  overrides: [
    transferSessionFactoryProvider.overrideWithValue(
      (String hostId) => Completer<TransferSession>().future,
    ),
  ],
);

TransferTask download(
  String path, {
  TransferStatus status = TransferStatus.done,
  String name = 'staged.bin',
}) => TransferTask(
  id: 't',
  hostId: 'h1',
  name: name,
  remotePath: '/var/$name',
  localPath: path,
  direction: TransferDirection.download,
  status: status,
);

void main() {
  useTransferTempDir();

  setUp(() => AppStrings.setLang('en'));
  tearDown(() => AppStrings.setLang('zh'));

  group('what a batch can carry', () {
    final entries = <FileItem>[
      item('logs', isDirectory: true),
      item('access.log'),
      item('error.log'),
    ];

    test('takes the ticked files, in the order the list shows', () {
      final plan = BatchDownloadPlan.of(entries, {
        '/var/error.log',
        '/var/access.log',
      });

      expect(plan.files.map((f) => f.name), ['access.log', 'error.log']);
      expect(plan.skipped, 0);
    });

    test('a ticked directory is counted rather than queued', () {
      final plan = BatchDownloadPlan.of(entries, {
        '/var/logs',
        '/var/access.log',
      });

      expect(plan.files.map((f) => f.name), ['access.log']);
      expect(
        plan.skipped,
        1,
        reason: 'the queue walks nothing, so a directory cannot be a task',
      );
    });

    test('a ticked path the refresh removed is counted too', () {
      final plan = BatchDownloadPlan.of(entries, {
        '/var/access.log',
        '/var/deleted-elsewhere.txt',
      });

      expect(plan.files.map((f) => f.name), ['access.log']);
      expect(plan.skipped, 1);
    });

    test('nothing ticked is nothing to queue, and nothing left out', () {
      final plan = BatchDownloadPlan.of(entries, const <String>{});
      expect(plan.files, isEmpty);
      expect(plan.skipped, 0);
    });
  });

  group('the batch action in the bar', () {
    Future<void> pumpBar(
      WidgetTester tester, {
      required int selected,
      required int files,
      required VoidCallback onDownload,
      required VoidCallback onDelete,
    }) => tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SftpSelectionBar(
            selectedCount: selected,
            fileCount: files,
            onDownload: onDownload,
            onDelete: onDelete,
            onCancel: () {},
          ),
        ),
      ),
    );

    /// The button carrying [label].
    /// 带有 [label] 的按钮。
    TextButton buttonWith(WidgetTester tester, String label) =>
        tester.widget<TextButton>(
          find.ancestor(
            of: find.text(label),
            matching: find.byType(TextButton),
          ),
        );

    testWidgets('names the count of files it will queue', (tester) async {
      await pumpBar(
        tester,
        selected: 4,
        files: 3,
        onDownload: () {},
        onDelete: () {},
      );

      expect(find.text(t('selected_count').replaceAll('{0}', '4')), findsOne);
      expect(find.text('${t('download')} (3)'), findsOneWidget);
      expect(find.text(t('batch_delete')), findsOneWidget);
      expect(find.text(t('cancel')), findsOneWidget);
    });

    testWidgets('reports the download tap, and delete stays separate', (
      tester,
    ) async {
      var downloads = 0;
      var deletes = 0;
      await pumpBar(
        tester,
        selected: 2,
        files: 2,
        onDownload: () => downloads++,
        onDelete: () => deletes++,
      );

      await tester.tap(find.text('${t('download')} (2)'));
      await tester.pumpAndSettle();
      expect(downloads, 1);
      expect(deletes, 0, reason: 'the two actions are not the same action');

      await tester.tap(find.text(t('batch_delete')));
      await tester.pumpAndSettle();
      expect(deletes, 1);
    });

    testWidgets('offers no download when the selection holds no file', (
      tester,
    ) async {
      var downloads = 0;
      var deletes = 0;
      await pumpBar(
        tester,
        selected: 1,
        files: 0,
        onDownload: () => downloads++,
        onDelete: () => deletes++,
      );

      expect(
        buttonWith(tester, '${t('download')} (0)').onPressed,
        isNull,
        reason: 'a folder-only selection has nothing this queue can carry',
      );
      // Delete still acts on it: it removes remote paths and needs no entry.
      expect(buttonWith(tester, t('batch_delete')).onPressed, isNotNull);

      await tester.tap(find.text('${t('download')} (0)'));
      await tester.pumpAndSettle();
      expect(downloads, 0);
    });
  });

  group('queueing a batch', () {
    testWidgets('one task per ticked file, each with its own staged copy', (
      tester,
    ) async {
      final container = idleContainer();
      final plan = BatchDownloadPlan.of(
        [
          item('logs', isDirectory: true),
          item('access.log', size: 4096),
          item('error.log', size: 512),
        ],
        {'/var/logs', '/var/access.log', '/var/error.log'},
      );
      late BatchDownloadResult result;
      // Read inside the tap handler, before any pump: what it proves is that
      // queueing has no `await` in it, which is what keeps a huge selection from
      // costing the frame that handled the tap.
      // 在处理函数内部、任何 pump 之前读取：它证明的是入队过程中没有 `await`——正是
      // 这一点让一个巨大的选中集不会花掉处理点击的那一帧。
      late int countDuringTap;

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: Scaffold(
              body: _Harness(
                run: (ref) {
                  result = queueBatchDownloadToStaging(
                    ref,
                    hostId: 'h1',
                    files: plan.files,
                  );
                  countDuringTap = ref.read(transferQueueProvider).length;
                },
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('go'));
      await tester.pump();

      expect(plan.skipped, 1, reason: 'the directory is left behind, counted');
      expect(result.queued, 2);
      expect(result.outcome, TransferQueueOutcome.queued);
      expect(
        countDuringTap,
        2,
        reason: 'the tasks are in the queue before the handler returns',
      );

      final tasks = container.read(transferQueueProvider);
      expect(tasks.map((task) => task.name), ['access.log', 'error.log']);
      expect(
        tasks.every((task) => task.direction == TransferDirection.download),
        isTrue,
      );
      expect(tasks.every((task) => task.hostId == 'h1'), isTrue);
      expect(tasks[0].remotePath, '/var/access.log');
      expect(tasks[0].totalBytes, 4096);
      final paths = tasks.map((task) => task.localPath).toList();
      expect(paths.toSet().length, 2, reason: 'two transfers must not collide');
      for (final path in paths) {
        expect(path, startsWith(transferStagingDirectory().path));
      }
      expect(
        tasks.any((task) => task.remotePath == '/var/logs'),
        isFalse,
        reason: 'a directory is not a task this queue can run',
      );
    });

    testWidgets('the transfer indicator shows the batch without being told', (
      tester,
    ) async {
      final container = idleContainer();
      final files = [item('a.log'), item('b.log'), item('c.log')];

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: Scaffold(
              appBar: AppBar(
                actions: [TransferQueueButton(onOpen: () {})],
              ),
              body: _Harness(
                run: (ref) => queueBatchDownloadToStaging(
                  ref,
                  hostId: 'h1',
                  files: files,
                ),
              ),
            ),
          ),
        ),
      );

      // Nothing queued yet: the button hides itself rather than showing a zero.
      expect(find.byIcon(Icons.swap_vert), findsNothing);

      await tester.tap(find.text('go'));
      await tester.pump();

      expect(find.byIcon(Icons.swap_vert), findsOneWidget);
      expect(find.text('3'), findsOneWidget);
    });
  });

  group('the report a batch leaves behind', () {
    test('names both numbers, and adds no English of its own', () {
      final report = batchDownloadReport(queued: 3, selected: 4);

      expect(report, 'Selected: 4 · Download: 3');
      expect(cjk.hasMatch(report), isFalse);
    });

    test('is translated, not assembled from English pieces', () {
      AppStrings.setLang('zh');
      final report = batchDownloadReport(queued: 3, selected: 4);

      expect(report, contains(t('selected')));
      expect(report, contains(t('download')));
      expect(report, contains('4'));
      expect(report, contains('3'));
    });
  });

  group('releasing a staged copy', () {
    test('a dismissed download gives its bytes back', () async {
      final path = localPath('staged-download.bin');
      File(path).writeAsBytesSync(const [1, 2, 3]);

      await discardStagedFile(download(path));

      expect(File(path).existsSync(), isFalse);
    });

    test('an upload never touches the user\'s own file', () async {
      final path = localPath('user-file.bin');
      File(path).writeAsBytesSync(const [1, 2, 3]);

      await discardStagedFile(
        TransferTask(
          id: 'u',
          hostId: 'h1',
          name: 'user-file.bin',
          remotePath: '/var/user-file.bin',
          localPath: path,
          direction: TransferDirection.upload,
          status: TransferStatus.done,
        ),
      );

      expect(
        File(path).existsSync(),
        isTrue,
        reason: 'that path is the source of the upload, not a copy of it',
      );
    });

    test('a task still moving keeps its file', () async {
      final path = localPath('in-flight.bin');
      File(path).writeAsBytesSync(const [1, 2, 3]);

      await discardStagedFile(download(path, status: TransferStatus.running));

      expect(File(path).existsSync(), isTrue);
    });

    test('a copy that is already gone is not a failure', () async {
      await discardStagedFile(download(localPath('never-written.bin')));
    });

    test('clearing finished rows releases the whole group', () async {
      final first = localPath('done-1.bin');
      final second = localPath('done-2.bin');
      File(first).writeAsBytesSync(const [1]);
      File(second).writeAsBytesSync(const [2]);

      await discardStagedFiles([download(first), download(second)]);

      expect(File(first).existsSync(), isFalse);
      expect(File(second).existsSync(), isFalse);
    });
  });

  group('selection mode', () {
    test('a ticked entry is what a batch acts on, and only while it is ticked', () {
      final selection = FileSelection();
      expect(selection.isActive, isFalse);

      selection.begin('/var/a.log');
      expect(selection.isActive, isTrue);
      expect(selection.count, 1);
      expect(selection.contains('/var/a.log'), isTrue);

      selection.toggle('/var/b.log');
      expect(BatchDownloadPlan.of([
        item('a.log'),
        item('b.log'),
      ], selection.paths).files.length, 2);

      // Untick the first: it is no longer part of anything a batch would do.
      selection.toggle('/var/a.log');
      expect(selection.contains('/var/a.log'), isFalse);
      expect(selection.isActive, isTrue);

      // Unticking the last one leaves selection mode, so there can be no bar
      // offering to act on nothing.
      selection.toggle('/var/b.log');
      expect(selection.isActive, isFalse);
      expect(selection.count, 0);
    });

    test('clearing the selection drops every path with it', () {
      final selection = FileSelection()
        ..begin('/var/a.log')
        ..toggle('/var/b.log');

      selection.clear();

      expect(selection.isActive, isFalse);
      expect(selection.paths, isEmpty);
      expect(BatchDownloadPlan.of([item('a.log')], selection.paths).files, isEmpty);
    });
  });
}
