import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:neko_mux/services/zip_writer.dart';
import 'package:path/path.dart' as p;

/// The ZIP writer, checked against a reader that did not write it.
///
/// Every assertion about the format here goes through the real `unzip`, run as
/// a process: `-t` to check the archive against its own checksums and
/// extraction to compare bytes. Asserting against a reader written beside the
/// writer would prove only that the two agree, and the thing that matters about
/// an archive is that somebody else's tool opens it — a test that read the
/// bytes back with the same mistake on both sides would pass on an archive no
/// user can unpack.
///
/// `unzip` is assumed to be on the PATH. This suite is for the machine the app
/// is built on, not for the phone; see integration_test/ for what runs there.

void main() {
  setUp(() async {
    _temp = await Directory.systemTemp.createTemp('zip_writer_test');
  });

  tearDown(() async {
    if (_temp.existsSync()) await _temp.delete(recursive: true);
  });

  group('an archive of a folder', () {
    test('unzip finds no errors and extracts every byte back', () async {
      final first = await _source('first.txt', utf8.encode('alpha\n'));
      final second = await _source('second.txt', utf8.encode('beta\n'));
      final empty = await _source('empty.bin', const <int>[]);
      final archive = _archive('folder.zip');

      final result = await writeZipToFile(
        output: archive,
        entries: [
          ZipEntrySource(path: 'first.txt', source: first),
          ZipEntrySource(path: 'empty.bin', source: empty),
          ZipEntrySource(path: 'second.txt', source: second),
        ],
      );

      expect(result.outcome, ZipWriteOutcome.completed);
      expect(result.entryCount, 3);
      expect(result.refusedSources, isEmpty);
      expect(result.failureDetail, isNull);
      expect(result.archiveIsReadable, isTrue);
      expect(result.bytesWritten, await archive.length());

      await _expectIntact(archive);
      final extracted = await _extract(archive);
      expect(
        await File(p.join(extracted.path, 'first.txt')).readAsBytes(),
        utf8.encode('alpha\n'),
      );
      expect(
        await File(p.join(extracted.path, 'second.txt')).readAsBytes(),
        utf8.encode('beta\n'),
      );
    });

    test('keeps an empty source as a zero-byte entry', () async {
      final empty = await _source('empty.bin', const <int>[]);
      final archive = _archive('empty.zip');

      final result = await writeZipToFile(
        output: archive,
        entries: [ZipEntrySource(path: 'empty.bin', source: empty)],
      );

      expect(result.outcome, ZipWriteOutcome.completed);
      expect(result.entryCount, 1);

      // The entry surviving at all is the point: a zero-length source is the
      // case a writer that skips empty files, or divides by a size somewhere,
      // gets wrong — and the file it would silently drop is a real one.
      await _expectIntact(archive);
      final extracted = await _extract(archive);
      final written = File(p.join(extracted.path, 'empty.bin'));
      expect(await written.exists(), isTrue);
      expect(await written.length(), 0);

      final listing = await Process.run('unzip', ['-l', archive.path]);
      expect(listing.stdout, contains('empty.bin'));
    });

    test('restores a nested path to the same nested path', () async {
      final nested = await _source('c.txt', utf8.encode('nested\n'));
      final archive = _archive('nested.zip');

      final result = await writeZipToFile(
        output: archive,
        entries: [ZipEntrySource(path: 'a/b/c.txt', source: nested)],
      );

      expect(result.outcome, ZipWriteOutcome.completed);
      final extracted = await _extract(archive);
      final restored = File(p.join(extracted.path, 'a', 'b', 'c.txt'));
      expect(await restored.exists(), isTrue, reason: 'the tree was flattened');
      expect(await restored.readAsBytes(), utf8.encode('nested\n'));
    });

    test('round-trips a file larger than one chunk byte for byte', () async {
      // Three full chunks and a partial fourth. This is the test that catches
      // an off-by-one in the chunking: a chunk boundary dropped, repeated or
      // reordered stays invisible in anything shorter than two chunks.
      final bytes = _noise(200 * 1024);
      final large = await _source('large.bin', bytes);
      final archive = _archive('large.zip');

      final result = await writeZipToFile(
        output: archive,
        entries: [ZipEntrySource(path: 'large.bin', source: large)],
      );

      expect(result.outcome, ZipWriteOutcome.completed);
      await _expectIntact(archive);
      final extracted = await _extract(archive);
      final restored = File(p.join(extracted.path, 'large.bin'));
      expect(await restored.length(), bytes.length);
      expect(await restored.readAsBytes(), bytes);
    });

    test('stores a name that is not ASCII as UTF-8', () async {
      final file = await _source('cafe.txt', utf8.encode('utf8\n'));
      final archive = _archive('utf8.zip');

      final result = await writeZipToFile(
        output: archive,
        entries: [ZipEntrySource(path: 'café.txt', source: file)],
      );

      expect(result.outcome, ZipWriteOutcome.completed);

      // Bit 11 is the format's way of saying the name is UTF-8, and it belongs
      // in both headers: a reader that walks the central directory never sees
      // the local one's copy. Read straight out of the bytes, because this
      // machine's unzip does not honour the bit — it maps names through the OEM
      // codepage whatever the flag or LANG say, and prints `caf├й.txt` for a
      // name that is exactly right. The listing below therefore tells it the
      // charset, which is what a reader ought to have learned from the bit.
      final bytes = await archive.readAsBytes();
      expect(_flagsAt(bytes, 6), _utf8NameFlag, reason: 'local header');
      final central = _centralHeaderOffset(bytes);
      expect(_flagsAt(bytes, central + 8), _utf8NameFlag, reason: 'central');
      final name = utf8.encode('café.txt');
      expect(
        bytes.sublist(30, 30 + name.length),
        name,
        reason: 'the local header should carry the name in UTF-8',
      );

      final listing = await Process.run('unzip', [
        '-O',
        'UTF-8',
        '-l',
        archive.path,
      ]);
      expect(
        listing.stdout,
        contains('café.txt'),
        reason: 'unzip printed:\n${listing.stdout}',
      );
    });
  });

  group('the timestamps', () {
    test("records the source file's own modification time", () async {
      final stamped = await _source('stamped.txt', utf8.encode('x'));
      // Two seconds past the odd minute, so that the format's two-second
      // resolution is exercised without being able to hide an error: the
      // minute and the hour have to survive it.
      await stamped.setLastModified(DateTime(2021, 3, 14, 15, 9, 26));
      final archive = _archive('stamped.zip');

      final result = await writeZipToFile(
        output: archive,
        entries: [ZipEntrySource(path: 'stamped.txt', source: stamped)],
      );

      expect(result.outcome, ZipWriteOutcome.completed);
      final listing = await Process.run('unzip', ['-l', archive.path]);
      expect(
        listing.stdout,
        contains('2021-03-14 15:09'),
        reason: 'unzip printed:\n${listing.stdout}',
      );
    });

    test('clamps a time before 1980 instead of failing', () async {
      final file = await _source('old.txt', utf8.encode('x'));
      final archive = _archive('old.zip');

      // An epoch-zero or clock-skewed file is an ordinary thing to meet on a
      // server, and the format cannot hold a year before 1980 at all. The entry
      // has to be written with the nearest date it can hold — refusing a real
      // file over its date would be trading the file for a rule.
      final result = await writeZipToFile(
        output: archive,
        entries: [
          ZipEntrySource(
            path: 'old.txt',
            source: file,
            modified: DateTime(1970, 1, 1, 12, 30),
          ),
        ],
      );

      expect(result.outcome, ZipWriteOutcome.completed);
      final listing = await Process.run('unzip', ['-l', archive.path]);
      expect(
        listing.stdout,
        contains('1980-01-01 12:30'),
        reason: 'unzip printed:\n${listing.stdout}',
      );
    });
  });

  group('what it refuses', () {
    test('reports a source that is gone rather than throwing', () async {
      final kept = await _source('kept.txt', utf8.encode('kept\n'));
      final gone = File(p.join(_temp.path, 'gone.txt'));
      final archive = _archive('gone.zip');

      // Never created at all, which is the same thing to this writer as one
      // deleted between the caller listing the folder and it reaching the file:
      // the open is where either shows up.
      final result = await writeZipToFile(
        output: archive,
        entries: [
          ZipEntrySource(path: 'gone.txt', source: gone),
          ZipEntrySource(path: 'kept.txt', source: kept),
        ],
      );

      expect(result.outcome, ZipWriteOutcome.incomplete);
      expect(result.refusedSources, ['gone.txt']);
      expect(result.entryCount, 1);
      expect(result.failureDetail, isNull);

      // The refusal is not allowed to cost the rest of the folder: what was
      // written must still be an archive, holding what could be read.
      expect(result.archiveIsReadable, isTrue);
      await _expectIntact(archive);
      final extracted = await _extract(archive);
      expect(
        await File(p.join(extracted.path, 'kept.txt')).readAsBytes(),
        utf8.encode('kept\n'),
      );
      expect(await File(p.join(extracted.path, 'gone.txt')).exists(), isFalse);
    });

    test('refuses a path that would escape the folder it unpacks into', () async {
      final file = await _source('escape.txt', utf8.encode('x'));
      final archive = _archive('escape.zip');

      // Built from a name a remote server chose, so it is the server's spelling
      // and not the caller's intent. Refused rather than rewritten: '..' in an
      // archive is how an unpack writes outside the directory the user picked,
      // and the caller is the only one who can fix the name.
      final result = await writeZipToFile(
        output: archive,
        entries: [
          ZipEntrySource(path: 'a/../escape.txt', source: file),
          ZipEntrySource(path: '/absolute/escape.txt', source: file),
          ZipEntrySource(path: '', source: file),
        ],
      );

      expect(result.outcome, ZipWriteOutcome.incomplete);
      expect(result.refusedSources, [
        'a/../escape.txt',
        '/absolute/escape.txt',
        '',
      ]);
      expect(result.entryCount, 0);
      expect(result.archiveIsReadable, isTrue);
    });
  });

  group('stopping', () {
    test('reports a cancelled write as stopped, not completed', () async {
      final bytes = _noise(256 * 1024);
      final large = await _source('large.bin', bytes);
      final archive = _archive('cancelled.zip');
      var asked = 0;

      final result = await writeZipToFile(
        output: archive,
        entries: [ZipEntrySource(path: 'large.bin', source: large)],
        // False twice, so the write is stopped in the middle of the data rather
        // than before it starts.
        shouldStop: () => asked++ >= 2,
      );

      expect(result.outcome, ZipWriteOutcome.stopped);
      expect(result.entryCount, 0);
      expect(result.archiveIsReadable, isFalse);

      // A partial file, and the caller can tell: it is shorter than the archive
      // would have been, no central directory was written, and the bytes that
      // are there are what the caller is free to delete.
      expect(await archive.exists(), isTrue);
      final onDisk = await archive.length();
      expect(onDisk, lessThan(bytes.length));
      expect(result.bytesWritten, onDisk);
      // And the fragment is not mistaken for an archive by a real reader: a
      // stopped write must not leave something that unpacks into a short but
      // plausible copy of the folder.
      final broken = await Process.run('unzip', ['-t', archive.path]);
      expect(broken.exitCode, isNot(0));
    });
  });

  group('progress', () {
    test('ends at the size of the archive it wrote', () async {
      final bytes = _noise(150 * 1024);
      final large = await _source('large.bin', bytes);
      final archive = _archive('progress.zip');
      final reports = <List<int>>[];

      final result = await writeZipToFile(
        output: archive,
        entries: [ZipEntrySource(path: 'large.bin', source: large)],
        onProgress: (written, total) => reports.add([written, total]),
      );

      expect(result.outcome, ZipWriteOutcome.completed);
      expect(reports, isNotEmpty);
      // Both numbers are bytes of the archive, so the last pair has to be the
      // archive's own size twice: a bar driven by these has to arrive at its
      // end, not near it.
      expect(reports.first, [0, result.bytesWritten]);
      expect(reports.last, [result.bytesWritten, result.bytesWritten]);
      for (var index = 1; index < reports.length; index++) {
        expect(
          reports[index][0],
          greaterThanOrEqualTo(reports[index - 1][0]),
          reason: 'progress went backwards at $index',
        );
      }
      for (final report in reports) {
        expect(report[0], lessThanOrEqualTo(report[1]));
      }
    });
  });
}

/// Bit 11 of the general purpose flags: the entry's name is UTF-8.
///
/// Spelled out here rather than imported, because it is a number the format
/// defines and this test is the one checking that the writer used it.
const int _utf8NameFlag = 0x0800;

/// A file of [bytes] inside the test's own directory, named [name].
Future<File> _source(String name, List<int> bytes) async {
  final file = File(p.join(_temp.path, name));
  await file.writeAsBytes(bytes, flush: true);
  return file;
}

/// The archive to write, inside the test's own directory.
File _archive(String name) => File(p.join(_temp.path, name));

/// The directory `setUp` made for this test.
///
/// A getter over a mutable global rather than a parameter carrying it into
/// every helper: the alternative is threading the same directory through seven
/// signatures that have nothing else to say to each other.
late Directory _temp;

/// Pseudo-random bytes, from a fixed seed so a failure can be reproduced.
///
/// Random rather than a pattern because a repeated byte is exactly what a
/// chunking bug can leave in place undetected: a dropped, duplicated or
/// reordered chunk of identical bytes reads the same either way.
Uint8List _noise(int length) {
  final bytes = Uint8List(length);
  final random = Random(20260919);
  for (var index = 0; index < length; index++) {
    bytes[index] = random.nextInt(256);
  }
  return bytes;
}

/// The 16-bit general purpose flags at [offset] in [bytes], little-endian.
int _flagsAt(Uint8List bytes, int offset) =>
    bytes[offset] | (bytes[offset + 1] << 8);

/// Where the first central directory record starts, found by its signature.
///
/// `PK\1\2`. The test needs the offset because the record's own fields — the
/// flags among them — sit at fixed distances from a start that moves with every
/// preceding entry.
int _centralHeaderOffset(Uint8List bytes) {
  for (var index = 0; index + 3 < bytes.length; index++) {
    if (bytes[index] == 0x50 &&
        bytes[index + 1] == 0x4B &&
        bytes[index + 2] == 0x01 &&
        bytes[index + 3] == 0x02) {
      return index;
    }
  }
  fail('the archive has no central directory record');
}

/// Requires `unzip -t` to accept [archive] — checksums and all.
///
/// Its own words are carried into the failure rather than swallowed: when a
/// reader will not take an archive, its complaint is the most useful thing in
/// the room.
Future<void> _expectIntact(File archive) async {
  final result = await Process.run('unzip', ['-t', archive.path]);
  expect(
    result.exitCode,
    0,
    reason: 'unzip -t said:\n${result.stdout}${result.stderr}',
  );
}

/// Extracts [archive] into a fresh directory and returns it.
Future<Directory> _extract(File archive) async {
  final out = Directory(p.join(_temp.path, 'extracted'));
  await out.create();
  final result = await Process.run('unzip', [
    '-q',
    '-o',
    archive.path,
    '-d',
    out.path,
  ]);
  expect(
    result.exitCode,
    0,
    reason: 'unzip could not extract it:\n${result.stdout}${result.stderr}',
  );
  return out;
}
