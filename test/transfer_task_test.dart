import 'package:flutter_test/flutter_test.dart';
import 'package:neko_mux/models/transfer_task.dart';

/// A task with everything but the fields under test held constant.
/// 除被测字段外全部固定的任务。
TransferTask task({
  int? totalBytes,
  int transferredBytes = 0,
  TransferStatus status = TransferStatus.queued,
  String? error,
  String? errorDetail,
}) {
  return TransferTask(
    id: 't1',
    hostId: 'h1',
    name: 'backup.tar.gz',
    remotePath: '/srv/backup.tar.gz',
    localPath: '/sdcard/backup.tar.gz',
    direction: TransferDirection.download,
    totalBytes: totalBytes,
    transferredBytes: transferredBytes,
    status: status,
    error: error,
    errorDetail: errorDetail,
  );
}

void main() {
  group('progress', () {
    test('is a fraction of the total when the total is known', () {
      expect(task(totalBytes: 200, transferredBytes: 50).progress, 0.25);
      expect(task(totalBytes: 200, transferredBytes: 200).progress, 1.0);
      expect(task(totalBytes: 4, transferredBytes: 1).progress, 0.25);
    });

    test('is null — not zero — when the total is unknown', () {
      // The distinction is the whole point: a caller that divides by a null
      // total and shows 0% is claiming the transfer has moved nothing, when in
      // truth the server never said how big the file is.
      // 这一区分正是重点：把 null 总数当分母、显示 0% 的调用方，是在断言传输一点都没
      // 动，而事实是服务器从未说过文件有多大。
      expect(task(transferredBytes: 1234).progress, isNull);
      expect(task(transferredBytes: 0).progress, isNull);
    });

    test('is null when the total is zero or negative', () {
      // A zero-byte file has no meaningful fraction, and neither does a size the
      // server reported as 0 for something that clearly has bytes.
      // 零字节文件没有有意义的比例，服务器对明明有内容的东西报告 0 也一样。
      expect(task(totalBytes: 0).progress, isNull);
      expect(task(totalBytes: -5, transferredBytes: 3).progress, isNull);
    });

    test('starts at zero for a task that has not moved anything', () {
      expect(task(totalBytes: 100).progress, 0.0);
    });

    test('clamps at 1 when the server sends more than it promised', () {
      // A file still being appended to on the server can overshoot the size the
      // task measured at its start; a bar must not run off its own end.
      // 服务器上仍在被追加的文件可能超过任务开始时量到的大小；进度条不能跑出自己的
      // 末端。
      expect(task(totalBytes: 100, transferredBytes: 150).progress, 1.0);
    });

    test('is null once again for a terminal task that never learned its size', () {
      final done = task(
        status: TransferStatus.done,
        transferredBytes: 4096,
      );
      expect(done.progress, isNull);
      expect(done.isTerminal, isTrue);
    });
  });

  group('isTerminal', () {
    test('is false only while queued or running', () {
      expect(task(status: TransferStatus.queued).isTerminal, isFalse);
      expect(task(status: TransferStatus.running).isTerminal, isFalse);
      expect(task(status: TransferStatus.done).isTerminal, isTrue);
      expect(task(status: TransferStatus.failed).isTerminal, isTrue);
      expect(task(status: TransferStatus.cancelled).isTerminal, isTrue);
    });
  });

  group('copyWith', () {
    test('keeps the identity fields a UI keys its rows on', () {
      final before = task(totalBytes: 10);
      final after = before.copyWith(status: TransferStatus.running);

      expect(after.id, before.id);
      expect(after.hostId, before.hostId);
      expect(after.name, before.name);
      expect(after.remotePath, before.remotePath);
      expect(after.localPath, before.localPath);
      expect(after.direction, before.direction);
    });

    test('leaves omitted fields alone', () {
      final before = task(totalBytes: 10, transferredBytes: 4);
      final after = before.copyWith(transferredBytes: 7);

      expect(after.transferredBytes, 7);
      expect(after.totalBytes, 10);
      expect(after.status, TransferStatus.queued);
    });

    test('can fill in a total that was unknown without losing progress', () {
      final before = task(transferredBytes: 512);
      final after = before.copyWith(totalBytes: 2048);

      expect(after.totalBytes, 2048);
      expect(after.transferredBytes, 512);
      expect(after.progress, 0.25);
    });

    test('keeps a diagnosis unless clearError is asked for', () {
      final failed = task(
        status: TransferStatus.failed,
        error: 'read',
        errorDetail: 'SftpStatusError: Permission denied',
      );

      expect(failed.copyWith(transferredBytes: 1).error, 'read');
      expect(failed.copyWith(transferredBytes: 1).errorDetail, isNotNull);

      // What a retry needs: null already means "unchanged" for every other
      // nullable parameter, so wiping the old diagnosis has to be sayable.
      // 重试所需要的：对其他每个可空参数而言 null 都已经表示「不变」，因此抹掉旧诊断
      // 必须能表达出来。
      final cleared = failed.copyWith(clearError: true);
      expect(cleared.error, isNull);
      expect(cleared.errorDetail, isNull);
    });
  });

  test('withError marks the task failed and keeps what it moved so far', () {
    final running = task(
      totalBytes: 100,
      transferredBytes: 40,
      status: TransferStatus.running,
    );
    final failed = running.withError('write', 'disk full');

    expect(failed.status, TransferStatus.failed);
    expect(failed.error, 'write');
    expect(failed.errorDetail, 'disk full');
    expect(failed.transferredBytes, 40);
    expect(failed.totalBytes, 100);
    expect(failed.progress, 0.4);
  });

  test('a task with no local path is representable, not silently defaulted', () {
    // It fails as localIo when it runs; the model does not invent a path.
    // 它运行时会以 localIo 失败；模型不会凭空造一个路径。
    const orphan = TransferTask(
      id: 't2',
      hostId: 'h1',
      name: 'x',
      remotePath: '/x',
      direction: TransferDirection.upload,
    );
    expect(orphan.localPath, isNull);
    expect(orphan.status, TransferStatus.queued);
  });

  test('the localIo code is a stable string the UI can switch on', () {
    expect(TransferErrorCode.localIo, 'localIo');
  });
}
