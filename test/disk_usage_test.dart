import 'package:flutter_test/flutter_test.dart';
import 'package:neko_mux/services/disk_usage.dart';

/// Guards the `df` parser, against output taken from a real Linux host.
///
/// The sample below is what `df -Pk` actually prints on a small server with a
/// container runtime on it — pseudo-filesystems included, because the interesting
/// mistake is not misreading a number but showing a user a full `tmpfs` bar
/// while the filesystem that is filling up sits below it.
const _realDf = '''
Filesystem     1K-blocks      Used Available Use% Mounted on
overlay         20971520   8388608  12582912  40% /
tmpfs             498704         0    498704   0% /dev
tmpfs             498704      1024    497680   1% /dev/shm
tmpfs             498704         0    498704   0% /sys/fs/cgroup
/dev/sda1        9767600   8000000   1267600  87% /var
tmpfs             498704         0    498704   0% /run
''';

void main() {
  test('reads every real filesystem with its sizes in bytes', () {
    final rows = parseDf(_realDf);

    expect(rows.map((r) => r.mountPoint), containsAll(['/', '/var']));
    final varRow = rows.firstWhere((r) => r.mountPoint == '/var');
    expect(varRow.source, '/dev/sda1');
    expect(varRow.totalBytes, 9767600 * 1024);
    expect(varRow.usedBytes, 8000000 * 1024);
    expect(varRow.usedPercent, closeTo(81.9, 0.1));
  });

  test('leaves out the pseudo-filesystems that cannot be an emergency', () {
    // The rule this encodes: a tmpfs at 100% is normal, and four of them on a
    // phone screen push the one filesystem that matters off it.
    final rows = parseDf(_realDf);

    expect(
      rows.any((r) => r.source == 'tmpfs'),
      isFalse,
      reason: 'memory-backed filesystems are not a "disk full" risk',
    );
  });

  test('a container overlay is judged by where it is, not by what it is', () {
    // On a Docker host, `df` prints one overlay per running container — a dozen
    // identical rows that are the container's view of the host's disk. Inside a
    // container that same source IS the root filesystem, and hiding it would
    // hide the only row that matters. Same source, opposite answers.
    const dockerHost = '''
Filesystem     1K-blocks      Used Available Use% Mounted on
/dev/sda1       20971520   8388608  12582912  40% /
overlay         20971520   8388608  12582912  40% /var/lib/docker/overlay2/abc
overlay         20971520   8388608  12582912  40% /var/lib/docker/overlay2/def
tmpfs             498704         0    498704   0% /run
''';

    final rows = parseDf(dockerHost);

    expect(rows.map((r) => r.mountPoint), ['/']);
    expect(
      rows.single.source,
      '/dev/sda1',
      reason: 'the host’s real root is the row worth showing here',
    );

    // The same overlay, mounted at /, is the root and survives the filter.
    final insideContainer = parseDf(_realDf);
    expect(insideContainer.map((r) => r.mountPoint), contains('/'));
  });

  test('the fullest filesystem comes first', () {
    // What the panel shows first is the answer to "is anything about to fill".
    final sorted = byFullness(parseDf(_realDf));

    expect(sorted.first.mountPoint, '/var');
    expect(sorted.first.usedPercent, closeTo(81.9, 0.1));
  });

  test('a header without data rows is not a filesystem', () {
    expect(
      parseDf('Filesystem 1K-blocks Used Available Use% Mounted on\n'),
      isEmpty,
    );
  });

  test('output that is not df at all yields nothing rather than a guess', () {
    // `df` is not installed, the shell printed an error, the host answered in a
    // language whose columns differ: none of these may become a row.
    expect(parseDf('df: command not found'), isEmpty);
    expect(parseDf(''), isEmpty);
    expect(parseDf('Filesystem 1K-blocks\n'), isEmpty);
  });

  test('a mount point with a space keeps its name', () {
    // Pathological but real — `/mnt/my disk` — and the POSIX format puts it
    // last, so it is reassembled from the remaining columns rather than truncated
    // to its first word.
    final rows = parseDf(
      'Filesystem 1K-blocks Used Available Use% Mounted on\n'
      '/dev/sdb1 1000 500 500 50% /mnt/my disk\n',
    );

    expect(rows.single.mountPoint, '/mnt/my disk');
  });

  test('a row whose sizes cannot be read is dropped, not zeroed', () {
    // A filesystem shown as 0% used because its numbers were unparsable is a
    // wrong number a user acts on.
    final rows = parseDf(
      'Filesystem 1K-blocks Used Available Use% Mounted on\n'
      '/dev/sdc1 unknown unknown unknown - /broken\n'
      '/dev/sdd1 2000 1000 1000 50% /fine\n',
    );

    expect(rows.map((r) => r.mountPoint), ['/fine']);
  });

  test('a filesystem with no reported size has no percentage', () {
    // Not 0%: unknown is its own answer, and it sorts last rather than first.
    final usage = DiskUsage(
      mountPoint: '/x',
      source: '/dev/sdx',
      usedBytes: 10,
      totalBytes: 0,
    );

    expect(usage.usedPercent, isNull);
    expect(byFullness([usage]).single.mountPoint, '/x');
  });
}
