import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neko_mux/core/i18n/strings.dart';
import 'package:neko_mux/models/transfer_task.dart';
import 'package:neko_mux/pages/sftp/sftp_bars.dart';
import 'package:neko_mux/pages/transfer/transfer_format.dart';
import 'package:neko_mux/pages/transfer/transfer_indicator.dart';
import 'package:neko_mux/pages/transfer/transfer_sheet.dart';
import 'package:neko_mux/providers/transfer_provider.dart';

/// The transfer surfaces as an English user sees them, with a queue that holds
/// exactly the tasks a test hands it.
/// 英文用户看到的传输界面，其队列中恰好只有测试交给它的任务。
///
/// A stub queue rather than the real one on purpose: what is under test here is
/// what the *widgets* read and which command a tap sends, and running real
/// transfers inside a widget test would replace those assertions with a race.
/// The commands themselves are tested against the real queue in
/// `transfer_queue_test.dart`; the wiring between the two is what these cover.
/// 刻意使用桩队列而非真实队列：这里要检验的是**控件**读了什么、一次点击发出了哪条命令，
/// 而在 widget 测试里真跑传输只会把这些断言换成一场赛跑。命令本身已在
/// `transfer_queue_test.dart` 中针对真实队列验证过；这些测试覆盖的是两者之间的接线。

/// A queue that runs nothing and records the commands it is sent.
/// 不运行任何东西、只记录收到命令的队列。
class _StubQueue extends TransferQueueNotifier {
  _StubQueue(this.initial);

  final List<TransferTask> initial;

  final List<String> cancelled = <String>[];
  final List<String> retried = <String>[];
  final List<String> removed = <String>[];
  int cleared = 0;

  @override
  List<TransferTask> build() => initial;

  @override
  void cancel(String id) => cancelled.add(id);

  @override
  void retry(String id) => retried.add(id);

  @override
  void remove(String id) => removed.add(id);

  @override
  void clearFinished() => cleared++;
}

/// A queued, running or stopped task, with everything a row can decide from.
/// 一个排队中、进行中或已停止的任务，带有行据以判断的一切。
TransferTask task(
  String id, {
  String name = 'deploy.tar.gz',
  TransferDirection direction = TransferDirection.download,
  TransferStatus status = TransferStatus.running,
  String? localPath = '/tmp/staged/deploy.tar.gz',
  int? totalBytes = 4096,
  int transferredBytes = 1024,
  String? error,
  String? errorDetail,
  String remotePath = '/var/www/deploy.tar.gz',
}) => TransferTask(
  id: id,
  hostId: 'h1',
  name: name,
  remotePath: remotePath,
  localPath: localPath,
  direction: direction,
  totalBytes: totalBytes,
  transferredBytes: transferredBytes,
  status: status,
  error: error,
  errorDetail: errorDetail,
);

/// Pumps the transfer sheet over a scope whose queue is [queue].
/// 在队列为 [queue] 的作用域之上渲染传输面板。
///
/// `pump` and never `pumpAndSettle`: a row whose size is unknown carries an
/// indeterminate progress bar, which animates for as long as it is on screen, so
/// settling is not a state this widget tree ever reaches. That is the point of
/// it, and it is also why the whole suite would hang rather than fail.
/// 用 `pump`，绝不用 `pumpAndSettle`：大小未知的行带有一根不确定的进度条，只要它在屏幕
/// 上就一直在动，因此「安定」根本不是这棵控件树会到达的状态。这正是它的意义所在，也正是
/// 整个测试套件会挂住而不是失败的原因。
Future<void> _pumpSheet(WidgetTester tester, _StubQueue queue) async {
  await tester.pumpWidget(
    // Keyed by the queue, so pumping a second queue into the same test builds a
    // second scope instead of updating the first one's overrides — an update
    // would leave the provider already created from the *first* queue, and the
    // test would silently assert against the tree it built a moment ago.
    // 以队列为 key：在同一个测试中渲染第二个队列时会建立第二个作用域，而不是更新第一个的
    // 覆盖项——更新会让 provider 保持由**第一个**队列创建出来的状态，测试于是会悄悄对着
    // 它片刻之前构建的那棵树做断言。
    ProviderScope(
      key: ObjectKey(queue),
      overrides: [transferQueueProvider.overrideWith(() => queue)],
      child: const MaterialApp(home: Scaffold(body: TransferSheet())),
    ),
  );
  await tester.pump();
}

/// The progress bars currently in the tree.
/// 当前树中的进度条。
List<LinearProgressIndicator> bars(WidgetTester tester) =>
    tester.widgetList<LinearProgressIndicator>(
      find.byType(LinearProgressIndicator),
    ).toList();

/// Every string the tree is currently showing.
/// 当前树中显示的所有字符串。
List<String> renderedText(WidgetTester tester) => tester
    .widgetList<Text>(find.byType(Text))
    .map((text) => text.data ?? '')
    .toList();

/// CJK text and CJK/full-width punctuation.
/// 中日韩文字与 CJK／全角标点。
final cjk = RegExp('[\\u3000-\\u303f\\u4e00-\\u9fff\\uff00-\\uffef]');

void main() {
  // The active language is global mutable state; every test here picks its own
  // and leaves the default behind.
  // 当前语言是全局可变状态；这里的每个测试各自选择，并把默认值留在身后。
  setUp(() => AppStrings.setLang('en'));
  tearDown(() => AppStrings.setLang('zh'));

  group('labels and numbers', () {
    test('sizes read the same way the file list reads them', () {
      expect(transferBytes(0), '0 B');
      expect(transferBytes(1023), '1023 B');
      expect(transferBytes(1024), '1.0 KB');
      expect(transferBytes(1536), '1.5 KB');
      expect(transferBytes(3 * 1024 * 1024), '3.0 MB');
      expect(transferBytes(2 * 1024 * 1024 * 1024), '2.0 GB');
    });

    test('an unknown total is named, never shown as a zero', () {
      final known = task('a', totalBytes: 2048, transferredBytes: 1024);
      expect(transferProgressLine(known), '1.0 KB / 2.0 KB');

      final unknown = task('b', totalBytes: null, transferredBytes: 1024);
      expect(transferProgressLine(unknown), contains(t('transfer_unknown_size')));
      expect(transferProgressLine(unknown), contains('1.0 KB'));
      // The number the user must never read as "this file is empty".
      expect(transferProgressLine(unknown), isNot(contains('0 B /')));

      // A total of 0 is the same statement as no total: `progress` refuses to
      // divide by it, and the line must agree with the bar above it.
      final zero = task('c', totalBytes: 0, transferredBytes: 512);
      expect(transferProgressLine(zero), contains(t('transfer_unknown_size')));
    });

    test('every status and direction has words, in the active language', () {
      for (final status in TransferStatus.values) {
        final label = transferStatusLabel(status);
        expect(label.trim(), isNotEmpty);
        expect(cjk.hasMatch(label), isFalse, reason: 'status $status');
      }
      for (final direction in TransferDirection.values) {
        final label = transferDirectionLabel(direction);
        expect(label.trim(), isNotEmpty);
        expect(cjk.hasMatch(label), isFalse, reason: 'direction $direction');
      }
      expect(transferStatusLabel(TransferStatus.done), t('transfer_status_done'));
      expect(
        transferDirectionLabel(TransferDirection.upload),
        t('transfer_direction_upload'),
      );
    });

    test('a device-side failure gets its own words, not a server code', () {
      final local = task('a', error: TransferErrorCode.localIo, errorDetail: 'EACCES');
      expect(transferFailureText(local), t('transfer_error_local_io'));
      // The raw detail is deliberately not appended here: `localIo` names the
      // side that failed, and the detail is a path or an errno the user cannot
      // act on any differently.
      expect(transferFailureText(local), isNot(contains('EACCES')));
    });

    test('a server-side failure is mapped with the service\'s own wording', () {
      final failed = task(
        'a',
        error: 'read',
        errorDetail: 'Permission denied',
      );
      expect(transferFailureText(failed), contains(t('read_failed')));
      expect(transferFailureText(failed), contains('Permission denied'));

      final upload = task(
        'b',
        direction: TransferDirection.upload,
        error: 'connRefused',
      );
      expect(transferFailureText(upload), t('conn_refused'));
    });

    test('a code nobody recognises falls back to the operation attempted', () {
      final upload = task('a', direction: TransferDirection.upload, error: '?!');
      expect(transferFailureText(upload), contains(t('write_failed')));

      final download = task('b', error: '?!');
      expect(transferFailureText(download), contains(t('read_failed')));
    });

    test('the group progress is indeterminate when any size is unknown', () {
      final known = task('a', totalBytes: 1000, transferredBytes: 500);
      expect(activeTransferProgress([known]), 0.5);

      final unknown = task('b', totalBytes: null, transferredBytes: 0);
      expect(
        activeTransferProgress([known, unknown]),
        isNull,
        reason: 'half a total cannot be averaged into a real number',
      );

      final finished = task('c', status: TransferStatus.done);
      expect(
        activeTransferProgress([finished]),
        isNull,
        reason: 'nothing is running',
      );
      expect(hasActiveTransfers([finished]), isFalse);
      expect(hasActiveTransfers([finished, known]), isTrue);
    });
  });

  group('the transfer list', () {
    testWidgets('draws a determinate bar and both byte counts when sized', (
      tester,
    ) async {
      await _pumpSheet(tester, _StubQueue([task('a')]));

      expect(find.text('deploy.tar.gz'), findsOneWidget);
      expect(find.text('1.0 KB / 4.0 KB'), findsOneWidget);
      expect(bars(tester).single.value, 0.25);
    });

    testWidgets('draws an indeterminate bar when the size is unknown', (
      tester,
    ) async {
      await _pumpSheet(
        tester,
        _StubQueue([task('a', totalBytes: null, transferredBytes: 512)]),
      );

      expect(
        renderedText(tester).join(' '),
        contains(t('transfer_unknown_size')),
      );
      // Null is what Flutter animates as indeterminate; 0 would be a bar
      // claiming the transfer has moved nothing.
      expect(bars(tester).single.value, isNull);
    });

    testWidgets('names the direction and the status of every row', (tester) async {
      await _pumpSheet(
        tester,
        _StubQueue([
          task('a', status: TransferStatus.queued),
          task('b', status: TransferStatus.running),
          task('c', status: TransferStatus.done),
          task('d', status: TransferStatus.failed, error: 'read'),
          task('e', status: TransferStatus.cancelled),
        ]),
      );

      String line(TransferStatus status) =>
          '${t('transfer_direction_download')} · ${transferStatusLabel(status)}';

      void expectNoCjk() {
        for (final text in renderedText(tester)) {
          final hit = cjk.firstMatch(text);
          expect(hit, isNull, reason: '"${hit?.group(0)}" in: $text');
        }
      }

      // Five rows are taller than the test viewport, and the list is lazy, so
      // the last one is only built once it is scrolled into view.
      // 五行比测试视口更高，而列表是惰性构建的，因此最后一行要滚动到可见范围内才会被
      // 建立。
      final first = renderedText(tester).join('\n');
      for (final status in [
        TransferStatus.queued,
        TransferStatus.running,
        TransferStatus.done,
        TransferStatus.failed,
      ]) {
        expect(first, contains(line(status)), reason: 'status $status');
      }
      expect(first, contains(t('read_failed')));
      expect(bars(tester), isNotEmpty);
      expectNoCjk();

      await tester.drag(find.byType(ListView), const Offset(0, -400));
      await tester.pump();

      final last = renderedText(tester).join('\n');
      expect(last, contains(line(TransferStatus.cancelled)));
      expectNoCjk();
    });

    testWidgets('says so when there is nothing to show', (tester) async {
      await _pumpSheet(tester, _StubQueue([]));

      expect(find.text(t('transfer_title')), findsOneWidget);
      expect(find.text(t('no_data')), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsNothing);
      expect(find.text(t('transfer_clear_finished')), findsOneWidget);
    });

    testWidgets('sends cancel for a task that is still moving', (tester) async {
      final queue = _StubQueue([task('a', status: TransferStatus.running)]);
      await _pumpSheet(tester, queue);

      expect(find.text(t('transfer_retry')), findsNothing);
      await tester.tap(find.text(t('cancel')));
      await tester.pumpAndSettle();

      expect(queue.cancelled, ['a']);
      expect(queue.retried, isEmpty);
      expect(queue.removed, isEmpty);
    });

    testWidgets('sends retry and remove for a task that has stopped', (
      tester,
    ) async {
      final queue = _StubQueue([
        task('a', status: TransferStatus.failed, error: 'read'),
      ]);
      await _pumpSheet(tester, queue);

      expect(find.text(t('cancel')), findsNothing);

      await tester.tap(find.text(t('transfer_retry')));
      await tester.pumpAndSettle();
      expect(queue.retried, ['a']);

      await tester.tap(find.text(t('delete')));
      await tester.pumpAndSettle();
      expect(queue.removed, ['a']);
      expect(queue.cancelled, isEmpty);
    });

    testWidgets('clears finished work, and only offers to when there is some', (
      tester,
    ) async {
      final moving = _StubQueue([task('a', status: TransferStatus.running)]);
      await _pumpSheet(tester, moving);
      final disabled = tester.widget<TextButton>(
        find.ancestor(
          of: find.text(t('transfer_clear_finished')),
          matching: find.byType(TextButton),
        ),
      );
      expect(
        disabled.onPressed,
        isNull,
        reason: 'nothing has finished, so there is nothing to clear',
      );

      final finished = _StubQueue([task('a', status: TransferStatus.done)]);
      await _pumpSheet(tester, finished);
      await tester.tap(find.text(t('transfer_clear_finished')));
      await tester.pumpAndSettle();
      expect(finished.cleared, 1);
    });

    testWidgets('offers save on a finished download, and nowhere else', (
      tester,
    ) async {
      await _pumpSheet(tester, _StubQueue([task('a', status: TransferStatus.done)]));
      expect(find.text(t('save')), findsOneWidget);

      // An upload's bytes are already on the server, so there is no local file
      // to publish and the entry is absent rather than useless.
      await _pumpSheet(
        tester,
        _StubQueue([
          task(
            'a',
            status: TransferStatus.done,
            direction: TransferDirection.upload,
          ),
        ]),
      );
      expect(find.text(t('save')), findsNothing);

      // A failed or cancelled download has no complete file either.
      await _pumpSheet(
        tester,
        _StubQueue([task('a', status: TransferStatus.failed, error: 'read')]),
      );
      expect(find.text(t('save')), findsNothing);

      // And a download with no local path has nothing to hand over.
      await _pumpSheet(
        tester,
        _StubQueue([task('a', status: TransferStatus.done, localPath: null)]),
      );
      expect(find.text(t('save')), findsNothing);
    });
  });

  group('the compact surfaces', () {
    testWidgets('the activity bar is absent until something moves', (
      tester,
    ) async {
      var opened = 0;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            transferQueueProvider.overrideWith(
              () => _StubQueue([task('a', status: TransferStatus.done)]),
            ),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: TransferActivityBar(onOpen: () => opened++),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // A finished transfer is not activity: the bar is about movement, and the
      // app-bar button is where a finished one is still reachable.
      expect(find.byType(LinearProgressIndicator), findsNothing);
      expect(find.text(t('transfer_title')), findsNothing);
    });

    testWidgets('the activity bar names the task and opens the list', (
      tester,
    ) async {
      var opened = 0;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            transferQueueProvider.overrideWith(
              () => _StubQueue([
                task('a', status: TransferStatus.running, name: 'error.log'),
              ]),
            ),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: TransferActivityBar(onOpen: () => opened++),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('${t('transfer_title')} · error.log'), findsOneWidget);
      expect(bars(tester).single.value, 0.25);

      await tester.tap(find.byType(TransferActivityBar));
      await tester.pumpAndSettle();
      expect(opened, 1);
    });

    testWidgets('the app-bar button counts the queue and hides when empty', (
      tester,
    ) async {
      var opened = 0;
      Future<void> pumpWith(List<TransferTask> tasks) async {
        await tester.pumpWidget(
          ProviderScope(
            // Keyed for the same reason `pumpSheet` is: two queues in one test
            // must be two scopes.
            // 加 key 的理由与 `pumpSheet` 相同：同一个测试中的两个队列必须是两个作用域。
            key: ObjectKey(tasks),
            overrides: [
              transferQueueProvider.overrideWith(() => _StubQueue(tasks)),
            ],
            child: MaterialApp(
              home: Scaffold(
                appBar: AppBar(
                  actions: [TransferQueueButton(onOpen: () => opened++)],
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
      }

      await pumpWith([]);
      expect(find.byIcon(Icons.swap_vert), findsNothing);

      await pumpWith([
        task('a'),
        task('b', status: TransferStatus.done),
      ]);
      expect(find.text('2'), findsOneWidget);

      await tester.tap(find.byIcon(Icons.swap_vert));
      await tester.pumpAndSettle();
      expect(opened, 1);
    });

    testWidgets('the upload bar reports the tap the page acts on', (
      tester,
    ) async {
      var uploads = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: SftpUploadBar(onUpload: () => uploads++)),
        ),
      );

      expect(find.text(t('upload')), findsOneWidget);
      // The placeholder this replaced is gone for good.
      expect(find.text(t('upload_dev')), findsNothing);

      await tester.tap(find.text(t('upload')));
      await tester.pumpAndSettle();
      expect(uploads, 1);
    });
  });
}
