import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neko_mux/core/i18n/strings.dart';
import 'package:neko_mux/models/file_item.dart';
import 'package:neko_mux/models/transfer_task.dart';
import 'package:neko_mux/pages/transfer/transfer_actions.dart';
import 'package:neko_mux/pages/transfer/transfer_io.dart';
import 'package:neko_mux/pages/transfer/transfer_sheet.dart';
import 'package:neko_mux/providers/transfer_provider.dart';
import 'package:neko_mux/services/transfer_runner.dart';

import 'transfer_fake_session.dart';

/// The device side of a transfer, with the system pickers replaced by a fake.
/// 传输的设备侧，其系统选择器由假实现替代。
///
/// The pickers are the one part of this that a widget test can neither show nor
/// press — on Android they are a native dialog — so what is under test here is
/// the contract this app has with them: which bytes are handed to `saveFile`
/// under which name, what each answer from it means, and which file a download
/// is staged into before any of that happens.
/// 选择器是这里唯一既无法在 widget 测试中显示、也无法按下的部分——在 Android 上它们是
/// 原生对话框——因此这里检验的是本应用与它们之间的契约：哪些字节以哪个名字交给
/// `saveFile`、它的每种答复各意味着什么，以及在这一切发生之前下载被暂存到哪个文件。

/// A [FilePickerPlatform] that answers with whatever the test told it to.
/// 按测试指示作答的 [FilePickerPlatform]。
class _FakePicker extends FilePickerPlatform {
  /// What `pickFiles` reports; an empty list is a cancelled pick.
  /// `pickFiles` 所报告的内容；空列表表示用户取消。
  List<PlatformFile> picked = const <PlatformFile>[];

  /// What `saveFile` answers: null is the documented "the user cancelled".
  /// `saveFile` 的答复：null 即文档所述的「用户取消」。
  Uri? savedTo = Uri.file('/tmp/whatever');

  /// Thrown by `saveFile` instead of answering, when set.
  /// 设置后由 `saveFile` 抛出，而不是返回答复。
  Object? saveError;

  int pickCalls = 0;
  int saveCalls = 0;
  String? savedFileName;
  Uint8List? savedBytes;

  @override
  Future<List<PlatformFile>> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    int compressionQuality = 0,
    AndroidOptions androidOptions = const AndroidOptions(),
    DarwinOptions darwinOptions = const DarwinOptions(),
    WindowsOptions windowsOptions = const WindowsOptions(),
    LinuxOptions linuxOptions = const LinuxOptions(),
    WebOptions webOptions = const WebOptions(),
  }) async {
    pickCalls++;
    return picked;
  }

  @override
  Future<Uri?> saveFile({
    required String fileName,
    required Uint8List bytes,
    required String mimeType,
    String? dialogTitle,
    String? initialDirectory,
    Function(FilePickerStatus)? onFileSaving,
    WindowsOptions windowsOptions = const WindowsOptions(),
    LinuxOptions linuxOptions = const LinuxOptions(),
    WebOptions webOptions = const WebOptions(),
  }) async {
    saveCalls++;
    savedFileName = fileName;
    savedBytes = bytes;
    final failure = saveError;
    if (failure != null) throw failure;
    return savedTo;
  }
}

/// A local file the user is imagined to have chosen.
/// 想象中用户选好的一个本地文件。
///
/// Built directly rather than through the plugin: `PlatformFile` cannot be
/// constructed outside the packages that declare it without depending on them,
/// and the decision under test — where this file's bytes are going — does not
/// depend on anything the plugin adds to it.
/// 直接构造而不是经由插件：在包外构造 `PlatformFile` 就要依赖那些包，而这里要检验的判断
/// ——这个文件的字节将去往何处——并不依赖插件为它附加的任何东西。
UploadPick pick(String path, {String? name, int? size}) => UploadPick(
  path: path,
  name: name ?? path.split('/').last,
  size: size,
);

/// A file of [bytes] bytes that costs nothing to create.
/// 一个创建起来不花代价的、大小为 [bytes] 字节的文件。
///
/// `truncate` leaves a sparse file: the length is real and no data is written, so
/// the over-the-ceiling case does not need 64 MiB of memory or disk to exist.
/// `truncate` 留下的是稀疏文件：长度是真的，数据并未写入，因此「超过上限」这一情形
/// 不需要真的占用 64 MiB 内存或磁盘。
void writeSparseFile(String path, int bytes) {
  final file = File(path).openSync(mode: FileMode.write);
  file.truncateSync(bytes);
  file.closeSync();
}

/// A page-less caller of the queueing helpers, standing in for the SFTP page.
/// 一个不依赖页面、代表 SFTP 页面调用入队辅助函数的调用方。
class _Harness extends ConsumerWidget {
  const _Harness({required this.run});

  final Future<TransferQueueOutcome> Function(WidgetRef ref) run;

  @override
  Widget build(BuildContext context, WidgetRef ref) => TextButton(
    onPressed: () => run(ref),
    child: const Text('go'),
  );
}

void main() {
  useTransferTempDir();

  setUp(() => AppStrings.setLang('en'));
  tearDown(() => AppStrings.setLang('zh'));

  late _FakePicker picker;
  late FilePickerPlatform original;

  setUp(() {
    original = FilePickerPlatform.instance;
    picker = _FakePicker();
    FilePickerPlatform.instance = picker;
  });

  tearDown(() {
    // Global state: leaving the fake installed would make every later test in
    // this isolate talk to it.
    // 全局状态：把假实现留在那里，会让本隔离区后续每个测试都与它对话。
    FilePickerPlatform.instance = original;
  });

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

  /// Runs [run] on the harness and returns the queue afterwards.
  /// 在测试宿主上执行 [run]，随后返回队列内容。
  Future<List<TransferTask>> runAndRead(
    WidgetTester tester,
    ProviderContainer container,
    Future<TransferQueueOutcome> Function(WidgetRef ref) run,
  ) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(home: Scaffold(body: _Harness(run: run))),
      ),
    );
    await tester.tap(find.text('go'));
    await tester.pump();
    return container.read(transferQueueProvider);
  }

  group('choosing a file to upload', () {
    testWidgets('the upload targets the directory the page handed over', (
      tester,
    ) async {
      final container = idleContainer();
      late TransferQueueOutcome outcome;

      await runAndRead(tester, container, (ref) async {
        outcome = queueUpload(
          ref,
          hostId: 'h1',
          remoteDir: '/etc/nginx',
          pick: pick('/tmp/nginx.conf', name: 'nginx.conf', size: 2048),
        );
        return outcome;
      });

      expect(outcome, TransferQueueOutcome.queued);
      final task = container.read(transferQueueProvider).single;
      expect(task.direction, TransferDirection.upload);
      expect(task.remotePath, '/etc/nginx/nginx.conf');
      expect(task.localPath, '/tmp/nginx.conf');
      expect(task.name, 'nginx.conf');
      expect(task.totalBytes, 2048);
    });

    testWidgets('a root directory does not double its separator', (tester) async {
      final container = idleContainer();
      late TransferQueueOutcome outcome;

      await runAndRead(tester, container, (ref) async {
        outcome = queueUpload(
          ref,
          hostId: 'h1',
          remoteDir: '/',
          pick: pick('/tmp/a.txt', name: 'a.txt'),
        );
        return outcome;
      });

      expect(outcome, TransferQueueOutcome.queued);
      expect(container.read(transferQueueProvider).single.remotePath, '/a.txt');
    });

    testWidgets('a pick with nothing readable behind it queues nothing', (
      tester,
    ) async {
      final container = idleContainer();
      late TransferQueueOutcome outcome;

      // What a picker reports when the file lives only behind a document
      // provider it could not export: a name, and no local path.
      await runAndRead(tester, container, (ref) async {
        outcome = queueUpload(
          ref,
          hostId: 'h1',
          remoteDir: '/etc',
          pick: const UploadPick(name: 'notes.txt'),
        );
        return outcome;
      });

      expect(outcome, TransferQueueOutcome.localIo);
      expect(container.read(transferQueueProvider), isEmpty);
    });

    testWidgets('a dismissed picker queues nothing and says nothing', (
      tester,
    ) async {
      final container = idleContainer();
      picker.picked = const <PlatformFile>[]; // empty is the documented cancel
      late TransferQueueOutcome outcome;

      await runAndRead(tester, container, (ref) async {
        outcome = await queueUploadFromPicker(
          ref,
          hostId: 'h1',
          remoteDir: '/etc',
        );
        return outcome;
      });

      expect(picker.pickCalls, 1);
      expect(outcome, TransferQueueOutcome.cancelled);
      expect(container.read(transferQueueProvider), isEmpty);
    });

    testWidgets('a picker that throws is reported, and queues nothing', (
      tester,
    ) async {
      final container = idleContainer();
      late TransferQueueOutcome outcome;

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: Scaffold(
              body: _Harness(
                run: (ref) async {
                  // The throwing picker is simulated at the seam the picker
                  // itself sits behind: a real `pickFiles` that fails raises
                  // from the platform channel, which is an exception out of
                  // this same call.
                  // 抛出异常的选择器在它自己所处的接缝上模拟：真实的 `pickFiles` 失败时
                  // 会从平台通道抛出，正是同一次调用抛出的异常。
                  FilePickerPlatform.instance = _ThrowingPicker();
                  try {
                    outcome = await queueUploadFromPicker(
                      ref,
                      hostId: 'h1',
                      remoteDir: '/etc',
                    );
                  } finally {
                    FilePickerPlatform.instance = picker;
                  }
                  return outcome;
                },
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('go'));
      await tester.pump();

      expect(outcome, TransferQueueOutcome.localIo);
      expect(container.read(transferQueueProvider), isEmpty);
    });
  });

  group('staging a download', () {
    test('every task gets its own path inside the staging directory', () {
      final first = stagedDownloadPath('deploy.tar.gz');
      final second = stagedDownloadPath('deploy.tar.gz');

      expect(first, isNot(second), reason: 'two downloads must not collide');
      expect(first, startsWith(transferStagingDirectory().path));
      expect(first, endsWith('_deploy.tar.gz'));
      expect(second, endsWith('_deploy.tar.gz'));
    });

    testWidgets('the download carries the file\'s path and its size', (
      tester,
    ) async {
      final container = idleContainer();
      final file = FileItem(
        name: 'access.log',
        path: '/var/log/access.log',
        size: 4096,
        modifiedDate: DateTime(2026, 1, 1),
      );

      await runAndRead(
        tester,
        container,
        (ref) async => queueDownloadToStaging(ref, hostId: 'h1', file: file),
      );

      final task = container.read(transferQueueProvider).single;
      expect(task.direction, TransferDirection.download);
      expect(task.remotePath, '/var/log/access.log');
      expect(task.name, 'access.log');
      expect(task.totalBytes, 4096);
      expect(task.localPath, startsWith(transferStagingDirectory().path));
      expect(task.localPath, endsWith('_access.log'));
      expect(
        Directory(transferStagingDirectory().path).existsSync(),
        isTrue,
        reason: 'the staging directory is created before anything is queued',
      );
    });

    testWidgets('a listing with no size leaves the total unknown', (
      tester,
    ) async {
      final container = idleContainer();
      final file = FileItem(
        name: 'mystery',
        path: '/var/mystery',
        modifiedDate: DateTime(2026, 1, 1),
      );

      await runAndRead(
        tester,
        container,
        (ref) async => queueDownloadToStaging(ref, hostId: 'h1', file: file),
      );

      expect(container.read(transferQueueProvider).single.totalBytes, isNull);
    });
  });

  group('publishing a finished download', () {
    TransferTask staged(String name, {int? transferredBytes}) => TransferTask(
      id: 't1',
      hostId: 'h1',
      name: name,
      remotePath: '/var/$name',
      localPath: localPath(name),
      direction: TransferDirection.download,
      totalBytes: transferredBytes,
      transferredBytes: transferredBytes ?? 0,
      status: TransferStatus.done,
    );

    test('hands the staged bytes to the save dialog under the file\'s name', () async {
      File(localPath('access.log')).writeAsStringSync('hello server');

      final outcome = await saveTransferToDevice(staged('access.log'));

      expect(outcome, TransferSaveOutcome.saved);
      expect(picker.saveCalls, 1);
      expect(picker.savedFileName, 'access.log');
      expect(picker.savedBytes, Uint8List.fromList('hello server'.codeUnits));
    });

    test('a dismissed save dialog is a cancellation, not a failure', () async {
      File(localPath('a.txt')).writeAsStringSync('x');
      picker.savedTo = null;

      expect(
        await saveTransferToDevice(staged('a.txt')),
        TransferSaveOutcome.cancelled,
      );
    });

    test('a staged file that is gone is reported without asking anybody', () async {
      expect(
        await saveTransferToDevice(staged('never-written.bin')),
        TransferSaveOutcome.missing,
      );
      expect(
        picker.saveCalls,
        0,
        reason: 'nothing to save means the user is not asked where to put it',
      );
    });

    test('a download with no local path has nothing to publish', () async {
      final task = TransferTask(
        id: 't1',
        hostId: 'h1',
        name: 'a.txt',
        remotePath: '/var/a.txt',
        direction: TransferDirection.download,
        status: TransferStatus.done,
      );
      expect(await saveTransferToDevice(task), TransferSaveOutcome.missing);
      expect(picker.saveCalls, 0);
    });

    test('a file above the ceiling is refused before a byte is read', () async {
      writeSparseFile(localPath('huge.img'), transferSaveMaxBytes + 1);

      expect(
        await saveTransferToDevice(staged('huge.img')),
        TransferSaveOutcome.tooLarge,
      );
      expect(
        picker.saveCalls,
        0,
        reason: 'the whole payload would have to fit in memory at once',
      );
    });

    test('a file exactly at the ceiling is allowed', () async {
      writeSparseFile(localPath('big.img'), transferSaveMaxBytes);

      expect(
        await saveTransferToDevice(staged('big.img')),
        TransferSaveOutcome.saved,
      );
      expect(picker.savedBytes, hasLength(transferSaveMaxBytes));
    });

    test('a picker that throws is a failure, not a crash', () async {
      File(localPath('a.txt')).writeAsStringSync('x');
      picker.saveError = const FileSystemException('provider went away');

      expect(
        await saveTransferToDevice(staged('a.txt')),
        TransferSaveOutcome.failed,
      );
    });

    testWidgets('the row\'s save button publishes the file and says so', (
      tester,
    ) async {
      File(localPath('report.csv')).writeAsStringSync('a,b\n1,2\n');
      final task = staged('report.csv');

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            transferQueueProvider.overrideWith(() => _FixedQueue([task])),
          ],
          child: const MaterialApp(home: Scaffold(body: TransferSheet())),
        ),
      );
      await tester.pump();

      expect(find.text(t('save')), findsOneWidget);
      // The button reads the staged file off the real disk, so the tap is
      // wrapped in `runAsync`: outside the fake clock is the only place a real
      // `File.exists` future ever completes.
      // 该按钮会从真实磁盘读取暂存文件，因此这次点击包在 `runAsync` 中：只有在假时钟之外，
      // 真实的 `File.exists` future 才会完成。
      await tester.runAsync(() async {
        await tester.tap(find.text(t('save')));
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pump();

      expect(picker.savedFileName, 'report.csv');
      expect(picker.savedBytes, Uint8List.fromList('a,b\n1,2\n'.codeUnits));
      expect(find.text(t('file_saved')), findsOneWidget);
    });

    testWidgets('a refused save is reported as a local file error', (
      tester,
    ) async {
      writeSparseFile(localPath('huge.img'), transferSaveMaxBytes + 1);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            transferQueueProvider.overrideWith(
              () => _FixedQueue([staged('huge.img')]),
            ),
          ],
          child: const MaterialApp(home: Scaffold(body: TransferSheet())),
        ),
      );
      await tester.pump();

      await tester.runAsync(() async {
        await tester.tap(find.text(t('save')));
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pump();

      expect(picker.saveCalls, 0);
      expect(find.text(t('file_too_large')), findsOneWidget);
    });
  });
}

/// A queue holding exactly the tasks a test hands it.
/// 恰好持有测试交给它的任务的队列。
class _FixedQueue extends TransferQueueNotifier {
  _FixedQueue(this.tasks);

  final List<TransferTask> tasks;

  @override
  List<TransferTask> build() => tasks;
}

/// A picker that fails the way a platform channel does.
/// 以平台通道的方式失败的选择器。
class _ThrowingPicker extends FilePickerPlatform {
  @override
  Future<List<PlatformFile>> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    int compressionQuality = 0,
    AndroidOptions androidOptions = const AndroidOptions(),
    DarwinOptions darwinOptions = const DarwinOptions(),
    WindowsOptions windowsOptions = const WindowsOptions(),
    LinuxOptions linuxOptions = const LinuxOptions(),
    WebOptions webOptions = const WebOptions(),
  }) async {
    throw const FileSystemException('no activity to pick from');
  }
}
