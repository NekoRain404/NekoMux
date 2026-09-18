import 'dart:io';

import 'package:file_picker/file_picker.dart';

import '../../core/i18n/strings.dart';
import '../../models/transfer_task.dart';
import '../../services/zip_writer.dart';
import 'transfer_io.dart';

/// One folder's worth of staged downloads, ready to be delivered as an archive.
class FolderBatch {
  /// The staging root every task in the batch was written under.
  final String root;

  /// The folder's own name — what the archive is called.
  final String name;

  /// The tasks, in the order the queue holds them.
  final List<TransferTask> tasks;

  const FolderBatch({
    required this.root,
    required this.name,
    required this.tasks,
  });

  /// Whether every file in the batch has arrived.
  ///
  /// A batch with a failure in it is deliberately not offered: an archive built
  /// from a folder that is missing a file looks exactly like a complete one, and
  /// the user would have no way to tell until they opened it on a laptop.
  bool get isComplete =>
      tasks.isNotEmpty && tasks.every((t) => t.status == TransferStatus.done);

  /// Total bytes the batch was expected to move, for a progress readout.
  int get totalBytes =>
      tasks.fold(0, (sum, t) => sum + (t.totalBytes ?? 0));
}

/// Groups [tasks] into the folder downloads they belong to.
///
/// Batches whose files are still moving are included: the row exists from the
/// moment the folder is queued, saying how far along it is, which is the answer
/// to "what is this list of forty rows?" — without it the sheet is a wall of
/// paths with no sign that they are one thing.
List<FolderBatch> folderBatches(List<TransferTask> tasks) {
  final byRoot = <String, List<TransferTask>>{};
  for (final task in tasks) {
    final root = task.folderRoot;
    if (root == null) continue;
    byRoot.putIfAbsent(root, () => []).add(task);
  }
  return [
    for (final entry in byRoot.entries)
      FolderBatch(
        root: entry.key,
        // The name the queue stored, falling back to the directory's own name —
        // a task carries it precisely so this never has to guess from a path.
        name: entry.value.first.folderName ?? _lastSegment(entry.key),
        tasks: entry.value,
      ),
  ];
}

String _lastSegment(String path) {
  final parts = path.split('/').where((p) => p.isNotEmpty).toList();
  return parts.isEmpty ? 'folder' : parts.last;
}

/// How a "save this folder as an archive" attempt ended.
enum FolderSaveOutcome {
  /// The user chose a location and the archive was written there.
  saved,

  /// The user dismissed the save dialog.
  cancelled,

  /// The staged folder could not be read, or the archive could not be built.
  failed,

  /// The archive is larger than the save dialog can take in one piece.
  tooLarge,

  /// The staged folder has no files in it any more.
  empty,
}

/// Zips [batch]'s staged tree and hands it to the system save dialog.
///
/// The archive exists because Android will not let this app write a tree to a
/// user-chosen directory: with only `INTERNET` it cannot open anything under
/// shared storage, and the one mechanism it does have — `saveFile` — takes a
/// single payload. So the folder's files are already on disk in the app's own
/// staging area, and this turns that tree into one file the user can put
/// anywhere.
///
/// The staging tree is left in place afterwards. It is the only copy of what was
/// downloaded, and the row it belongs to still points at it; the queue's own
/// cleanup is what releases it.
Future<FolderSaveOutcome> saveFolderAsZip(
  FolderBatch batch, {
  void Function(int written, int total)? onProgress,
}) async {
  final root = Directory(batch.root);
  if (!root.existsSync()) return FolderSaveOutcome.empty;

  final entries = <ZipEntrySource>[];
  await for (final entity in root.list(recursive: true, followLinks: false)) {
    if (entity is! File) continue;
    entries.add(
      ZipEntrySource(
        path: _archivePath(root.path, entity.path),
        source: entity,
      ),
    );
  }
  if (entries.isEmpty) return FolderSaveOutcome.empty;

  final archive = File('${root.path}.zip');
  try {
    final result = await writeZipToFile(
      output: archive,
      entries: entries,
      onProgress: onProgress,
    );
    if (result.outcome != ZipWriteOutcome.completed) {
      return FolderSaveOutcome.failed;
    }

    // The same ceiling the single-file save honours, and for the same reason:
    // `saveFile` takes the whole payload in memory and copies it again on the
    // platform side, so an archive past this size would be killed rather than
    // delivered.
    final length = await archive.length();
    if (length > transferSaveMaxBytes) return FolderSaveOutcome.tooLarge;

    final saved = await FilePicker.saveFile(
      fileName: '${batch.name}.zip',
      bytes: await archive.readAsBytes(),
      dialogTitle: t('save_folder_zip'),
    );
    // A null answer is the documented "the user cancelled", and the only other
    // one: the platform returns a location or nothing at all.
    return saved == null
        ? FolderSaveOutcome.cancelled
        : FolderSaveOutcome.saved;
  } catch (_) {
    // A staging tree that vanished between the listing and the read, a disk
    // that filled, a provider that refused the write: all the same thing to the
    // user, and none of them a reason to take the queue down.
    return FolderSaveOutcome.failed;
  } finally {
    // The zip is only a courier: the staged tree is the copy the queue owns, and
    // leaving a second one behind doubles what a folder download costs the
    // device.
    try {
      if (archive.existsSync()) await archive.delete();
    } catch (_) {
      // Best effort. A leftover temporary is not worth reporting.
    }
  }
}

/// [file]'s path inside an archive rooted at [root], with forward slashes.
String _archivePath(String root, String file) {
  final relative = file.startsWith('$root/')
      ? file.substring(root.length + 1)
      : file.split('/').last;
  return relative.replaceAll(r'\', '/');
}
