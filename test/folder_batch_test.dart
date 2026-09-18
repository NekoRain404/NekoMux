import 'package:flutter_test/flutter_test.dart';
import 'package:neko_mux/models/transfer_task.dart';
import 'package:neko_mux/pages/transfer/folder_zip.dart';

/// Grouping the queue's rows back into the folders they came from.
///
/// A folder download is a hundred ordinary transfers, so this is the only place
/// that knows they are one thing. Two ways it can be wrong, and both are silent:
/// a batch that swallows unrelated single-file downloads would offer an archive
/// containing files the user never asked to zip, and a batch that misses one of
/// its own files would deliver an archive that looks complete and is not.
TransferTask task({
  required String id,
  String? root,
  String? name,
  TransferStatus status = TransferStatus.done,
}) => TransferTask(
  id: id,
  hostId: 'h1',
  name: name ?? id,
  remotePath: '/remote/$id',
  localPath: '/staging/$id',
  direction: TransferDirection.download,
  folderRoot: root,
  folderName: name,
  status: status,
);

void main() {
  test('every file of one folder lands in one batch', () {
    final batches = folderBatches([
      task(id: 'a', root: '/staging/folder_1_logs', name: 'logs'),
      task(id: 'b', root: '/staging/folder_1_logs', name: 'logs'),
      task(id: 'c', root: '/staging/folder_1_logs', name: 'logs'),
    ]);

    expect(batches, hasLength(1));
    expect(batches.single.tasks, hasLength(3));
    expect(batches.single.name, 'logs');
    expect(batches.single.root, '/staging/folder_1_logs');
  });

  test('two folders stay apart, even with the same name', () {
    // Two `logs` folders from two hosts stage into different roots, and an
    // archive that merged them would be a folder that exists nowhere.
    final batches = folderBatches([
      task(id: 'a', root: '/staging/folder_1_logs', name: 'logs'),
      task(id: 'b', root: '/staging/folder_2_logs', name: 'logs'),
    ]);

    expect(batches, hasLength(2));
    expect(batches.map((b) => b.root).toSet(), hasLength(2));
  });

  test('single-file downloads are not part of any batch', () {
    // The failure this prevents: offering to zip a folder and quietly including
    // whatever else happened to be in the queue.
    final batches = folderBatches([
      task(id: 'single'),
      task(id: 'a', root: '/staging/folder_1_logs', name: 'logs'),
      task(id: 'another'),
    ]);

    expect(batches, hasLength(1));
    expect(batches.single.tasks.map((t) => t.id), ['a']);
  });

  test('a batch is only complete when every file has arrived', () {
    final partial = folderBatches([
      task(id: 'a', root: '/r', name: 'logs'),
      task(id: 'b', root: '/r', name: 'logs', status: TransferStatus.running),
    ]);
    expect(partial.single.isComplete, isFalse);

    final failed = folderBatches([
      task(id: 'a', root: '/r', name: 'logs'),
      task(id: 'b', root: '/r', name: 'logs', status: TransferStatus.failed),
    ]);
    expect(
      failed.single.isComplete,
      isFalse,
      reason: 'an archive built from a folder missing a file looks complete and '
          'is not — the worst thing to hand a user who is backing something up',
    );

    final done = folderBatches([
      task(id: 'a', root: '/r', name: 'logs'),
      task(id: 'b', root: '/r', name: 'logs'),
    ]);
    expect(done.single.isComplete, isTrue);
  });

  test('the total is the sum of what is known, and nulls count as nothing', () {
    final batch = folderBatches([
      TransferTask(
        id: 'a',
        hostId: 'h1',
        name: 'a',
        remotePath: '/r/a',
        localPath: '/l/a',
        direction: TransferDirection.download,
        folderRoot: '/r',
        totalBytes: 100,
      ),
      TransferTask(
        id: 'b',
        hostId: 'h1',
        name: 'b',
        remotePath: '/r/b',
        localPath: '/l/b',
        direction: TransferDirection.download,
        folderRoot: '/r',
      ),
    ]).single;

    expect(batch.totalBytes, 100);
  });

  test('a folder whose name was not recorded falls back to the path', () {
    final batch = folderBatches([
      task(id: 'a', root: '/staging/folder_9_backups'),
    ]).single;

    expect(
      batch.name,
      'folder_9_backups',
      reason: 'better a staging name than a crash or an empty label',
    );
  });
}
