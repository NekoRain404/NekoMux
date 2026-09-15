import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:neko_mux/models/transfer_task.dart';
import 'package:neko_mux/providers/transfer_provider.dart';
import 'package:neko_mux/services/sftp_service.dart';

import 'transfer_fake_session.dart';

void main() {
  useTransferTempDir();

  group('progress', () {
    test('publishes bytes as they move', () async {
      final factory = FakeSessionFactory();
      final container = transferContainer(factory);
      final queue = container.read(transferQueueProvider.notifier);

      final chunks = [Uint8List(1024), Uint8List(2048)];
      factory.onCreate = (session) {
        session.serve('/remote/p.bin', chunks: chunks, size: 3072);
      };

      final seen = <int>[];
      container.listen(transferQueueProvider, (_, next) {
        final task = next.where((t) => t.name == 'p.bin').firstOrNull;
        if (task != null) seen.add(task.transferredBytes);
      });

      final task = queue.enqueueDownload(
        hostId: 'h1',
        remotePath: '/remote/p.bin',
        localPath: localPath('p.bin'),
      );
      await waitForStatus(container, task.id, TransferStatus.done);

      expect(seen, contains(1024));
      expect(seen, contains(3072));
      expect(taskById(container, task.id).progress, 1.0);
    });

    test('coalesces progress publications instead of publishing per chunk', () async {
      final factory = FakeSessionFactory();
      // An interval no transfer can outlast, so the only publications left are
      // the ones that must happen: start, the first progress report (which is
      // never withheld), and the terminal transition.
      // 一个任何传输都跑不完的间隔，于是只剩下必须发生的发布：开始、第一次进度报告
      // （它从不被扣留），以及终止跃迁。
      final container = transferContainer(
        factory,
        progressInterval: const Duration(hours: 1),
      );
      final queue = container.read(transferQueueProvider.notifier);

      final chunks = [for (var i = 0; i < 40; i++) Uint8List(64 * 1024)];
      factory.onCreate = (session) {
        session.serve(
          '/remote/many.bin',
          chunks: chunks,
          size: 40 * 64 * 1024,
        );
      };

      var publications = 0;
      container.listen(transferQueueProvider, (_, _) => publications++);

      final task = queue.enqueueDownload(
        hostId: 'h1',
        remotePath: '/remote/many.bin',
        localPath: localPath('many.bin'),
      );
      await waitForStatus(container, task.id, TransferStatus.done);

      final session = factory.sessions.single;
      expect(
        session.progressCalls,
        greaterThanOrEqualTo(40),
        reason: 'the transfer really did report progress per chunk',
      );
      expect(
        publications,
        lessThanOrEqualTo(4),
        reason: 'the queue must not rebuild its listeners once per chunk',
      );

      // And the coalesced-away values are not lost: the finished row shows
      // everything it moved.
      // 被合并掉的值也没有丢失：已结束的行显示它搬运的全部内容。
      expect(taskById(container, task.id).transferredBytes, 40 * 64 * 1024);
    });

    test('a task the server gives no size for still completes, with null progress', () async {
      final factory = FakeSessionFactory();
      final container = transferContainer(factory);
      final queue = container.read(transferQueueProvider.notifier);

      final chunks = [Uint8List(500), Uint8List(500)];
      factory.onCreate = (session) {
        // No `size` argument: this server does not report one.
        // 不传 `size`：这台服务器不报告大小。
        session.serve('/remote/unsized.bin', chunks: chunks);
      };

      final task = queue.enqueueDownload(
        hostId: 'h1',
        remotePath: '/remote/unsized.bin',
        localPath: localPath('unsized.bin'),
      );
      await waitForStatus(container, task.id, TransferStatus.done);

      expect(taskById(container, task.id).totalBytes, isNull);
      expect(taskById(container, task.id).progress, isNull);
      expect(
        File(localPath('unsized.bin')).lengthSync(),
        1000,
        reason: 'an unknown size must not stop the bytes from arriving',
      );
    });
  });

  group('row management', () {
    test('retry puts a finished task back in line and clears its diagnosis', () async {
      final factory = FakeSessionFactory();
      final container = transferContainer(factory);
      final queue = container.read(transferQueueProvider.notifier);

      factory.onCreate = (session) {
        session.failUpload(
          '/remote/flaky.bin',
          const SftpException(SftpFailure.write, 'nope'),
        );
      };
      writeLocalFile('flaky.bin', 8);

      final task = queue.enqueueUpload(
        hostId: 'h1',
        localPath: localPath('flaky.bin'),
        remotePath: '/remote/flaky.bin',
      );
      await waitForStatus(container, task.id, TransferStatus.failed);
      expect(taskById(container, task.id).error, isNotNull);

      // The second connection serves it properly.
      // 第二条连接正常提供它。
      factory.onCreate = null;
      queue.retry(task.id);
      await waitForStatus(container, task.id, TransferStatus.done);

      expect(taskById(container, task.id).error, isNull);
      expect(taskById(container, task.id).errorDetail, isNull);
      expect(factory.sessions.length, 2);
    });

    test('retry is a no-op for a task that has not finished', () async {
      final factory = FakeSessionFactory();
      final container = transferContainer(factory);
      final queue = container.read(transferQueueProvider.notifier);

      writeLocalFile('q.bin', 8);
      final task = queue.enqueueUpload(
        hostId: 'h1',
        localPath: localPath('q.bin'),
        remotePath: '/remote/q.bin',
      );
      final before = taskById(container, task.id);
      queue.retry(task.id);
      expect(identical(taskById(container, task.id), before), isTrue);
    });

    test('remove drops the row and cancels what is still going', () async {
      final factory = FakeSessionFactory();
      final container = transferContainer(factory);
      final queue = container.read(transferQueueProvider.notifier);

      final chunk = Uint8List(1024);
      factory.onCreate = (session) {
        session.serve(
          '/remote/gone.bin',
          chunks: [chunk],
          repeat: -1,
          delay: const Duration(milliseconds: 1),
          size: 1 << 30,
        );
      };

      final task = queue.enqueueDownload(
        hostId: 'h1',
        remotePath: '/remote/gone.bin',
        localPath: localPath('gone.bin'),
      );
      await waitUntil(
        container,
        () => taskById(container, task.id).transferredBytes > 0,
        describe: 'the download to start',
      );

      queue.remove(task.id);
      expect(
        container.read(transferQueueProvider).where((t) => t.id == task.id),
        isEmpty,
      );

      // The row is gone, but the transfer really stopped: the load-bearing half
      // of "remove" is the cancel.
      // 行没了，但传输确实停了：「移除」真正承重的那一半是取消。
      await waitUntil(
        container,
        () => factory.sessions.single.isClosed,
        describe: 'the connection to be released once the removed task stopped',
      );
      expect(
        factory.sessions.single.cancelledDownloads,
        contains('/remote/gone.bin'),
      );
    });

    test('clearFinished keeps only what is still going', () async {
      final factory = FakeSessionFactory();
      final container = transferContainer(factory);
      final queue = container.read(transferQueueProvider.notifier);

      final chunk = Uint8List(1024);
      factory.onCreate = (session) {
        session.serve(
          '/remote/live.bin',
          chunks: [chunk],
          repeat: -1,
          delay: const Duration(milliseconds: 1),
          size: 1 << 30,
        );
        session.serve('/remote/quick.bin', chunks: [chunk], size: chunk.length);
      };
      writeLocalFile('quick.bin', 8);

      final upload = queue.enqueueUpload(
        hostId: 'h1',
        localPath: localPath('quick.bin'),
        remotePath: '/remote/quick.bin',
      );
      await waitForStatus(container, upload.id, TransferStatus.done);

      final live = queue.enqueueDownload(
        hostId: 'h1',
        remotePath: '/remote/live.bin',
        localPath: localPath('live.bin'),
      );
      await waitUntil(
        container,
        () => taskById(container, live.id).transferredBytes > 0,
        describe: 'the second batch to start',
      );

      queue.clearFinished();
      final remaining = container.read(transferQueueProvider);
      expect(remaining.map((t) => t.id), [live.id]);

      queue.cancel(live.id);
      await waitForStatus(container, live.id, TransferStatus.cancelled);
      queue.clearFinished();
      expect(container.read(transferQueueProvider), isEmpty);
    });
  });

  group('end to end through the queue', () {
    test('a download writes the server bytes to the local file', () async {
      final factory = FakeSessionFactory();
      final container = transferContainer(factory);
      final queue = container.read(transferQueueProvider.notifier);

      final payload = Uint8List.fromList(List.generate(300, (i) => i % 256));
      factory.onCreate = (session) {
        session.serve(
          '/remote/backup.tar.gz',
          chunks: [
            Uint8List.sublistView(payload, 0, 100),
            Uint8List.sublistView(payload, 100, 300),
          ],
          size: payload.length,
        );
      };

      final task = queue.enqueueDownload(
        hostId: 'h1',
        remotePath: '/remote/backup.tar.gz',
        localPath: localPath('backup.tar.gz'),
      );
      await waitForStatus(container, task.id, TransferStatus.done);

      expect(File(localPath('backup.tar.gz')).readAsBytesSync(), payload);
      expect(taskById(container, task.id).name, 'backup.tar.gz');
      expect(taskById(container, task.id).totalBytes, payload.length);
      expect(taskById(container, task.id).transferredBytes, payload.length);
      expect(taskById(container, task.id).direction, TransferDirection.download);
    });

    test('an upload sends the local file bytes and measures them', () async {
      final factory = FakeSessionFactory();
      final container = transferContainer(factory);
      final queue = container.read(transferQueueProvider.notifier);

      final payload = Uint8List.fromList(List.generate(1234, (i) => i % 256));
      File(localPath('config.conf')).writeAsBytesSync(payload);

      final task = queue.enqueueUpload(
        hostId: 'h1',
        localPath: localPath('config.conf'),
        remotePath: '/srv/config.conf',
      );
      await waitForStatus(container, task.id, TransferStatus.done);

      expect(
        factory.sessions.single.uploadedBytes['/srv/config.conf'],
        payload,
      );
      expect(
        taskById(container, task.id).totalBytes,
        1234,
        reason: 'the local file is measured when the task starts',
      );
      expect(taskById(container, task.id).progress, 1.0);
      expect(taskById(container, task.id).name, 'config.conf');
    });

    test('the default name for a download is the remote file name', () async {
      final factory = FakeSessionFactory();
      final container = transferContainer(factory);
      final queue = container.read(transferQueueProvider.notifier);

      final task = queue.enqueueDownload(
        hostId: 'h1',
        remotePath: '/var/backups/db-2026-09-15.sql',
        localPath: localPath('whatever.sql'),
      );
      // Posix rules, so a Windows-style path on the phone does not change it.
      // 用 POSIX 规则，因此手机上的 Windows 风格路径不会影响它。
      expect(task.name, 'db-2026-09-15.sql');
    });
  });
}
