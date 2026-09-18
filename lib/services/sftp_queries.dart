import 'package:dartssh2/dartssh2.dart';

import 'sftp_format.dart';

/// The queries that ask the server about a path rather than moving bytes.
///
/// Extracted from [SftpService], which keeps the connection check and the
/// failure code; what lives here is only the part that talks to the SFTP client.
/// They are grouped because they share one shape — one request, one attribute
/// answer, no streaming — and because that shape is what makes them cheap enough
/// for a caller to use as a guard before doing something else.

/// The size the server reports for [path], or null when it reports none.
Future<int?> remoteFileSize(SftpClient sftp, String path) async {
  final attrs = await sftp.stat(path);
  return attrs.size;
}

/// Whether [path] exists, treating "no such file" as an answer rather than as a
/// failure.
///
/// The distinction is why this is not just a `stat` in a try: a caller deciding
/// whether to warn before an overwrite needs "it is not there" to be `false`,
/// while a permission error must still come back as an error — otherwise the
/// warning is skipped for a file the app cannot read, and the overwrite proceeds
/// unannounced.
Future<bool> remotePathExists(SftpClient sftp, String path) async {
  try {
    await sftp.stat(path);
    return true;
  } catch (e) {
    if (isMissingFileError(e)) return false;
    rethrow;
  }
}

/// Replaces the permission bits of [path], keeping the file-type bits the server
/// reported for it: those bits exist only in the server's answer, so the path is
/// stat-ed first.
///
/// [permissions] is an octal-style mask (0o644), not a whole mode — see
/// [mergePermissionBits].
Future<void> setWholeFilePermissions(
  SftpClient sftp,
  String path,
  int permissions,
) async {
  final attrs = await sftp.stat(path);
  final mode = mergePermissionBits(attrs.mode?.value, permissions);
  await sftp.setStat(path, SftpFileAttrs(mode: SftpFileMode.value(mode)));
}

/// The canonical form of [path] as the server resolved it.
///
/// `.`, `..` and a relative name all mean what `sftp-server` says they mean. It
/// does **not** expand `~`: the server has no such expansion, so a path
/// beginning with one fails as a missing directory rather than being silently
/// rewritten to something else.
Future<String> resolveRemotePath(SftpClient sftp, String path) =>
    sftp.absolute(path);
