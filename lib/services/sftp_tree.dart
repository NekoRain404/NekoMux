import '../models/file_item.dart';

/// What a recursive delete needs from a connection: the entries under a path,
/// and the removal of one entry.
///
/// Deliberately the narrowest pair that does the job. `SftpService` has a dozen
/// other members and none of them are used here; this is also the seam a test
/// replaces, which is what lets the walk order — the part that decides whether a
/// delete succeeds or fails on the first non-empty directory — be tested without
/// a server.
abstract class SftpTreeOps {
  /// The entries directly under [path].
  Future<List<FileItem>> listDirectory(String path);

  /// Removes one entry: a file, or a directory that is already empty.
  Future<void> deleteFile(String path);
}

/// The outcome of walking a tree.
class TreeDeleteResult {
  /// Entries removed, files and directories together.
  final int removed;

  /// The first failure that stopped the walk, or null when it completed.
  final Object? failure;

  /// The path the walk stopped at, when [failure] is set.
  final String? failedPath;

  const TreeDeleteResult({
    required this.removed,
    this.failure,
    this.failedPath,
  });

  /// Whether every entry was removed.
  bool get complete => failure == null;
}

/// Deletes [path] and everything under it, deepest first.
///
/// The order is the whole point. `SftpService.deleteFile` removes a file or an
/// *empty* directory, so deleting a directory before its contents fails on the
/// first one that is not empty — which is why "delete this folder" could not
/// work at all before this: the only single-path delete the app had does exactly
/// that. Walking depth-first means every directory is empty by the time it is
/// reached.
///
/// [maxEntries] caps the walk. A directory can hold more than a phone can be
/// asked about, and a cap that reports where it stopped is honest; silently
/// deleting "as much as fits" is not, and neither is a walk that appears to hang.
///
/// Failing part-way leaves the tree partly deleted — unavoidable, since the
/// bytes are already gone — so the result reports how far it got rather than
/// pretending to be atomic.
Future<TreeDeleteResult> deleteTree(
  SftpTreeOps ops,
  String path, {
  required bool isDirectory,
  int maxEntries = 2000,
}) async {
  var removed = 0;
  // The path the walk is standing on, updated as it descends, so a failure can
  // name where it happened rather than blaming the directory the user tapped.
  var at = path;

  Future<TreeDeleteResult?> walk(String current, bool directory) async {
    at = current;
    if (!directory) {
      await ops.deleteFile(current);
      removed++;
      return null;
    }

    final entries = await ops.listDirectory(current);
    at = current;
    for (final entry in entries) {
      if (removed >= maxEntries) {
        return TreeDeleteResult(
          removed: removed,
          failure: StateError('entry limit reached'),
          failedPath: current,
        );
      }
      final stopped = await walk(entry.path, entry.isDirectory);
      if (stopped != null) return stopped;
    }

    // Empty now, so this succeeds — the reason the children went first.
    await ops.deleteFile(current);
    removed++;
    return null;
  }

  try {
    final stopped = await walk(path, isDirectory);
    if (stopped != null) return stopped;
    return TreeDeleteResult(removed: removed);
  } catch (e) {
    return TreeDeleteResult(removed: removed, failure: e, failedPath: at);
  }
}

/// One file a scan found, with where it sits relative to the folder scanned.
class TreeFile {
  /// Absolute path on the server, for the transfer to read.
  final String remotePath;

  /// Path inside the scanned folder, `/`-separated and without a leading slash
  /// (`logs/app.log`) — what the file is called in the archive the download
  /// eventually becomes, and what keeps two `app.log` files from colliding.
  final String relativePath;

  /// Size the listing reported, or null when it reported none.
  final int? size;

  const TreeFile({
    required this.remotePath,
    required this.relativePath,
    this.size,
  });
}

/// What a scan found, and what it could not carry.
class TreeScanResult {
  /// Every file under the root, in the order the walk reached them.
  final List<TreeFile> files;

  /// Directories that held nothing.
  ///
  /// Counted rather than silently dropped: an archive built from [files] alone
  /// reproduces the files but not the empty folders between them, and a user who
  /// downloads `conf/` expecting to find `conf/empty-here/` should be told it is
  /// not going to be there.
  final int emptyDirectories;

  /// The first failure that stopped the walk, or null when it finished.
  final Object? failure;

  /// The path the walk stopped at, when [failure] is set.
  final String? failedPath;

  /// True when nothing stopped the walk.
  bool get complete => failure == null;

  const TreeScanResult({
    required this.files,
    this.emptyDirectories = 0,
    this.failure,
    this.failedPath,
  });
}

/// Walks [root] and lists every file under it, with its path relative to [root].
///
/// The mirror of [deleteTree], and for the same reason: a folder download is a
/// walk, and the walk is the part that has to be right. The queue moves files —
/// one remote path to one local path, with no recursion anywhere behind it — so
/// the recursion has to happen before anything is enqueued.
///
/// [maxEntries] caps the scan for the same reason [deleteTree] caps its walk: a
/// directory can hold more than a phone can be asked about, and stopping to say
/// where is honest where quietly taking "as much as fits" is not.
Future<TreeScanResult> scanTree(
  SftpTreeOps ops,
  String root, {
  int maxEntries = 2000,
}) async {
  final files = <TreeFile>[];
  var emptyDirectories = 0;
  var at = root;

  Future<TreeScanResult?> walk(String current, String relative) async {
    at = current;
    final entries = await ops.listDirectory(current);
    at = current;

    if (entries.isEmpty && relative.isNotEmpty) {
      emptyDirectories++;
      return null;
    }

    for (final entry in entries) {
      final childRelative = relative.isEmpty
          ? entry.name
          : '$relative/${entry.name}';
      if (entry.isDirectory) {
        final stopped = await walk(entry.path, childRelative);
        if (stopped != null) return stopped;
        continue;
      }
      if (files.length >= maxEntries) {
        return TreeScanResult(
          files: files,
          emptyDirectories: emptyDirectories,
          failure: StateError('entry limit reached'),
          failedPath: current,
        );
      }
      files.add(
        TreeFile(
          remotePath: entry.path,
          relativePath: childRelative,
          size: entry.size > 0 ? entry.size : null,
        ),
      );
    }
    return null;
  }

  try {
    final stopped = await walk(root, '');
    if (stopped != null) return stopped;
    return TreeScanResult(files: files, emptyDirectories: emptyDirectories);
  } catch (e) {
    return TreeScanResult(
      files: files,
      emptyDirectories: emptyDirectories,
      failure: e,
      failedPath: at,
    );
  }
}
