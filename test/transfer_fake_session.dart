import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neko_mux/models/transfer_task.dart';
import 'package:neko_mux/providers/transfer_provider.dart';
import 'package:neko_mux/services/sftp_service.dart';
import 'package:neko_mux/services/transfer_runner.dart';

/// A [TransferSession] that moves real bytes between the queue and the test, with
/// no socket anywhere.
/// 在队列与测试之间搬运真实字节的 [TransferSession]，全程没有套接字。
///
/// It is deliberately shaped like the things the queue depends on rather than
/// like a mock of the service: [download] is an `async*` generator (so
/// `StreamSubscription.cancel()` reaches it exactly as it reaches the real
/// one), and [upload] consumes its source with `await for` (so closing the
/// source ends it exactly as it ends dartssh2's writer).
/// 它刻意的形状是队列所依赖的那些东西，而不是服务的 mock：[download] 是一个 `async*`
/// 生成器（因此 `StreamSubscription.cancel()` 到达它的方式与到达真实实现完全一致），
/// [upload] 用 `await for` 消费数据源（因此关闭数据源终止它的方式与终止 dartssh2
/// 写入器完全一致）。
class FakeTransferSession implements TransferSession {
  FakeTransferSession(this.hostId);

  final String hostId;

  final List<String> startedUploads = [];
  final List<String> startedDownloads = [];

  /// The offset each download was asked to start at, in call order.
  final List<int> downloadOffsets = [];
  final List<String> finishedDownloads = [];
  final List<String> cancelledDownloads = [];
  final List<String> completedUploads = [];
  final Map<String, List<int>> uploadedBytes = {};

  final Map<String, int> sizes = {};
  final Map<String, List<Uint8List>> _chunks = {};
  final Map<String, int> _repeats = {};
  final Map<String, Duration> _delays = {};
  final Map<String, Object> _downloadErrors = {};
  final Map<String, Object> _uploadErrors = {};

  /// Per-chunk delay on an upload, for tests that need to catch one in flight.
  /// 上传每块之间的延迟，供需要抓住进行中任务的测试使用。
  Duration uploadDelay = Duration.zero;

  final Map<String, Completer<void>> _uploadGates = {};

  /// Makes the upload to [path] block until [release] is called for it, so a
  /// test can hold a transfer open and observe what the queue does meanwhile
  /// rather than racing it.
  /// 让发往 [path] 的上传阻塞到对 [path] 调用 [release] 为止，使测试能把一次传输
  /// 撑开、观察队列在此期间做了什么，而不是与它赛跑。
  void gateUpload(String path) =>
      _uploadGates.putIfAbsent(path, Completer.new);

  void release(String path) {
    final gate = _uploadGates[path];
    if (gate != null && !gate.isCompleted) gate.complete();
  }

  int progressCalls = 0;
  int active = 0;
  int maxActive = 0;
  int closeCount = 0;

  bool get isClosed => closeCount > 0;

  /// Makes [path] downloadable. [repeat] of -1 never ends, which is how a test
  /// gets a transfer it can cancel part way through.
  /// 让 [path] 可下载。[repeat] 为 -1 表示永不结束，测试借此得到可以中途取消的传输。
  void serve(
    String path, {
    required List<Uint8List> chunks,
    int repeat = 1,
    Duration delay = Duration.zero,
    int? size,
  }) {
    _chunks[path] = chunks;
    _repeats[path] = repeat;
    _delays[path] = delay;
    if (size != null) sizes[path] = size;
  }

  void failDownload(String path, Object error) => _downloadErrors[path] = error;

  void failUpload(String path, Object error) => _uploadErrors[path] = error;

  @override
  Future<int?> size(String path) async => sizes[path];

  @override
  Stream<Uint8List> download(
    String path, {
    int from = 0,
    void Function(int bytesRead)? onProgress,
  }) async* {
    startedDownloads.add(path);
    downloadOffsets.add(from);
    _enter();
    var reachedEnd = false;
    try {
      final error = _downloadErrors[path];
      if (error != null) throw error;

      final chunks = _chunks[path] ?? const <Uint8List>[];
      final repeat = _repeats[path] ?? 1;
      final delay = _delays[path] ?? Duration.zero;
      var sent = 0;
      onProgress?.call(0);

      var round = 0;
      while (repeat < 0 || round < repeat) {
        for (final chunk in chunks) {
          if (delay > Duration.zero) await Future<void>.delayed(delay);
          yield chunk;
          sent += chunk.length;
          progressCalls++;
          onProgress?.call(sent);
        }
        round++;
      }
      reachedEnd = true;
    } finally {
      // The `finally` of an `async*` body runs on cancellation too, which is
      // the observable that proves the queue's `sub.cancel()` reached the
      // stream rather than merely flipping a flag in the UI.
      // `async*` 函数体的 `finally` 在被取消时同样会执行，这个可观测点证明了队列的
      // `sub.cancel()` 真的到达了这条流，而不只是翻转了界面上的一个标志。
      if (reachedEnd) {
        finishedDownloads.add(path);
      } else {
        cancelledDownloads.add(path);
      }
      _leave();
    }
  }

  @override
  Future<void> upload(
    String path,
    Stream<Uint8List> data, {
    int at = 0,
    void Function(int bytesWritten)? onProgress,
  }) async {
    startedUploads.add(path);
    _enter();
    var reachedEnd = false;
    try {
      final gate = _uploadGates[path];
      if (gate != null) await gate.future;

      final error = _uploadErrors[path];
      if (error != null) throw error;

      final bytes = <int>[];
      await for (final chunk in data) {
        if (uploadDelay > Duration.zero) {
          await Future<void>.delayed(uploadDelay);
        }
        bytes.addAll(chunk);
        progressCalls++;
        onProgress?.call(bytes.length);
      }
      reachedEnd = true;
      uploadedBytes[path] = bytes;
    } finally {
      if (reachedEnd) completedUploads.add(path);
      _leave();
    }
  }

  @override
  Future<void> close() async => closeCount++;

  void _enter() {
    active++;
    if (active > maxActive) maxActive = active;
  }

  void _leave() => active--;
}

/// Hands out [FakeTransferSession]s, one per host, and counts how many were
/// opened.
/// 发放 [FakeTransferSession]（每台主机一个），并统计打开次数。
class FakeSessionFactory {
  final List<FakeTransferSession> sessions = [];
  final List<String> openedFor = [];

  /// Invoked for each session before it is handed over, so a test can describe
  /// what it serves without knowing when the queue will open it.
  /// 在会话交付前对每个会话调用，使测试无需预知队列何时打开它就能描述它提供什么。
  void Function(FakeTransferSession)? onCreate;

  /// How many of the next [open] calls fail, simulating a host that cannot be
  /// reached.
  /// 接下来多少次 [open] 调用会失败，用于模拟连不上的主机。
  int failOpens = 0;

  Future<TransferSession> open(String hostId) async {
    if (failOpens > 0) {
      failOpens--;
      throw const SftpException(SftpFailure.connRefused, 'connection refused');
    }
    final session = FakeTransferSession(hostId);
    onCreate?.call(session);
    sessions.add(session);
    openedFor.add(hostId);
    return session;
  }
}

/// The temp directory a test's local files live in.
/// 测试的本地文件所在的临时目录。
late Directory tempDir;

/// Registers the temp-directory [setUp] and [tearDown] for the calling file.
/// 为调用方文件注册临时目录的 [setUp] 与 [tearDown]。
void useTransferTempDir() {
  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('nekomux_transfer_test_');
  });
  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });
}

String localPath(String name) => '${tempDir.path}/$name';

/// Writes a local file of [bytes] zero bytes into [tempDir].
/// 在 [tempDir] 中写入一个 [bytes] 字节的零填充本地文件。
void writeLocalFile(String name, int bytes) {
  File(localPath(name)).writeAsBytesSync(Uint8List(bytes));
}

ProviderContainer transferContainer(
  FakeSessionFactory factory, {
  Duration progressInterval = Duration.zero,
}) {
  return ProviderContainer.test(
    overrides: [
      transferSessionFactoryProvider.overrideWithValue(factory.open),
      transferProgressIntervalProvider.overrideWithValue(progressInterval),
    ],
  );
}

TransferTask taskById(ProviderContainer container, String id) =>
    container.read(transferQueueProvider).firstWhere((t) => t.id == id);

TransferStatus statusOf(ProviderContainer container, String id) =>
    taskById(container, id).status;

/// Polls [condition] until it holds, yielding to the event loop between checks.
/// 反复检查 [condition] 直到成立，其间让出事件循环。
Future<void> waitUntil(
  ProviderContainer container,
  bool Function() condition, {
  required String describe,
}) async {
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while (DateTime.now().isBefore(deadline)) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
  final tasks = container.read(transferQueueProvider);
  fail('timed out waiting for: $describe\nall tasks: $tasks');
}

Future<void> waitForStatus(
  ProviderContainer container,
  String id,
  TransferStatus status,
) => waitUntil(
  container,
  () => statusOf(container, id) == status,
  describe: 'task $id to reach ${status.name}',
);
