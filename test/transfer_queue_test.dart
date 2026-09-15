import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:neko_mux/models/transfer_task.dart';
import 'package:neko_mux/providers/transfer_provider.dart';
import 'package:neko_mux/services/sftp_service.dart';

import 'transfer_fake_session.dart';

void main() {
  useTransferTempDir();

  group('ordering and concurrency', () {
    test('runs one transfer at a time per host, in enqueue order', () async {
      final factory = FakeSessionFactory();
      final container = transferContainer(factory);
      final queue = container.read(transferQueueProvider.notifier);

      // Every transfer blocks until the test releases it, so "one at a time"
      // is observable rather than raced.
      // 每次传输都阻塞到测试释放它为止，因此「一次一个」是可观测的，而不是靠抢。
      factory.onCreate = (session) {
        session
          ..gateUpload('/remote/a.bin')
          ..gateUpload('/remote/b.bin')
          ..gateUpload('/remote/c.bin');
      };

      writeLocalFile('a.bin', 8);
      writeLocalFile('b.bin', 8);
      writeLocalFile('c.bin', 8);

      final a = queue.enqueueUpload(
        hostId: 'h1',
        localPath: localPath('a.bin'),
        remotePath: '/remote/a.bin',
      );
      final b = queue.enqueueUpload(
        hostId: 'h1',
        localPath: localPath('b.bin'),
        remotePath: '/remote/b.bin',
      );
      final c = queue.enqueueUpload(
        hostId: 'h1',
        localPath: localPath('c.bin'),
        remotePath: '/remote/c.bin',
      );

      await waitUntil(
        container,
        () => factory.sessions.isNotEmpty,
        describe: 'the session to be opened',
      );
      final session = factory.sessions.single;

      await waitUntil(
        container,
        () => session.startedUploads.length == 1,
        describe: 'the first upload to start',
      );
      expect(session.startedUploads, ['/remote/a.bin']);
      expect(
        session.startedUploads,
        isNot(contains('/remote/b.bin')),
        reason: 'the second task must not start while the first is running',
      );
      expect(statusOf(container, b.id), TransferStatus.queued);
      expect(statusOf(container, c.id), TransferStatus.queued);
      expect(session.active, 1);

      // Releasing the first lets exactly one more start, and no more.
      // 释放第一个只会让再一个启动，不会更多。
      session.release('/remote/a.bin');
      await waitForStatus(container, a.id, TransferStatus.done);
      await waitUntil(
        container,
        () => session.startedUploads.length == 2,
        describe: 'the second upload to start after the first finished',
      );
      expect(session.startedUploads[1], '/remote/b.bin');
      expect(statusOf(container, c.id), TransferStatus.queued);
      expect(session.active, 1);

      session.release('/remote/b.bin');
      session.release('/remote/c.bin');
      await waitForStatus(container, b.id, TransferStatus.done);
      await waitForStatus(container, c.id, TransferStatus.done);

      expect(
        session.startedUploads,
        ['/remote/a.bin', '/remote/b.bin', '/remote/c.bin'],
        reason: 'enqueue order is the run order',
      );
      expect(session.maxActive, 1, reason: 'never two streams at once');
    });

    test('runs transfers for different hosts concurrently', () async {
      final factory = FakeSessionFactory();
      final container = transferContainer(factory);
      final queue = container.read(transferQueueProvider.notifier);

      writeLocalFile('one.bin', 4);
      writeLocalFile('two.bin', 4);

      final a = queue.enqueueUpload(
        hostId: 'h1',
        localPath: localPath('one.bin'),
        remotePath: '/remote/one.bin',
      );
      final b = queue.enqueueUpload(
        hostId: 'h2',
        localPath: localPath('two.bin'),
        remotePath: '/remote/two.bin',
      );

      await waitForStatus(container, a.id, TransferStatus.done);
      await waitForStatus(container, b.id, TransferStatus.done);

      // "One at a time" is a per-host rule, not a global one: two servers are
      // two links, and serialising them would only make both slower.
      // 「一次一个」是按主机而非按全局的规则：两台服务器就是两条链路，把它们串行化
      // 只会让两边都更慢。
      expect(factory.openedFor, ['h1', 'h2']);
      expect(factory.sessions[0].completedUploads, ['/remote/one.bin']);
      expect(factory.sessions[1].completedUploads, ['/remote/two.bin']);
    });
  });

  group('failure handling', () {
    test('a failed transfer does not stop the queue', () async {
      final factory = FakeSessionFactory();
      final container = transferContainer(factory);
      final queue = container.read(transferQueueProvider.notifier);

      factory.onCreate = (session) {
        session.failUpload(
          '/remote/bad.bin',
          const SftpException(SftpFailure.write, 'Permission denied'),
        );
      };

      writeLocalFile('bad.bin', 8);
      writeLocalFile('good.bin', 8);

      final bad = queue.enqueueUpload(
        hostId: 'h1',
        localPath: localPath('bad.bin'),
        remotePath: '/remote/bad.bin',
      );
      final good = queue.enqueueUpload(
        hostId: 'h1',
        localPath: localPath('good.bin'),
        remotePath: '/remote/good.bin',
      );

      await waitForStatus(container, bad.id, TransferStatus.failed);
      await waitForStatus(container, good.id, TransferStatus.done);

      expect(taskById(container, bad.id).error, SftpFailure.write.name);
      expect(taskById(container, bad.id).errorDetail, 'Permission denied');
      expect(
        factory.sessions.single.completedUploads,
        ['/remote/good.bin'],
        reason: 'the task behind a failed one still runs',
      );
    });

    test('a failure on the device side reports localIo, not a server code', () async {
      final factory = FakeSessionFactory();
      final container = transferContainer(factory);
      final queue = container.read(transferQueueProvider.notifier);

      // No such file: the upload cannot even be fed, and no SFTP status
      // describes that.
      // 文件不存在：这次上传连数据都喂不出来，没有任何 SFTP 状态能描述这一点。
      final task = queue.enqueueUpload(
        hostId: 'h1',
        localPath: localPath('missing.bin'),
        remotePath: '/remote/missing.bin',
      );

      await waitForStatus(container, task.id, TransferStatus.failed);
      expect(taskById(container, task.id).error, TransferErrorCode.localIo);
      expect(
        taskById(container, task.id).error,
        isNot(anyOf(contains('Sftp'))),
        reason: 'a device-side failure must not be blamed on the server',
      );
    });

    test('a connection that refuses to open fails only its own task', () async {
      final factory = FakeSessionFactory()..failOpens = 1;
      final container = transferContainer(factory);
      final queue = container.read(transferQueueProvider.notifier);

      writeLocalFile('r.bin', 8);

      final first = queue.enqueueUpload(
        hostId: 'h1',
        localPath: localPath('r.bin'),
        remotePath: '/remote/first.bin',
      );
      final second = queue.enqueueUpload(
        hostId: 'h1',
        localPath: localPath('r.bin'),
        remotePath: '/remote/second.bin',
      );

      await waitForStatus(container, first.id, TransferStatus.failed);
      await waitForStatus(container, second.id, TransferStatus.done);

      expect(taskById(container, first.id).error, SftpFailure.connRefused.name);
      expect(
        factory.sessions.length,
        1,
        reason: 'the second task opens its own connection rather than giving up',
      );
    });
  });

  group('cancellation', () {
    test('cancelling a queued task stops it from ever starting', () async {
      final factory = FakeSessionFactory();
      final container = transferContainer(factory);
      final queue = container.read(transferQueueProvider.notifier);

      writeLocalFile('first.bin', 8);
      writeLocalFile('second.bin', 8);
      writeLocalFile('third.bin', 8);

      final first = queue.enqueueUpload(
        hostId: 'h1',
        localPath: localPath('first.bin'),
        remotePath: '/remote/first.bin',
      );
      final second = queue.enqueueUpload(
        hostId: 'h1',
        localPath: localPath('second.bin'),
        remotePath: '/remote/second.bin',
      );
      final third = queue.enqueueUpload(
        hostId: 'h1',
        localPath: localPath('third.bin'),
        remotePath: '/remote/third.bin',
      );

      queue.cancel(second.id);
      expect(statusOf(container, second.id), TransferStatus.cancelled);

      await waitForStatus(container, first.id, TransferStatus.done);
      await waitForStatus(container, third.id, TransferStatus.done);

      expect(
        factory.sessions.single.startedUploads,
        ['/remote/first.bin', '/remote/third.bin'],
        reason: 'the cancelled task is skipped, the one after it is not',
      );
    });

    test('cancelling a running download stops the I/O', () async {
      final factory = FakeSessionFactory();
      final container = transferContainer(factory);
      final queue = container.read(transferQueueProvider.notifier);

      final chunk = Uint8List(4096);
      factory.onCreate = (session) {
        // Endless, and slow enough that the test can catch it mid-flight.
        // 永不结束，且慢到足以让测试在半途抓住它。
        session.serve(
          '/remote/endless.bin',
          chunks: [chunk],
          repeat: -1,
          delay: const Duration(milliseconds: 1),
          size: 1 << 30,
        );
        session.serve('/remote/after.bin', chunks: [chunk], size: chunk.length);
      };

      final running = queue.enqueueDownload(
        hostId: 'h1',
        remotePath: '/remote/endless.bin',
        localPath: localPath('endless.bin'),
      );
      final next = queue.enqueueDownload(
        hostId: 'h1',
        remotePath: '/remote/after.bin',
        localPath: localPath('after.bin'),
      );

      await waitUntil(
        container,
        () => taskById(container, running.id).transferredBytes > 0,
        describe: 'the download to start moving bytes',
      );

      queue.cancel(running.id);
      await waitForStatus(container, running.id, TransferStatus.cancelled);

      final atCancel = taskById(container, running.id).transferredBytes;
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(
        taskById(container, running.id).transferredBytes,
        atCancel,
        reason: 'no further bytes may arrive after the cancel',
      );

      // The stream subscription was cancelled, which is what ran the
      // generator's `finally` and closed the server-side handle. A queue that
      // only flipped a status would never reach this list.
      // 流的订阅被取消了，正是它执行了生成器的 `finally` 并关闭了服务器端句柄。
      // 只翻转状态码的队列永远不会出现在这张表里。
      expect(
        factory.sessions.single.cancelledDownloads,
        contains('/remote/endless.bin'),
      );

      await waitForStatus(container, next.id, TransferStatus.done);
      expect(
        factory.sessions.single.completedUploads,
        isEmpty,
        reason: 'the probe never uploaded anything',
      );
    });

    test('cancelling a running upload stops feeding the server', () async {
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

      final session = factory.sessions.single;
      final sent = session.uploadedBytes['/remote/big.bin']?.length ?? 0;
      expect(
        sent,
        lessThan(total),
        reason: 'closing the source must stop the upload short of the end',
      );
      expect(
        taskById(container, task.id).totalBytes,
        total,
        reason: 'stopping early does not lose the size that was measured',
      );
    });

    test('cancelling an already finished task changes nothing', () async {
      final factory = FakeSessionFactory();
      final container = transferContainer(factory);
      final queue = container.read(transferQueueProvider.notifier);

      writeLocalFile('done.bin', 8);
      final task = queue.enqueueUpload(
        hostId: 'h1',
        localPath: localPath('done.bin'),
        remotePath: '/remote/done.bin',
      );
      await waitForStatus(container, task.id, TransferStatus.done);

      queue.cancel(task.id);
      expect(statusOf(container, task.id), TransferStatus.done);
      expect(taskById(container, task.id).error, isNull);
    });
  });

  group('connection lifecycle', () {
    test('opens one connection per host and releases it when the queue empties', () async {
      final factory = FakeSessionFactory();
      final container = transferContainer(factory);
      final queue = container.read(transferQueueProvider.notifier);

      writeLocalFile('one.bin', 8);
      writeLocalFile('two.bin', 8);

      final first = queue.enqueueUpload(
        hostId: 'h1',
        localPath: localPath('one.bin'),
        remotePath: '/remote/one.bin',
      );
      final second = queue.enqueueUpload(
        hostId: 'h1',
        localPath: localPath('two.bin'),
        remotePath: '/remote/two.bin',
      );

      await waitForStatus(container, first.id, TransferStatus.done);
      await waitForStatus(container, second.id, TransferStatus.done);
      await waitUntil(
        container,
        () => factory.sessions.single.isClosed,
        describe: 'the connection to be released once the queue is empty',
      );

      expect(
        factory.sessions.length,
        1,
        reason: 'two tasks on one host share one connection',
      );
      expect(factory.sessions.single.closeCount, 1);
    });

    test('releases the connection when the last task failed', () async {
      final factory = FakeSessionFactory();
      final container = transferContainer(factory);
      final queue = container.read(transferQueueProvider.notifier);

      factory.onCreate = (session) {
        session.failUpload(
          '/remote/a.bin',
          const SftpException(SftpFailure.write, 'nope'),
        );
        session.failUpload(
          '/remote/b.bin',
          const SftpException(SftpFailure.write, 'nope'),
        );
      };
      writeLocalFile('f.bin', 8);

      final first = queue.enqueueUpload(
        hostId: 'h1',
        localPath: localPath('f.bin'),
        remotePath: '/remote/a.bin',
      );
      final second = queue.enqueueUpload(
        hostId: 'h1',
        localPath: localPath('f.bin'),
        remotePath: '/remote/b.bin',
      );

      await waitForStatus(container, first.id, TransferStatus.failed);
      await waitForStatus(container, second.id, TransferStatus.failed);
      await waitUntil(
        container,
        () => factory.sessions.single.isClosed,
        describe: 'the connection to be released after the failures',
      );
      expect(factory.sessions.single.closeCount, 1);
    });

    test('releases the connection when the last task was cancelled', () async {
      final factory = FakeSessionFactory();
      final container = transferContainer(factory);
      final queue = container.read(transferQueueProvider.notifier);

      final chunk = Uint8List(1024);
      factory.onCreate = (session) {
        session.serve(
          '/remote/slow.bin',
          chunks: [chunk],
          repeat: -1,
          delay: const Duration(milliseconds: 1),
          size: 1 << 30,
        );
      };

      final task = queue.enqueueDownload(
        hostId: 'h1',
        remotePath: '/remote/slow.bin',
        localPath: localPath('slow.bin'),
      );

      await waitUntil(
        container,
        () => taskById(container, task.id).transferredBytes > 0,
        describe: 'the download to start',
      );
      queue.cancel(task.id);
      await waitForStatus(container, task.id, TransferStatus.cancelled);
      await waitUntil(
        container,
        () => factory.sessions.single.isClosed,
        describe: 'the connection to be released after the cancel',
      );
      expect(factory.sessions.single.closeCount, 1);
    });

    test('opens a fresh connection for the next batch', () async {
      final factory = FakeSessionFactory();
      final container = transferContainer(factory);
      final queue = container.read(transferQueueProvider.notifier);

      writeLocalFile('x.bin', 8);

      final first = queue.enqueueUpload(
        hostId: 'h1',
        localPath: localPath('x.bin'),
        remotePath: '/remote/x.bin',
      );
      await waitForStatus(container, first.id, TransferStatus.done);
      await waitUntil(
        container,
        () => factory.sessions.single.isClosed,
        describe: 'the first connection to be released',
      );

      final second = queue.enqueueUpload(
        hostId: 'h1',
        localPath: localPath('x.bin'),
        remotePath: '/remote/y.bin',
      );
      await waitForStatus(container, second.id, TransferStatus.done);

      // Lazily, per batch: an abandoned connection is exactly the leak the
      // `_connectEpoch` guard in `SftpService` exists to prevent, and one kept
      // alive for a host with nothing queued is the same leak seen from here.
      // 按批次惰性打开：被遗弃的连接正是 `SftpService` 里 `_connectEpoch` 守护所要
      // 防止的泄漏，而为一条没有排队任务的主机保留连接，就是同一泄漏在这里的样子。
      expect(factory.sessions.length, 2);
      expect(factory.openedFor, ['h1', 'h1']);
    });
  });
}
