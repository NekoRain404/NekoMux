import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neko_mux/models/transfer_task.dart';
import 'package:neko_mux/providers/transfer_provider.dart';
import 'package:neko_mux/services/sftp_service.dart';
import 'package:neko_mux/services/transfer_runner.dart';

import 'transfer_fake_session.dart';

/// How a transfer ends, and what the row says about it.
/// 一次传输如何结束，以及该行对此说了什么。
///
/// Three separate rules, all of them about the *terminal* state: that a cancel
/// which arrives after the bytes did not relabel a complete transfer, that a
/// retried task waits its turn, and that a task which failed still reports the
/// bytes it moved.
/// 三条互相独立的规则，全都关于**终止**状态：在字节到达之后才到来的取消不会把一次完整
/// 的传输改标；被重试的任务照旧排队等待；失败的任务仍然报告它搬运过的字节数。

/// A session whose download reports bytes and then fails, so a failure can be
/// observed arriving *after* progress has been made.
/// 一次下载会先报告字节、随后失败的会话，使「失败发生在进度之后」这一情形可被观测。
class _FailsAfterProgress implements TransferSession {
  _FailsAfterProgress(this.chunks, this.error);

  final List<Uint8List> chunks;
  final Object error;

  @override
  Future<int?> size(String path) async =>
      chunks.fold<int>(0, (sum, chunk) => sum + chunk.length);

  @override
  Stream<Uint8List> download(
    String path, {
    int from = 0,
    void Function(int bytesRead)? onProgress,
  }) async* {
    var sent = 0;
    onProgress?.call(0);
    for (final chunk in chunks) {
      yield chunk;
      sent += chunk.length;
      onProgress?.call(sent);
    }
    throw error;
  }

  @override
  Future<void> upload(
    String path,
    Stream<Uint8List> data, {
    int at = 0,
    void Function(int bytesWritten)? onProgress,
  }) async {
    throw UnimplementedError('not used by these tests');
  }

  @override
  Future<void> close() async {}
}

void main() {
  useTransferTempDir();

  group('cancelling at the finish line', () {
    test('a cancel that lands after the last byte is still a finished download', () async {
      final factory = FakeSessionFactory();
      final container = transferContainer(factory);
      final queue = container.read(transferQueueProvider.notifier);

      final payload = Uint8List(4096);
      factory.onCreate = (session) {
        session.serve('/remote/one.bin', chunks: [payload], size: payload.length);
      };

      final task = queue.enqueueDownload(
        hostId: 'h1',
        remotePath: '/remote/one.bin',
        localPath: localPath('one.bin'),
      );

      // The tap that lands in the window the finding is about: every byte has
      // been published, the stream has ended, and the task is still `running`
      // because the runner is inside its `finally` — cancelling the subscription
      // and closing the sink, which is real file I/O rather than a microtask.
      // 落在该缺陷所描述的那个窗口里的点击：所有字节都已发布、流已经结束，而任务仍是
      // `running`，因为 runner 正在它的 `finally` 里——取消订阅、关闭接收端，那是真实的
      // 文件 I/O，不是一个微任务。
      container.listen(transferQueueProvider, (_, next) {
        final current = next.where((t) => t.id == task.id).firstOrNull;
        if (current == null ||
            current.status != TransferStatus.running ||
            current.transferredBytes != payload.length) {
          return;
        }
        // A microtask, so the cancel cannot land before the stream's own end:
        // this is the "after the bytes, before the close" window, not a race.
        // 用一个微任务，好让取消不会抢在流自身结束之前落下：这里要的是「字节已到、关闭
        // 未完成」那个窗口，而不是一场赛跑。
        scheduleMicrotask(() => queue.cancel(task.id));
      });

      await waitUntil(
        container,
        () => taskById(container, task.id).isTerminal,
        describe: 'the task to stop',
      );

      expect(
        statusOf(container, task.id),
        TransferStatus.done,
        reason: 'the file is complete, so the row may not say cancelled',
      );
      expect(File(localPath('one.bin')).lengthSync(), payload.length);
    });

    test('a cancel before the last byte is still a cancellation', () async {
      final factory = FakeSessionFactory();
      final container = transferContainer(factory);
      final queue = container.read(transferQueueProvider.notifier);

      final chunk = Uint8List(1024);
      factory.onCreate = (session) {
        session.serve(
          '/remote/endless.bin',
          chunks: [chunk],
          repeat: -1,
          delay: const Duration(milliseconds: 1),
          size: 1 << 30,
        );
      };

      final task = queue.enqueueDownload(
        hostId: 'h1',
        remotePath: '/remote/endless.bin',
        localPath: localPath('endless.bin'),
      );
      await waitUntil(
        container,
        () => taskById(container, task.id).transferredBytes > 0,
        describe: 'the download to start',
      );

      queue.cancel(task.id);
      await waitForStatus(container, task.id, TransferStatus.cancelled);
    });

    test('a cancelled upload that stopped short is a cancellation', () async {
      final factory = FakeSessionFactory();
      final container = transferContainer(factory);
      final queue = container.read(transferQueueProvider.notifier);

      const total = 2 * 1024 * 1024;
      factory.onCreate = (session) {
        session.uploadDelay = const Duration(milliseconds: 1);
      };
      writeLocalFile('big.bin', total);

      final task = queue.enqueueUpload(
        hostId: 'h1',
        localPath: localPath('big.bin'),
        remotePath: '/remote/big.bin',
      );
      await waitUntil(
        container,
        () => taskById(container, task.id).transferredBytes > 0,
        describe: 'the upload to start moving bytes',
      );

      queue.cancel(task.id);
      await waitForStatus(container, task.id, TransferStatus.cancelled);

      final sent = factory.sessions.single.uploadedBytes['/remote/big.bin'];
      expect(sent?.length ?? 0, lessThan(total));
    });
  });

  group('retry', () {
    test('a retried task goes to the back of the queue instead of jumping it', () async {
      final factory = FakeSessionFactory();
      final container = transferContainer(factory);
      final queue = container.read(transferQueueProvider.notifier);

      factory.onCreate = (session) {
        // The first task fails; the other two wait for the test to release them,
        // so "who runs next" is observed rather than raced.
        // 第一个任务失败；另外两个等测试释放，因此「谁下一个运行」是被观察到的，而不是
        // 抢出来的。
        session
          ..failUpload(
            '/remote/first.bin',
            const SftpException(SftpFailure.write, 'nope'),
          )
          ..gateUpload('/remote/second.bin')
          ..gateUpload('/remote/third.bin');
      };
      writeLocalFile('f.bin', 8);

      final first = queue.enqueueUpload(
        hostId: 'h1',
        localPath: localPath('f.bin'),
        remotePath: '/remote/first.bin',
      );
      final second = queue.enqueueUpload(
        hostId: 'h1',
        localPath: localPath('f.bin'),
        remotePath: '/remote/second.bin',
      );
      final third = queue.enqueueUpload(
        hostId: 'h1',
        localPath: localPath('f.bin'),
        remotePath: '/remote/third.bin',
      );

      await waitForStatus(container, first.id, TransferStatus.failed);
      final session = factory.sessions.single;
      await waitUntil(
        container,
        () => session.startedUploads.contains('/remote/second.bin'),
        describe: 'the second task to start',
      );

      queue.retry(first.id);
      expect(
        container.read(transferQueueProvider).map((t) => t.id),
        [second.id, third.id, first.id],
        reason: 'the retried row moves to the end of the sheet',
      );

      session.release('/remote/second.bin');
      await waitForStatus(container, second.id, TransferStatus.done);
      await waitUntil(
        container,
        () => session.startedUploads.contains('/remote/third.bin'),
        describe: 'the third task to start while the retry waits',
      );
      session.release('/remote/third.bin');
      await waitForStatus(container, third.id, TransferStatus.done);
      await waitForStatus(container, first.id, TransferStatus.failed);

      expect(
        session.startedUploads,
        [
          '/remote/first.bin',
          '/remote/second.bin',
          '/remote/third.bin',
          '/remote/first.bin',
        ],
        reason: 'the retry runs last, not in the place it was enqueued in',
      );
    });
  });

  group('a failed task reports what it moved', () {
    test('bytes still pending at the failure are carried into the row', () async {
      final chunks = [Uint8List(1024), Uint8List(1024)];
      final container = ProviderContainer.test(
        overrides: [
          transferSessionFactoryProvider.overrideWithValue(
            (String hostId) async => _FailsAfterProgress(
              chunks,
              const SftpException(SftpFailure.read, 'the connection went away'),
            ),
          ),
          // No progress publication after the first: whatever the transfer moves
          // after that stays in the pending map, which is exactly the value the
          // failure has to carry.
          // 第一次之后不再发布任何进度：此后传输搬运的字节都留在待发表中，而那正是失败
          // 必须结转的值。
          transferProgressIntervalProvider.overrideWithValue(
            const Duration(hours: 1),
          ),
        ],
      );
      final queue = container.read(transferQueueProvider.notifier);

      final task = queue.enqueueDownload(
        hostId: 'h1',
        remotePath: '/remote/backup.bin',
        localPath: localPath('backup.bin'),
      );
      await waitForStatus(container, task.id, TransferStatus.failed);

      expect(
        File(localPath('backup.bin')).lengthSync(),
        2048,
        reason: 'the bytes really did arrive before the failure',
      );
      expect(
        taskById(container, task.id).transferredBytes,
        2048,
        reason: 'a failed row may not claim to have moved less than it did',
      );
      expect(taskById(container, task.id).error, SftpFailure.read.name);
      expect(
        taskById(container, task.id).errorDetail,
        'the connection went away',
      );
    });
  });
}
