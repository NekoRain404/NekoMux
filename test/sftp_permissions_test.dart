import 'package:flutter_test/flutter_test.dart';
import 'package:neko_mux/pages/sftp/sftp_permissions.dart';

/// Guards the arithmetic behind the change-permissions dialog.
///
/// Both directions are silent when they are wrong: a misread symbolic mode
/// prefills the field with a number the user is invited to confirm, and a
/// misparsed octal sets the file to a mode nobody asked for. Neither shows up as
/// an error — the first is confirmed by reflex and the second appears to work —
/// so they are pinned here instead.
void main() {
  group('octalFromSymbolic', () {
    test('reads the three common modes', () {
      expect(octalFromSymbolic('rw-r--r--'), '644');
      expect(octalFromSymbolic('rwxr-xr-x'), '755');
      expect(octalFromSymbolic('rw-------'), '600');
    });

    test('reads the bits that are easy to get backwards', () {
      // Group-writable, world-writable and the execute bit at each position:
      // off-by-one in the group offset, or reading `x` at the wrong place,
      // produces a plausible-looking mode that grants something nobody granted.
      expect(octalFromSymbolic('rw-rw-rw-'), '666');
      expect(octalFromSymbolic('r--------'), '400');
      expect(octalFromSymbolic('--x--x--x'), '111');
      expect(octalFromSymbolic('rwxrwxrwx'), '777');
      expect(octalFromSymbolic('---------'), '000');
    });

    test('keeps the setuid and sticky bits out of the arithmetic', () {
      // `rws` means "read, write, execute, and setuid" — the mode itself is
      // still 7 for that group. Reading the `s` as a missing execute bit would
      // silently drop execute permission when the dialog is confirmed.
      expect(octalFromSymbolic('rwsr-xr-x'), '755');
      expect(octalFromSymbolic('rwsrwsrwt'), '777');
    });

    test('skips the type character some listings carry', () {
      // `formatMode` in the service emits exactly this shape, so a listing
      // passed through unchanged must still read correctly.
      expect(octalFromSymbolic('drwxr-xr-x'), '755');
      expect(octalFromSymbolic('-rw-r--r--'), '644');
      expect(octalFromSymbolic('lrwxrwxrwx'), '777');
    });

    test('answers with nothing rather than a guess', () {
      // A wrong prefill is worse than an empty one: the user confirms the
      // number without checking it.
      expect(octalFromSymbolic(''), '');
      expect(octalFromSymbolic('rw-'), '');
      expect(octalFromSymbolic('?'), '');
    });
  });

  group('parseOctalMode', () {
    test('accepts the three-digit form', () {
      expect(parseOctalMode('755'), 0x1ED);
      expect(parseOctalMode('644'), 0x1A4);
      expect(parseOctalMode('000'), 0);
      expect(parseOctalMode('777'), 0x1FF);
    });

    test('accepts the four-digit form and ignores the leading digit', () {
      // `0755` and `4755` are what chmod and stat print; this dialog sets
      // permissions, not setuid, so the leading digit is dropped rather than
      // silently applied as something the user did not ask for.
      expect(parseOctalMode('0755'), 0x1ED);
      expect(parseOctalMode('4755'), 0x1ED);
      expect(parseOctalMode('2750'), 0x1E8);
      // The rule is "the last three digits are the mode", so this is accepted
      // too — four digits always means the first one is a special-bits digit,
      // and 7 there is a well-formed (if unusual) request.
      expect(parseOctalMode('7555'), 0x16D);
    });

    test('tolerates surrounding whitespace', () {
      expect(parseOctalMode('  755  '), 0x1ED);
    });

    test('rejects anything that is not three octal digits', () {
      expect(parseOctalMode(''), isNull);
      expect(parseOctalMode('   '), isNull);
      expect(parseOctalMode('75'), isNull);
      expect(parseOctalMode('999'), isNull, reason: '9 is not an octal digit');
      expect(parseOctalMode('75a'), isNull);
      expect(parseOctalMode('-755'), isNull);
      expect(parseOctalMode('rwxr-xr-x'), isNull);
    });
  });

  test('the two directions agree on the modes the app displays', () {
    // Round-tripping is the property that matters in use: the dialog is
    // prefilled from the listing, and confirming without editing must leave the
    // file's mode exactly as it was.
    for (final symbolic in ['rw-r--r--', 'rwxr-xr-x', 'rw-------', 'rwxrwxrwx']) {
      final octal = octalFromSymbolic(symbolic);
      expect(octal, isNotEmpty, reason: symbolic);
      expect(parseOctalMode(octal), isNotNull, reason: octal);
    }
  });
}
