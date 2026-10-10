import 'package:flutter_test/flutter_test.dart';
import 'package:neko_mux/services/disk_scan.dart';

/// Guards the disk scanner and its parser.
///
/// The fixtures are real `du` output from this machine rather than invented,
/// because the failure this feature has to avoid is a property of the real
/// output and not of a tidy example:
///
///     $ du -xk -d1 /var/lib/docker
///     du: cannot read directory '/var/lib/docker': Permission denied
///     0	/var/lib/docker
///     $ echo $?
///     1
///
/// Read without the exit status, that is a directory holding nothing — the
/// answer "not here, look elsewhere" for a directory that was never read.
void main() {
  // `du -xk -d1 /home/nekorain`, copied row for row from a real run.
  const realScan = '''
155028908\t/home/nekorain/.local
76917940\t/home/nekorain/Downloads
71139276\t/home/nekorain/.cache
53007976\t/home/nekorain/.config
52020540\t/home/nekorain/ubuntu-share
12507876\t/home/nekorain/AndroidStudioProjects
556827680\t/home/nekorain
''';

  group('the command', () {
    test('never pipes, because the exit status is the point', () {
      // The subtle one. `du … | sort -rn | head` is what anyone would write,
      // and it reports the exit status of `head` — so a scan that could not
      // read half the tree comes back looking like a success.
      final command = diskScanCommand('/var')!;

      expect(
        command,
        isNot(contains('|')),
        reason: 'a pipeline would report the exit status of its last command',
      );
      expect(command, isNot(contains('sort')));
      expect(command, isNot(contains('head')));
    });

    test('asks for one filesystem, one level, sortable units', () {
      final command = diskScanCommand('/var')!;

      expect(
        command,
        contains('-x'),
        reason: 'without it a scan of `/` charges every mounted disk to `/`',
      );
      expect(command, contains('-d1'));
      expect(
        command,
        contains('-k'),
        reason: '`-h` prints `1.5G`, and a caller that wants the largest first '
            'cannot order that',
      );
      expect(command, endsWith("'/var'"));
    });

    test('quotes a path, because a path is not a container name', () {
      expect(diskScanCommand('/mnt/my disk'), "du -x -k -d1 '/mnt/my disk'");
      expect(diskScanCommand("/mnt/it's"), r"du -x -k -d1 '/mnt/it'\''s'");
      expect(
        diskScanCommand(r'/mnt/$(whoami)'),
        r"du -x -k -d1 '/mnt/$(whoami)'",
        reason: 'unquoted, this path would run a command instead of naming a '
            'directory',
      );
    });

    test('refuses a path it cannot quote rather than passing it raw', () {
      expect(
        diskScanCommand('/mnt/two\nlines'),
        isNull,
        reason: 'a POSIX shell cannot carry a newline in single quotes, and '
            'falling back to the unquoted value is the injection this prevents',
      );
    });
  });

  group('the parser', () {
    test('sorts the children largest first', () {
      final scan = parseDiskScan(realScan);

      expect(
        scan.entries.map((e) => e.name),
        ['.local', 'Downloads', '.cache', '.config', 'ubuntu-share',
          'AndroidStudioProjects'],
      );
      expect(scan.entries.first.bytes, 155028908 * 1024);
    });

    test('separates the scanned directory total from its children', () {
      // `du` prints a directory after its contents, so the last line is the
      // total. Listed as a peer it would read as one more consumer, when it is
      // in fact the sum of all of them.
      final scan = parseDiskScan(realScan);

      expect(scan.total, isNotNull);
      expect(scan.total!.path, '/home/nekorain');
      expect(scan.total!.bytes, 556827680 * 1024);
      expect(
        scan.entries.map((e) => e.path),
        isNot(contains('/home/nekorain')),
      );
    });

    test('reads the zero a permission failure produces, without judging it', () {
      // The real shape. `du` prints `0` for a directory it could not read and
      // exits 1; the parser reports the zero it was given. Distinguishing the
      // two is the caller's job, and it can only do that from the exit status —
      // which is why the command is not piped.
      const denied = "0\t/var/lib/docker\n";

      final scan = parseDiskScan(denied);

      expect(scan.total!.bytes, 0);
      expect(scan.entries, isEmpty);
    });

    test('a directory with no children still reports its own total', () {
      final scan = parseDiskScan('4\t/var/empty\n');

      expect(scan.total!.path, '/var/empty');
      expect(scan.entries, isEmpty);
      expect(scan.isEmpty, isTrue);
    });

    test('names an entry by its last segment, root included', () {
      final scan = parseDiskScan(
        '3\t/mnt/data\n2\t/\n1\trelative\n4\t/mnt/trailing/\n',
      );

      expect(scan.entries.map((e) => e.name), ['data', '/', 'relative']);
      expect(
        scan.total!.name,
        'trailing',
        reason: 'a trailing slash must not leave the name empty',
      );
    });

    test('caps the list and says that it did', () {
      final many = [
        for (var i = 0; i < 100; i++) '${i + 1}\t/mnt/dir$i',
        '999\t/mnt',
      ].join('\n');

      final scan = parseDiskScan(many, maxEntries: 10);

      expect(scan.entries, hasLength(10));
      expect(scan.truncated, isTrue);
      expect(
        scan.entries.first.bytes,
        greaterThan(scan.entries.last.bytes),
        reason: 'the cap must keep the largest, not the first ten printed',
      );
    });

    test('a list that fits is not reported as truncated', () {
      final scan = parseDiskScan(realScan, maxEntries: 10);

      expect(scan.truncated, isFalse);
    });

    test('skips lines that are not measurements', () {
      // `du` writes its complaints to stderr, which the caller captures
      // separately — but a parser handed a merged stream must not turn one into
      // a row with a made-up size.
      const mixed = '''
du: cannot read directory '/root/.cache': Permission denied
2048\t/var/log
not a measurement
\t/nothing
-5\t/negative
4096\t/var/lib
''';

      final scan = parseDiskScan(mixed);

      // `/var/lib` is the last line that parses, so it is the one `du` would
      // have printed as the root — the four bad lines produced nothing at all.
      expect(scan.entries.map((e) => e.path), ['/var/log']);
      expect(scan.total!.path, '/var/lib');
    });

    test('keeps a tab inside a path rather than splitting at it', () {
      // The first tab separates; anything after it belongs to the path.
      final scan = parseDiskScan('1\t/mnt/odd\tname\n2\t/mnt\n');

      expect(scan.entries.single.path, '/mnt/odd\tname');
    });

    test('empty output yields nothing rather than throwing', () {
      expect(parseDiskScan(''), isEmpty);
      expect(parseDiskScan('\n\n'), isEmpty);
      expect(parseDiskScan('').total, isNull);
    });
  });
}
