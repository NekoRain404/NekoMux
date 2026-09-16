// The pure half of the SFTP layer: values in, values out, no session anywhere.
//
// Everything here is a plain function over what the server reported, so a page
// can render a listing without a connection and a test can check the result
// without pretending to have one. That is why it is a file of its own rather
// than a private corner of `services/sftp_service.dart`: nothing in it can fail
// for a reason a caller has to catch.
//
// It holds two kinds of transformation. The display ones — `listingItems`,
// `toFileItem` and `formatMode` — turn what a directory listing reported into the
// rows the file list shows, which is a rendering rule and reads as one. The
// other kind is what the service's methods that need a server are thin wrappers
// around: a status code turned into "there is no such file"
// (`isMissingFileError`), a mode turned into the mode a permission change sends
// (`mergePermissionBits`), a raw connect failure turned into a code
// (`classifySftpConnectFailure`, the counterpart of `classifySshFailure` in
// `services/ssh_service.dart`), and the one line of text this app writes at all
// (`stallDetailText` — a number, never a sentence in any language).
//
// They are split out of `services/sftp_service.dart`, which is at its 800-line
// limit (`CLAUDE.md`): it gained three methods in this change and could not have
// kept its size if these had stayed behind.

import 'package:dartssh2/dartssh2.dart';

import '../models/file_item.dart';
import 'sftp_failure.dart';

/// The rows a file list shows for [entries], the listing of [path]: dot entries
/// dropped, directories first, then files, each group alphabetical.
///
/// The ordering is part of the answer rather than something the page applies
/// afterwards: it is the same list the user is about to act on, and a caller that
/// sorted it differently would be showing a different directory.
List<FileItem> listingItems(List<SftpName> entries, String path) {
  final items = entries
      .where((e) => e.filename != '.' && e.filename != '..')
      .map((e) => toFileItem(e, path))
      .toList();
  items.sort((a, b) {
    if (a.isDirectory && !b.isDirectory) return -1;
    if (!a.isDirectory && b.isDirectory) return 1;
    return a.name.compareTo(b.name);
  });
  return items;
}

/// Convert an [SftpName] entry to a [FileItem] for the UI.
///
/// A missing modification time becomes `now`, which is the one opinionated thing
/// here: a server that reports no time at all still has to yield a sortable
/// [FileItem.modifiedDate], and `DateTime.now()` was what the file list already
/// showed for those.
FileItem toFileItem(SftpName entry, String parentPath) {
  final a = entry.attr;
  final fullPath = parentPath.endsWith('/')
      ? '$parentPath${entry.filename}'
      : '$parentPath/${entry.filename}';

  return FileItem(
    name: entry.filename,
    path: fullPath,
    isDirectory: a.isDirectory,
    size: a.size ?? 0,
    permissions: formatMode(a.mode),
    modifiedDate: a.modifyTime != null
        ? DateTime.fromMillisecondsSinceEpoch(a.modifyTime! * 1000)
        : DateTime.now(),
  );
}

/// Format an [SftpFileMode] into a Unix-like permission string (e.g. "rwxr-xr--").
///
/// The type bits are deliberately not rendered: `SftpFileMode.value` carries
/// them, and a nine-character string is what the file list has room for. A
/// server that reports no mode at all yields a string of dashes rather than an
/// empty cell, so the column stays aligned.
String formatMode(SftpFileMode? mode) {
  if (mode == null) return '---------';
  return '${mode.userRead ? 'r' : '-'}${mode.userWrite ? 'w' : '-'}${mode.userExecute ? 'x' : '-'}'
      '${mode.groupRead ? 'r' : '-'}${mode.groupWrite ? 'w' : '-'}${mode.groupExecute ? 'x' : '-'}'
      '${mode.otherRead ? 'r' : '-'}${mode.otherWrite ? 'w' : '-'}${mode.otherExecute ? 'x' : '-'}';
}

/// The bits of a mode that say what an entry *is*: 0o170000.
///
/// Mirrors dartssh2's own mask (`sftp_file_attrs.dart`, the private
/// `_ModeFlags.mask`), which is not exported, so it is restated here with the
/// name of what it means.
const int sftpFileTypeMask = 0xF000;

/// The bits of a mode a permission change owns: 0o7777 — the nine permission
/// bits plus setuid / setgid / sticky.
const int sftpPermissionMask = 0xFFF;

/// The mode a permission change should send: the file-type bits of
/// [existingMode] kept, its permission bits replaced by [permissions].
///
/// The type bits have to survive because a mode is one 32-bit word on the wire,
/// and its top four bits answer "what is this" rather than "who may touch it". A
/// `chmod` that sent only permission bits would be asking the server to change
/// the kind of the entry as well; every server this was tried against ignores
/// those bits, but a server that does not is under no obligation to warn before
/// turning a regular file into a FIFO. Keeping them costs one AND.
///
/// [permissions] is masked to [sftpPermissionMask], so a caller that hands over a
/// whole mode copied from a listing (`0o100644`) contributes its permission bits
/// and none of its type bits — the wrong direction, but not a second way to set
/// them.
///
/// [existingMode] is null when the server reported no mode at all. There is then
/// nothing to preserve and the result is the permission bits alone: exactly what
/// a chmod sent before this function existed, and all such a server can have been
/// expecting.
int mergePermissionBits(int? existingMode, int permissions) =>
    ((existingMode ?? 0) & sftpFileTypeMask) |
    (permissions & sftpPermissionMask);

/// Whether [error] is the server saying there is no such file, as opposed to a
/// real failure.
///
/// Only the protocol's own status counts — `SSH_FX_NO_SUCH_FILE`, the one answer
/// a server gives that means the path is absent rather than inaccessible. The
/// rest of the vocabulary (`SSH_FX_PERMISSION_DENIED`, `SSH_FX_FAILURE`, a
/// dropped connection) is a failure to *look*, and a caller that warns before
/// overwriting must not read that as "nothing is there": the dangerous direction
/// is the one that overwrites a file the user was never asked about.
///
/// Matching on the message text instead would be a guess about a server's wording,
/// and the guess would land in exactly that dangerous direction.
bool isMissingFileError(Object error) =>
    error is SftpStatusError && error.code == SftpStatusCode.noSuchFile;

/// The technical detail to report for a transfer that stopped moving bytes.
///
/// [cause] — what dartssh2's own listener reported, when anything did — wins,
/// because it is the server's own complaint and the convention here is that
/// [SftpException.detail] is the underlying error's rendering and never a
/// sentence this app wrote. The fallback covers the case where there is no such
/// error at all, which is a connection that has gone away entirely: a number,
/// not a translation, which is also why it is not a string the i18n table owns.
String stallDetailText(Duration timeout, [Object? cause]) => cause != null
    ? cause.toString()
    : 'no progress for ${timeout.inMilliseconds}ms';

/// Classify a raw connect failure into a code the presentation layer can turn
/// into a sentence in the user's own language.
///
/// Reading a transport error is protocol knowledge and stays here; wording it is
/// not, and moved to the i18n table. The predicates and their order are the ones
/// the message-based translation used, so which code a given failure yields is
/// unchanged — only the words are, with the one exception noted below.
///
/// That exception is the second spelling of a timeout. A socket timeout reads
/// `SocketException: Connection timed out, host: …, port: …` — `Socket.connect`
/// never says `timeout` — so the old predicate matched none of the failures it
/// existed for, and every timed-out SFTP connection was reported as a generic
/// `SftpFailure.connect` instead of a timeout. `classifySshFailure` has matched
/// both spellings all along; this is the same two-part test, and the sites that
/// read this code reach the same sentence from either connection path.
///
/// The counterpart of `SshFailure`'s `classifySshFailure`, and public for the same
/// reason: a code is something a caller can test without opening a socket.
SftpFailure classifySftpConnectFailure(String error) {
  final lower = error.toLowerCase();
  if (lower.contains('timeout') || lower.contains('timed out')) {
    return SftpFailure.connTimeout;
  }
  if (lower.contains('auth') ||
      lower.contains('password') ||
      lower.contains('key')) {
    return SftpFailure.authFailed;
  }
  if (lower.contains('refused')) return SftpFailure.connRefused;
  if (lower.contains('resolve') || lower.contains('unknown host')) {
    return SftpFailure.hostUnreachable;
  }
  return SftpFailure.connect;
}
