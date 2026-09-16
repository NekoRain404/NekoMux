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
