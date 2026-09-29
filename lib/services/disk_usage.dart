/// One mounted filesystem's usage, as `df` reported it.
class DiskUsage {
  /// Where it is mounted (`/`, `/var`, `/boot`).
  final String mountPoint;

  /// The device or source behind it (`/dev/sda1`, `overlay`, `tmpfs`).
  final String source;

  /// Used and total size in bytes.
  final int usedBytes;
  final int totalBytes;

  const DiskUsage({
    required this.mountPoint,
    required this.source,
    required this.usedBytes,
    required this.totalBytes,
  });

  /// Usage as a percentage, or null when the total is unknown.
  ///
  /// Null rather than 0 for a filesystem whose size `df` did not report: a full
  /// bar reading "0%" is the kind of wrong number a user acts on.
  double? get usedPercent =>
      totalBytes <= 0 ? null : (usedBytes / totalBytes) * 100;

  /// Whether this filesystem is one whose filling up is an operational problem.
  ///
  /// Memory-backed and read-only pseudo-filesystems are not: a `tmpfs` at 100%
  /// is normal (it grows to its limit by design and holds nothing that was not
  /// put there this boot), and a squashfs is a read-only image. Listing them
  /// beside the real ones crowds a phone screen with bars that mean nothing
  /// while the filesystem that is actually filling up scrolls off it.
  ///
  /// `overlay` is the one source that is judged by where it is mounted rather
  /// than by what it is. On a Docker host, `df` reports one overlay per running
  /// container — a dozen rows with identical sizes that are the container's
  /// view of the host's disk, and none of them is news. Inside a container, the
  /// overlay IS the root filesystem, and it is the single row that matters most.
  /// So: hidden unless it is `/`.
  bool get isWorthShowing {
    if (mountPoint == '/') return true;
    const pseudo = ['tmpfs', 'devtmpfs', 'squashfs', 'ramfs', 'overlay'];
    return !pseudo.contains(source);
  }
}

/// Parses `df -Pk` output.
///
/// `-P` is the POSIX format — one line per filesystem, six columns, no line
/// wrapping — which is why the command asks for it: the default format wraps a
/// long device name onto its own line, and a parser that assumed one line per
/// filesystem would then read the *next* line's numbers against the wrong mount.
/// `-k` makes the sizes kilobytes regardless of the host's `DF_BLOCK_SIZE`.
///
/// Returns an empty list for output with no data rows, which is the honest
/// answer: a `df` that printed nothing has told us nothing, and returning a
/// fabricated row would be worse than returning none.
List<DiskUsage> parseDf(String output, {bool onlyRealFilesystems = true}) {
  final rows = <DiskUsage>[];
  for (final line in output.split('\n')) {
    final parts = line.trim().split(RegExp(r'\s+'));
    // Six columns: Filesystem, 1K-blocks, Used, Available, Use%, Mounted on.
    // A mount point with spaces is split by this, so the last column is
    // reassembled below rather than taken as a single token.
    if (parts.length < 6) continue;
    if (parts[0] == 'Filesystem') continue; // the header

    final totalKb = int.tryParse(parts[1]);
    final usedKb = int.tryParse(parts[2]);
    if (totalKb == null || usedKb == null) continue;

    final mount = parts.sublist(5).join(' ');
    final usage = DiskUsage(
      mountPoint: mount,
      source: parts[0],
      usedBytes: usedKb * 1024,
      totalBytes: totalKb * 1024,
    );
    if (onlyRealFilesystems && !usage.isWorthShowing) continue;
    rows.add(usage);
  }
  return rows;
}

/// [filesystems] ordered by how close to full they are, fullest first.
///
/// The order is the whole value on a phone: the question is not "list my mounts"
/// but "is anything about to fill", and the answer has to be the first thing
/// visible. A filesystem whose usage could not be computed sorts last rather
/// than first — unknown is not urgent.
List<DiskUsage> byFullness(List<DiskUsage> filesystems) {
  final sorted = [...filesystems];
  sorted.sort((a, b) {
    final pa = a.usedPercent;
    final pb = b.usedPercent;
    if (pa == null && pb == null) return a.mountPoint.compareTo(b.mountPoint);
    if (pa == null) return 1;
    if (pb == null) return -1;
    return pb.compareTo(pa);
  });
  return sorted;
}
