// Measuring what is using the space in a directory tree, and the parser for
// `du` output.
//
// The console already reports that a filesystem is nearly full. This answers
// the question that follows — what is filling it — which until now a phone
// could only settle by opening a terminal and typing a pipeline by hand.

import 'shell_quote.dart';

/// The command that measures the immediate children of [path].
///
/// Null when [path] holds a character that cannot be quoted. The caller must
/// not fall back to the unquoted value: that is the injection this guards
/// against, and refusing to scan is the honest failure.
///
/// `-x` stays on one filesystem. Without it, scanning `/` walks into every
/// mounted disk and charges their contents to `/` — slower, and wrong about
/// where the space went, which is the one thing being asked.
///
/// `-k` reports kibibytes. `-h` would print `1.5G` and nothing can sort that;
/// the numbers become readable units on this side.
///
/// `-d1` limits the output to the immediate children, which bounds the result
/// by the number of subdirectories rather than the number of files: a tree with
/// a million files still answers with one line per child.
///
/// Nothing is piped, and that is deliberate. A pipeline reports the exit status
/// of its *last* command, and this command's exit status is load-bearing: `du`
/// exits 1 when it could not read something, and that is the entire difference
/// between a directory that is empty and one that could not be read. A
/// `| sort -rn | head` here would report success for a scan that never
/// happened.
String? diskScanCommand(String path) {
  final quoted = shellQuote(path);
  // Flags kept separate rather than combined into `-xk`: one letter per
  // decision, so a reader — and a test — can look for the one it cares about
  // without knowing which letters a neighbour happens to bundle with.
  return quoted == null ? null : 'du -x -k -d1 $quoted';
}

/// One directory's measured size.
class DiskEntry {
  /// The full path `du` reported.
  final String path;

  /// Its size in bytes.
  final int bytes;

  const DiskEntry({required this.path, required this.bytes});

  /// The last path segment, for display beside the size.
  ///
  /// Falls back to the whole path when there is no segment to take — the root
  /// `/` has an empty last segment, and a row with no name at all is worse than
  /// one labelled `/`.
  String get name {
    if (path == '/') return '/';
    final trimmed = path.endsWith('/')
        ? path.substring(0, path.length - 1)
        : path;
    final slash = trimmed.lastIndexOf('/');
    return slash < 0 ? trimmed : trimmed.substring(slash + 1);
  }
}

/// What one scan of a directory found.
class DiskScan {
  /// The directory's children, largest first.
  final List<DiskEntry> entries;

  /// The scanned directory's own total, or null when `du` reported none.
  final DiskEntry? total;

  /// Whether there were more children than [entries] carries.
  final bool truncated;

  const DiskScan({
    required this.entries,
    required this.total,
    this.truncated = false,
  });

  /// Whether the directory held nothing measurable.
  bool get isEmpty => entries.isEmpty;
}

/// Reads `du -xk -d1` output into a scan.
///
/// The last line is the scanned directory's own total — `du` prints a directory
/// after its contents — and it is separated out rather than listed. It is the
/// sum of everything above it, and showing it as a peer of its own children
/// would invite reading it as one more consumer of space.
///
/// Rows that do not parse are skipped. Nothing here needs them: a line without
/// a tab, or with a size that is not a number, is not something `du` produced,
/// and guessing at it would put a wrong size next to a real path.
///
/// [maxEntries] caps the list because a directory with a thousand
/// subdirectories is not a list anyone reads. The caller is told the cap was
/// hit rather than left to imply it has everything.
DiskScan parseDiskScan(String output, {int maxEntries = 40}) {
  final parsed = <DiskEntry>[];

  for (final line in output.split('\n')) {
    if (line.isEmpty) continue;
    // The first tab, not the last: `du` writes `<size>\t<path>`, and a path
    // containing a tab must keep it rather than be split at it.
    final tab = line.indexOf('\t');
    if (tab <= 0) continue;

    final kib = int.tryParse(line.substring(0, tab).trim());
    if (kib == null || kib < 0) continue;

    final path = line.substring(tab + 1);
    if (path.isEmpty) continue;

    parsed.add(DiskEntry(path: path, bytes: kib * 1024));
  }

  if (parsed.isEmpty) {
    return const DiskScan(entries: [], total: null);
  }

  final total = parsed.removeLast();
  parsed.sort((a, b) => b.bytes.compareTo(a.bytes));

  return DiskScan(
    entries: parsed.take(maxEntries).toList(),
    total: total,
    truncated: parsed.length > maxEntries,
  );
}
