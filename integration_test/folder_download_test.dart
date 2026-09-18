import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:neko_mux/models/credential.dart';
import 'package:neko_mux/models/host.dart';
import 'package:neko_mux/models/transfer_task.dart';
import 'package:neko_mux/services/sftp_service.dart';
import 'package:neko_mux/services/sftp_tree.dart';
import 'package:neko_mux/services/transfer_runner.dart';

/// Downloading a whole folder, run ON THE PHONE against a real server tree.
///
/// The promise a folder download makes is not "the bytes arrived" — each file's
/// download is the same code the single-file case uses — it is that the SHAPE
/// arrived: `app/logs/day1.txt` is still under `app/logs/`, two files with the
/// same name in different directories stay apart, and nothing was quietly
/// skipped. A flattening bug, or a walk that missed a branch, passes every
/// byte-level assertion and fails the user.
///
/// Requirements: the transfer fixture container up, `adb reverse tcp:2222
/// tcp:2222`, and the tree created by the command in `integration_test/README.md`.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  const treeRoot = '/config/tree';

  final host = Host(
    id: 'integration',
    alias: 'docker-test-ssh',
    ipAddress: '127.0.0.1',
    port: 2222,
    credentialId: 'integration',
  );
  const credential = Credential(
    id: 'integration',
    name: 'nekotest',
    authType: 0,
    username: 'nekotest',
    secretData: 'nekotest',
  );

  Future<bool> acceptAnyKey(String _) async => true;

  late SftpService sftp;
  late Directory staging;

  setUp(() async {
    sftp = SftpService(
      host: host,
      credential: credential,
      onHostKeyVerify: acceptAnyKey,
    );
    await sftp.connect();
    staging = await Directory.systemTemp.createTemp('folder_download');
  });

  tearDown(() async {
    await sftp.disconnect();
    if (staging.existsSync()) await staging.delete(recursive: true);
  });

  /// Downloads every file a scan found into [staging], reproducing the tree.
  Future<int> downloadTree(TreeScanResult scan) async {
    final runner = TransferRunner(SftpTransferSession(sftp));
    var done = 0;
    for (final file in scan.files) {
      final task = TransferTask(
        id: 'x$done',
        hostId: 'integration',
        name: file.relativePath,
        remotePath: file.remotePath,
        localPath: '${staging.path}/${file.relativePath}',
        direction: TransferDirection.download,
        totalBytes: file.size,
      );
      final outcome = await runner.download(
        task,
        TransferCancelSignal(),
        (_) {},
      );
      expect(
        outcome,
        TransferOutcome.completed,
        reason: '${file.relativePath} did not finish',
      );
      done++;
    }
    return done;
  }

  testWidgets('the scan finds every file, with the shape intact', (
    tester,
  ) async {
    final scan = await scanTree(sftp, treeRoot);

    expect(scan.complete, isTrue, reason: 'stopped at ${scan.failedPath}');
    expect(
      scan.files.map((f) => f.relativePath).toList()..sort(),
      ['app/big.bin', 'app/logs/day1.txt', 'app/logs/day2.txt', 'conf/nginx.conf', 'readme.txt'],
      reason: 'the relative path is what carries the folder shape',
    );
    expect(
      scan.emptyDirectories,
      1,
      reason: 'the fixture has one empty folder, and the user is told about it',
    );
  });

  testWidgets('every file lands at its own path in the tree', (tester) async {
    final scan = await scanTree(sftp, treeRoot);
    final count = await downloadTree(scan);

    expect(count, 5);

    // The tree on disk, not just the file count: a flattened download would
    // have the right number of bytes in the wrong place.
    final onDisk = <String>[];
    await for (final entity in staging.list(recursive: true)) {
      if (entity is File) {
        onDisk.add(entity.path.substring(staging.path.length + 1));
      }
    }
    onDisk.sort();
    expect(onDisk, [
      'app/big.bin',
      'app/logs/day1.txt',
      'app/logs/day2.txt',
      'conf/nginx.conf',
      'readme.txt',
    ]);
  });

  testWidgets('the staged bytes match the server, file for file', (
    tester,
  ) async {
    // Sizes and content: the 150 KB binary is the one that catches a chunking
    // mistake, and the small text files catch a mix-up between siblings — which
    // is what two same-shaped `dayN.txt` files are for.
    final scan = await scanTree(sftp, treeRoot);
    await downloadTree(scan);

    for (final file in scan.files) {
      final remote = await _collect(sftp.downloadStream(file.remotePath));
      final local = await File('${staging.path}/${file.relativePath}').readAsBytes();
      expect(
        local,
        remote,
        reason: '${file.relativePath} differs from the server copy',
      );
    }
  });

  testWidgets('a scan of a folder that is not there fails cleanly', (
    tester,
  ) async {
    // The walk reports rather than throwing: a caller that has already queued
    // three folders must be able to say "this one did not work" about the
    // fourth instead of losing the whole batch.
    final scan = await scanTree(sftp, '/config/no-such-folder');

    expect(scan.complete, isFalse);
    expect(scan.files, isEmpty);
    expect(scan.failedPath, '/config/no-such-folder');
  });
}

Future<List<int>> _collect(Stream<List<int>> stream) async {
  final bytes = <int>[];
  await for (final chunk in stream) {
    bytes.addAll(chunk);
  }
  return bytes;
}
