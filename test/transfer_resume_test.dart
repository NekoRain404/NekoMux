import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:neko_mux/models/transfer_task.dart';
import 'package:neko_mux/services/transfer_runner.dart';

/// Resuming a transfer, and — just as important — refusing to.
///
/// A resume that is wrong produces the worst kind of file: the right size, the
/// wrong contents, assembled from two versions of the same name. So the cases
/// below are half about doing it and half about declining to: a remote file that
/// is no longer the one the partial copy is a prefix of must start over, and so
/// must anything whose sizes cannot be reconciled.
class _ResumeSession implements TransferSession {
  _ResumeSession({
    required this.remoteBytes,
    this.remoteSize,
  });

  /// What a download delivers, from the offset it was asked for.
  final List<int> remoteBytes;

  /// What `size()` answers. Defaults to [remoteBytes]' length.
  final int? remoteSize;

  int? uploadOffset;
  final List<int> receivedBytes = [];
  final List<int> downloadOffsets = [];

  @override
  Future<int?> size(String path) async => remoteSize ?? remoteBytes.length;

  @override
  Stream<Uint8List> download(
    String path, {
    int from = 0,
    void Function(int bytesRead)? onProgress,
  }) async* {
    downloadOffsets.add(from);
    var sent = 0;
    for (var i = from; i < remoteBytes.length; i++) {
      yield Uint8List.fromList([remoteBytes[i]]);
      sent++;
      onProgress?.call(sent);
    }
  }

  @override
  Future<void> upload(
    String path,
    Stream<Uint8List> data, {
    int at = 0,
    void Function(int bytesWritten)? onProgress,
  }) async {
    uploadOffset = at;
    var written = 0;
    await for (final chunk in data) {
      receivedBytes.addAll(chunk);
      written += chunk.length;
      onProgress?.call(written);
    }
  }

  @override
  Future<void> close() async {}
}

class _Cancel implements TransferCancelSignal {
  @override
  bool isCancelled = false;

  @override
  void Function()? onCancel;

  @override
  void cancel() => isCancelled = true;

  @override
  void detach() => onCancel = null;
}

TransferTask downloadTask(String localPath, {int? totalBytes}) => TransferTask(
  id: 't1',
  hostId: 'h1',
  name: 'payload.bin',
  remotePath: '/remote/payload.bin',
  localPath: localPath,
  direction: TransferDirection.download,
  totalBytes: totalBytes,
);

TransferTask uploadTask(String localPath, {int? totalBytes}) => TransferTask(
  id: 't2',
  hostId: 'h1',
  name: 'payload.bin',
  remotePath: '/remote/payload.bin',
  localPath: localPath,
  direction: TransferDirection.upload,
  totalBytes: totalBytes,
);

void main() {
  late Directory temp;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('resume_test');
  });

  tearDown(() async {
    if (temp.existsSync()) await temp.delete(recursive: true);
  });

  group('download', () {
    test('a retry asks the server to start where the file ends', () async {
      // The whole feature: 4 of 10 bytes arrived last time, so the next attempt
      // is a read from offset 4 and an append, not a fresh 10.
      final local = File('${temp.path}/part.bin');
      await local.writeAsBytes([0, 1, 2, 3]);

      final session = _ResumeSession(remoteBytes: List.generate(10, (i) => i));
      final runner = TransferRunner(session);
      await runner.download(
        downloadTask(local.path, totalBytes: 10),
        _Cancel(),
        (_) {},
        resume: true,
      );

      expect(session.downloadOffsets, [4]);
      expect(
        await local.readAsBytes(),
        List.generate(10, (i) => i),
        reason: 'the four bytes already on disk must survive and be completed',
      );
    });

    test('a first attempt starts at zero and truncates', () async {
      // A fresh download must not append to whatever the staging path happens to
      // hold: the unique name makes a collision unlikely, not impossible.
      final local = File('${temp.path}/fresh.bin');
      await local.writeAsBytes([9, 9, 9, 9]);

      final session = _ResumeSession(remoteBytes: [1, 2, 3]);
      final runner = TransferRunner(session);
      await runner.download(
        downloadTask(local.path, totalBytes: 3),
        _Cancel(),
        (_) {},
      );

      expect(session.downloadOffsets, [0]);
      expect(await local.readAsBytes(), [1, 2, 3]);
    });

    test('progress is reported against the whole file, not the remainder',
        () async {
      final local = File('${temp.path}/bar.bin');
      await local.writeAsBytes([0, 1, 2, 3]);

      final session = _ResumeSession(remoteBytes: List.generate(10, (i) => i));
      final runner = TransferRunner(session);
      final reported = <int>[];
      await runner.download(
        downloadTask(local.path, totalBytes: 10),
        _Cancel(),
        reported.add,
        resume: true,
      );

      expect(reported, isNotEmpty);
      expect(
        reported.last,
        10,
        reason: 'a bar that ended at 6 would describe the wrong transfer',
      );
      expect(
        reported.first,
        greaterThanOrEqualTo(5),
        reason: 'the first report already includes the resumed prefix',
      );
    });

    test('a remote file that is no longer the same size restarts', () async {
      // The partial copy is a prefix of *some* version of the file. If the
      // server's copy has changed length, nothing here can say it is the same
      // version, and splicing them produces a plausible, wrong file.
      final local = File('${temp.path}/changed.bin');
      await local.writeAsBytes([0, 1, 2, 3]);

      final session = _ResumeSession(
        remoteBytes: List.generate(20, (i) => i),
        remoteSize: 20,
      );
      final runner = TransferRunner(session);
      await runner.download(
        downloadTask(local.path, totalBytes: 10), // what the task expected
        _Cancel(),
        (_) {},
        resume: true,
      );

      expect(session.downloadOffsets, [0]);
      expect(await local.readAsBytes(), hasLength(20));
    });

    test('an unknown remote size restarts rather than guessing', () async {
      final local = File('${temp.path}/unknown.bin');
      await local.writeAsBytes([0, 1, 2, 3]);

      final session = _ResumeSession(remoteBytes: List.generate(10, (i) => i));
      final runner = TransferRunner(session);
      await runner.download(
        downloadTask(local.path), // totalBytes null
        _Cancel(),
        (_) {},
        resume: true,
      );

      expect(session.downloadOffsets, [0]);
    });

    test('a partial file at or past the expected size restarts', () async {
      // Equal means it is already complete (or was thought to be), and larger
      // means it belongs to something else entirely.
      for (final bytes in [
        [0, 1, 2, 3, 4, 5, 6, 7, 8, 9],
        [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11],
      ]) {
        final local = File('${temp.path}/sized.bin');
        await local.writeAsBytes(bytes);
        final session = _ResumeSession(
          remoteBytes: List.generate(10, (i) => i),
        );
        await TransferRunner(session).download(
          downloadTask(local.path, totalBytes: 10),
          _Cancel(),
          (_) {},
          resume: true,
        );
        expect(session.downloadOffsets, [0], reason: 'for ${bytes.length} bytes');
      }
    });
  });

  group('upload', () {
    test('a retry opens the remote at the size it already has', () async {
      // 4 bytes are on the server from the failed attempt, so the writer starts
      // at 4 and the source starts at 4 — the prefix is neither re-sent nor
      // re-written further along than it belongs.
      final local = File('${temp.path}/up.bin');
      await local.writeAsBytes([0, 1, 2, 3, 4, 5, 6, 7, 8, 9]);

      final session = _ResumeSession(remoteBytes: const [], remoteSize: 4);
      final runner = TransferRunner(session);
      await runner.upload(
        uploadTask(local.path, totalBytes: 10),
        _Cancel(),
        (_) {},
        resume: true,
      );

      expect(session.uploadOffset, 4);
      expect(
        session.receivedBytes,
        [4, 5, 6, 7, 8, 9],
        reason: 'the bytes already on the server must not be sent again',
      );
    });

    test('a first attempt opens at zero', () async {
      final local = File('${temp.path}/up2.bin');
      await local.writeAsBytes([0, 1, 2]);

      final session = _ResumeSession(remoteBytes: const [], remoteSize: 0);
      await TransferRunner(session).upload(
        uploadTask(local.path, totalBytes: 3),
        _Cancel(),
        (_) {},
      );

      expect(session.uploadOffset, 0);
      expect(session.receivedBytes, [0, 1, 2]);
    });

    test('a remote copy longer than the local file restarts', () async {
      // There is no offset at which this local file continues that remote one:
      // it is a different, longer file, and the upload is an overwrite.
      final local = File('${temp.path}/up3.bin');
      await local.writeAsBytes([0, 1, 2]);

      final session = _ResumeSession(remoteBytes: const [], remoteSize: 9);
      await TransferRunner(session).upload(
        uploadTask(local.path, totalBytes: 3),
        _Cancel(),
        (_) {},
        resume: true,
      );

      expect(session.uploadOffset, 0);
      expect(session.receivedBytes, [0, 1, 2]);
    });

    test('a local file edited since the task was made restarts', () async {
      // The recorded size is the only thing tying the server's prefix to this
      // file's prefix. Once the local file changes, they are unrelated and the
      // upload starts again rather than mixing two versions.
      final local = File('${temp.path}/up4.bin');
      await local.writeAsBytes([0, 1, 2, 3, 4]);

      final session = _ResumeSession(remoteBytes: const [], remoteSize: 3);
      await TransferRunner(session).upload(
        uploadTask(local.path, totalBytes: 10), // the size it had when queued
        _Cancel(),
        (_) {},
        resume: true,
      );

      expect(session.uploadOffset, 0);
      expect(session.receivedBytes, [0, 1, 2, 3, 4]);
    });

    test('progress is reported against the whole file', () async {
      final local = File('${temp.path}/up5.bin');
      await local.writeAsBytes(List.generate(10, (i) => i));

      final session = _ResumeSession(remoteBytes: const [], remoteSize: 4);
      final reported = <int>[];
      await TransferRunner(session).upload(
        uploadTask(local.path, totalBytes: 10),
        _Cancel(),
        reported.add,
        resume: true,
      );

      expect(reported.last, 10);
    });
  });
}
