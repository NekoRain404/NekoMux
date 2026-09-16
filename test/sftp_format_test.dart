import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neko_mux/services/sftp_failure.dart';
import 'package:neko_mux/services/sftp_format.dart';

/// Guards the pure half of the SFTP layer: everything here runs without a
/// server, which is the whole point of the file it tests.
///
/// Two things are covered. The display helpers moved out of
/// `services/sftp_service.dart` (`listingItems` / `toFileItem` / `formatMode`),
/// tested here so that the move can be shown to have changed nothing. And the
/// translations the service's own methods wrap, which is where the arithmetic
/// that must not be guessed at lives: which status code means "absent", and
/// which bits of a mode a permission change owns.

/// A mode as it is written everywhere else — `octal(100644)` is the `0o100644` of
/// the comments in `services/sftp_format.dart` and of a `chmod` you would type.
///
/// Dart has no octal literals, and writing 33188 instead would hide exactly the
/// value the assertions are about.
int octal(int digits) => int.parse('$digits', radix: 8);

void main() {
  /// One entry as a server would report it, defaulting to an ordinary 0o644
  /// file.
  SftpName entry(
    String name, {
    bool directory = false,
    int? size = 0,
    int? modified,
    int? mode,
  }) => SftpName(
    filename: name,
    longname: name,
    attr: SftpFileAttrs(
      size: size,
      mode: SftpFileMode.value(
        mode ?? (directory ? octal(40755) : octal(100644)),
      ),
      modifyTime: modified,
    ),
  );

  group('formatMode', () {
    test('renders the nine permission bits, and nothing else', () {
      expect(formatMode(SftpFileMode.value(octal(100644))), 'rw-r--r--');
      expect(formatMode(SftpFileMode.value(octal(40755))), 'rwxr-xr-x');
      expect(formatMode(SftpFileMode.value(octal(100600))), 'rw-------');
      // 0o4755 carries the setuid bit, which the string has no room for: it is
      // nine characters wide by design, and that bit is shown by whatever uses
      // it, not by the listing.
      expect(formatMode(SftpFileMode.value(octal(4755))), 'rwxr-xr-x');
    });

    test('a server that reported no mode yields dashes, not an empty cell', () {
      // The column has to keep its width either way.
      expect(formatMode(null), '---------');
    });
  });

  group('toFileItem', () {
    test('joins the parent path with the entry name', () {
      expect(toFileItem(entry('a.txt'), '/home/root').path, '/home/root/a.txt');
      expect(
        toFileItem(entry('a.txt'), '/home/root/').path,
        '/home/root/a.txt',
      );
      // The root already ends in a slash, so a naive 'parent/name' join would
      // produce '//a.txt'.
      expect(toFileItem(entry('a.txt'), '/').path, '/a.txt');
    });

    test('carries size, kind and mode across', () {
      final file = toFileItem(entry('a.txt', size: 12), '/');
      expect(file.name, 'a.txt');
      expect(file.isDirectory, isFalse);
      expect(file.size, 12);
      expect(file.permissions, 'rw-r--r--');

      final dir = toFileItem(entry('docs', directory: true), '/');
      expect(dir.isDirectory, isTrue);
      expect(dir.permissions, 'rwxr-xr-x');
    });

    test('a missing size is 0 and a missing time is now', () {
      final item = toFileItem(entry('a.txt', size: null), '/');
      expect(item.size, 0);
      expect(
        item.modifiedDate.difference(DateTime.now()).inSeconds.abs(),
        lessThan(5),
      );

      // Seconds on the wire, milliseconds in the model.
      final stamped = toFileItem(entry('a.txt', modified: 1700000000), '/');
      expect(
        stamped.modifiedDate,
        DateTime.fromMillisecondsSinceEpoch(1700000000 * 1000),
      );
    });
  });

  group('listingItems', () {
    test('drops the dot entries, directories first, then names', () {
      final items = listingItems([
        entry('.', directory: true),
        entry('..', directory: true),
        entry('b.txt'),
        entry('zdir', directory: true),
        entry('a.txt'),
      ], '/home');

      expect(items.map((i) => i.name).toList(), ['zdir', 'a.txt', 'b.txt']);
      expect(items.first.path, '/home/zdir');
    });

    test('an empty directory is an empty list, not an error', () {
      expect(listingItems([], '/home'), isEmpty);
    });
  });

  group('mergePermissionBits', () {
    test('keeps the file-type bits the server reported', () {
      // 0o100644 is a regular file; the result has to still be one, or a server
      // that honours the type bits would turn the file into something else.
      expect(mergePermissionBits(octal(100644), octal(755)), octal(100755));
      expect(mergePermissionBits(octal(40755), octal(700)), octal(40700));
      // A symlink stays a symlink.
      expect(mergePermissionBits(octal(120777), octal(777)), octal(120777));
    });

    test('replaces exactly the permission bits', () {
      expect(mergePermissionBits(octal(100600), octal(644)), octal(100644));
      // setuid / setgid / sticky are the caller's to set, not ours to strip.
      expect(mergePermissionBits(octal(100644), octal(4755)), octal(104755));
    });

    test('a whole mode passed as permissions contributes no type bits', () {
      // A caller that hands over what the listing showed (0o100644) gets its
      // permission bits and none of its type bits — otherwise the OR would turn
      // this directory into a regular file.
      expect(mergePermissionBits(octal(40755), octal(100644)), octal(40644));
      // And an absurd input cannot invent a FIFO.
      expect(mergePermissionBits(0, octal(10644)), octal(644));
    });

    test('a server that reported no mode leaves permissions alone', () {
      // Nothing to preserve, so the result is what a chmod sent before the type
      // bits were carried at all: the permission bits by themselves.
      expect(mergePermissionBits(null, octal(644)), octal(644));
      expect(mergePermissionBits(null, octal(750)), octal(750));
    });
  });

  group('isMissingFileError', () {
    test('the protocol status for an absent path means false', () {
      expect(
        isMissingFileError(
          SftpStatusError(SftpStatusCode.noSuchFile, 'No such file'),
        ),
        isTrue,
      );
    });

    test('every other refusal is a failure to look, not an absence', () {
      // The dangerous direction: collapsing any of these to false would let a
      // caller that warns before overwriting decide there is nothing there — and
      // overwrite the very file it meant to protect.
      expect(
        isMissingFileError(
          SftpStatusError(SftpStatusCode.permissionDenied, 'Permission denied'),
        ),
        isFalse,
      );
      expect(
        isMissingFileError(SftpStatusError(SftpStatusCode.failure, 'Failure')),
        isFalse,
      );
      expect(
        isMissingFileError(
          SftpStatusError(SftpStatusCode.opUnsupported, 'Unsupported'),
        ),
        isFalse,
      );
    });

    test('an error that is not a status at all is not an absence either', () {
      expect(isMissingFileError(SftpError('Unexpected reply')), isFalse);
      expect(isMissingFileError(Exception('socket is closed')), isFalse);
      expect(isMissingFileError('No such file'), isFalse);
    });
  });

  group('classifySftpConnectFailure', () {
    test('a failure is read into the code the page turns into a sentence', () {
      // The spelling `Socket.connect` actually produces, and the one this
      // classifier used to miss: it tested for `timeout` alone, so a timed-out
      // SFTP connection was reported as a generic connect failure.
      expect(
        classifySftpConnectFailure(
          'SocketException: Connection timed out, host: 10.0.0.1, port: 22',
        ),
        SftpFailure.connTimeout,
      );
      // The other spelling is still matched, so a server or SDK that words it
      // this way keeps the timeout code.
      expect(
        classifySftpConnectFailure('SocketException: Connection timeout'),
        SftpFailure.connTimeout,
      );
      expect(
        classifySftpConnectFailure('SSHAuthError: authentication failed'),
        SftpFailure.authFailed,
      );
      expect(
        classifySftpConnectFailure('SocketException: Connection refused'),
        SftpFailure.connRefused,
      );
      expect(
        classifySftpConnectFailure('SocketException: Unknown host example'),
        SftpFailure.hostUnreachable,
      );
    });

    test('anything unrecognised is reported as connect, never thrown', () {
      // A message this app has never seen still has to yield a code: throwing
      // here would put a raw transport error in front of the user instead.
      expect(
        classifySftpConnectFailure('something nobody has seen'),
        SftpFailure.connect,
      );
      expect(classifySftpConnectFailure(''), SftpFailure.connect);
    });
  });

  group('stallDetailText', () {
    test("the server's own complaint wins over a number", () {
      expect(
        stallDetailText(
          const Duration(seconds: 30),
          'SftpStatusError: Failure(code 4)',
        ),
        'SftpStatusError: Failure(code 4)',
      );
    });

    test('with nothing to report, the detail is a number, not a sentence', () {
      // This string is not translated anywhere: it is the deadline in
      // milliseconds, and a user reads the sentence the i18n table picked for
      // the failure code.
      expect(
        stallDetailText(const Duration(seconds: 30)),
        'no progress for 30000ms',
      );
      expect(
        stallDetailText(const Duration(milliseconds: 250)),
        'no progress for 250ms',
      );
    });
  });
}
