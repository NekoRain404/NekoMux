// A streaming, store-only ZIP writer, for handing a downloaded folder back to
// the user as a single file.
//
// Why it exists: a remote folder is downloaded into the app's own staging
// directory, and that is as far as `dart:io` can carry it — holding only the
// INTERNET permission, the app cannot open anything under
// /storage/emulated/0, and the one route to a location the user chose is
// `FilePicker.saveFile`, which takes a single Uint8List. A folder therefore has
// to arrive as one archive.
//
// Store-only is a decision rather than an omission: the bytes are media and
// logs that are already compressed, so deflate would spend a phone's battery to
// make them no smaller, and a hand-written DEFLATE is a large amount of code
// whose mistakes stay invisible until an archive someone depends on will not
// open.
//
// Nothing here holds an archive, or one whole file, in memory: every source is
// read in [zipChunkBytes] pieces and written straight out, and the only
// structure that grows with the input is the central directory — some sixty
// bytes per entry, written last because the format requires it.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// How much of a source file is read, and written, at a time: large enough to
/// disappear into the syscall, small enough that a 500 MB file does not become
/// 500 MB of heap.
const int zipChunkBytes = 64 * 1024;

/// The largest number a ZIP field can hold.
///
/// 0xFFFFFFFF itself is not available — that exact value is the sentinel
/// meaning "the real number is in a ZIP64 extra field", and this writer emits
/// no ZIP64 records.
const int zipMaxFieldValue = 0xFFFFFFFE;

/// The most entries a ZIP can index without ZIP64: the entry counts are 16-bit.
const int zipMaxEntryCount = 0xFFFF;

/// One file to place in the archive, and where it goes inside it.
class ZipEntrySource {
  const ZipEntrySource({
    required this.path,
    required this.source,
    this.modified,
  });

  /// Path the entry takes inside the archive, with forward slashes:
  /// `logs/app.log`, `config/nginx.conf`.
  ///
  /// Built by the caller, because only it knows what the tree it downloaded is
  /// called. A path this writer cannot store is refused and reported in
  /// [ZipWriteResult.refusedSources] rather than rewritten — see [_archiveName].
  final String path;

  /// The local file the bytes come from.
  final File source;

  /// The time to record, or null to record [source]'s own modification time.
  final DateTime? modified;
}

/// How a [writeZipToFile] call ended.
///
/// Four answers rather than a bool, because the caller has four different
/// things to do about them, and "it wrote something" is true of all four.
enum ZipWriteOutcome {
  /// Every entry the caller listed is in the archive.
  completed,

  /// A usable, readable archive, missing entries whose source could not be
  /// read. Worth delivering with a note; see [ZipWriteResult.refusedSources].
  incomplete,

  /// The caller asked to stop. What is on disk is a fragment with no central
  /// directory — no unzip tool will open it, and it is the caller's to delete.
  stopped,

  /// The archive could not be finished: a source stopped reading part way, or
  /// the output refused the bytes. Also a fragment, also the caller's to
  /// delete, and this one carries [ZipWriteResult.failureDetail].
  failed,
}

/// What [writeZipToFile] did, in enough detail to decide what to tell the user.
class ZipWriteResult {
  const ZipWriteResult({
    required this.outcome,
    required this.bytesWritten,
    required this.entryCount,
    this.refusedSources = const <String>[],
    this.failureDetail,
  });

  /// How the write ended.
  final ZipWriteOutcome outcome;

  /// Bytes of the archive that are on disk.
  final int bytesWritten;

  /// Entries written into the central directory — the ones an unzip will find.
  final int entryCount;

  /// Archive paths of the entries that were not written, in the order listed.
  ///
  /// Two things land here, both refused rather than repaired: a source that
  /// could not be opened or is not a regular file — deleted between the caller
  /// listing it and this writer reaching it, most often — and a path that is
  /// not a legal archive path. Neither is fatal, because the rest of the folder
  /// is still worth having, and neither may pass silently either: the outcome
  /// is [ZipWriteOutcome.incomplete] when this is not empty.
  final List<String> refusedSources;

  /// The underlying error's own words, when [outcome] is
  /// [ZipWriteOutcome.failed]; null otherwise.
  final String? failureDetail;

  /// Whether what is on disk is a ZIP at all.
  ///
  /// True for [ZipWriteOutcome.completed] and [ZipWriteOutcome.incomplete],
  /// which differ only in what they contain; false for the two that end before
  /// the central directory is written, because a ZIP is defined by its index —
  /// a fragment without one is not a short archive, it is not an archive.
  bool get archiveIsReadable =>
      outcome == ZipWriteOutcome.completed ||
      outcome == ZipWriteOutcome.incomplete;
}

/// Writes [entries] into [output] as a ZIP archive, streaming both sides.
///
/// Bytes go from each source to the archive as they are read, in
/// [zipChunkBytes] pieces, so the memory this needs does not depend on the size
/// of the folder.
///
/// [onProgress] is called with the bytes written so far and the size the
/// archive is currently going to be — both bytes of the archive rather than of
/// the sources, so the pair is comparable. The total can shrink while this runs,
/// when an entry is refused and its share is subtracted, and never falls below
/// the bytes already written.
///
/// [shouldStop] is polled between chunks and between entries, and is the only
/// way to interrupt this. It is honoured as far as the last byte written: a stop
/// arriving after the final entry has been read does not relabel a finished
/// archive, it just arrives too late. The result says [ZipWriteOutcome.stopped]
/// only when the archive really is unfinished.
///
/// Nothing here throws for a failure it can describe — a missing source, an
/// unreadable one, an output that will not open are all answers in the result —
/// because the caller is a UI that has to say something either way, and an
/// exception out of a file copy tells it less.
Future<ZipWriteResult> writeZipToFile({
  required File output,
  required List<ZipEntrySource> entries,
  void Function(int bytesWritten, int totalBytes)? onProgress,
  bool Function()? shouldStop,
}) async {
  final planned = <_PlannedEntry>[];
  final refused = <String>[];

  for (final entry in entries) {
    // Path and size first, and neither is fatal: a folder that lost a file
    // between the listing and this moment should still deliver the rest.
    final name = _archiveName(entry.path);
    if (name == null || name.length > 0xFFFF) {
      refused.add(entry.path);
      continue;
    }
    FileStat stat;
    try {
      stat = await entry.source.stat();
    } on FileSystemException {
      refused.add(entry.path);
      continue;
    }
    if (stat.type != FileSystemEntityType.file ||
        stat.size > zipMaxFieldValue) {
      refused.add(entry.path);
      continue;
    }
    planned.add(
      _PlannedEntry(
        source: entry.source,
        path: entry.path,
        name: name,
        flags: _nameFlags(name),
        size: stat.size,
        dos: _DosTimestamp(entry.modified ?? stat.modified),
      ),
    );
  }

  // Refused here rather than half-written later: both limits are where the
  // format would have to lie about a number, and an archive that claims to hold
  // more than it can index is worse than one that was never made. ZIP64 is what
  // lifts them, and this writer is not that.
  final totalBytes = _plannedTotal(planned);
  if (planned.length > zipMaxEntryCount) {
    return _failed(
      refused,
      'the archive would hold ${planned.length} entries, past the '
      '$zipMaxEntryCount a ZIP can index without ZIP64',
    );
  }
  if (totalBytes > zipMaxFieldValue) {
    return _failed(
      refused,
      'the archive would be $totalBytes bytes, past the '
      '$zipMaxFieldValue a ZIP can index without ZIP64',
    );
  }

  final RandomAccessFile sink;
  try {
    sink = await output.open(mode: FileMode.write);
  } on FileSystemException catch (error) {
    return _failed(refused, error.toString());
  }
  return _ZipRun(
    sink: sink,
    planned: planned,
    refused: refused,
    totalBytes: totalBytes,
    onProgress: onProgress,
    shouldStop: shouldStop,
  ).write();
}

/// A result for a run that never got as far as writing an archive.
ZipWriteResult _failed(List<String> refused, String detail) => ZipWriteResult(
  outcome: ZipWriteOutcome.failed,
  bytesWritten: 0,
  entryCount: 0,
  refusedSources: List<String>.unmodifiable(refused),
  failureDetail: detail,
);

/// One run of [writeZipToFile], with the state a run accumulates.
///
/// A class rather than one long function because the state outlives any single
/// step: the offset the entry being written started at, the running total, the
/// central directory being built behind it — all of it readable from the step
/// that is running *and* from the one that reports how it ended.
class _ZipRun {
  _ZipRun({
    required this.sink,
    required this.planned,
    required this.refused,
    required int totalBytes,
    this.onProgress,
    this.shouldStop,
  }) : _total = totalBytes;

  /// The archive being written, positioned at the end of what is written.
  final RandomAccessFile sink;
  /// The entries that passed the planning pass, in the caller's order.
  final List<_PlannedEntry> planned;
  /// Paths refused, starting with the ones refused while planning.
  final List<String> refused;
  /// Called with the bytes written so far and the size now planned.
  final void Function(int bytesWritten, int totalBytes)? onProgress;
  /// Polled between chunks; answers whether the caller wants this to stop.
  final bool Function()? shouldStop;
  /// The planned size, shrunk as entries are refused during the run.
  int _total;
  /// Bytes of the archive written so far.
  int _written = 0;
  /// Entries written into the central directory.
  int _entryCount = 0;
  /// The central directory, built as entries are written and flushed last.
  final BytesBuilder _central = BytesBuilder(copy: false);
  /// Set when a source fails part way through, in whatever words it came in.
  String? _failureDetail;
  /// Set once [shouldStop] has answered yes.
  bool _stopped = false;

  /// Writes the whole archive, and says how it went.
  Future<ZipWriteResult> write() async {
    String? failure;
    try {
      _report();
      for (final entry in planned) {
        switch (await _writeEntry(entry)) {
          case _EntryResult.written:
            break;
          case _EntryResult.refused:
            refused.add(entry.path);
            // The refusal comes off the total as well, so the caller's bar does
            // not stall short of the end of an archive that is already as big
            // as it is going to get.
            _total -= entry.plannedBytes;
          case _EntryResult.stopped:
            _stopped = true;
          case _EntryResult.unreadable:
            failure = _failureDetail ?? 'an entry could not be written';
        }
        if (_stopped || failure != null) break;
      }

      // Only reached when every entry that could be written was: a stopped or
      // failed run must not end with a central directory, because that is what
      // would make a fragment read as a complete — and silently short —
      // archive.
      if (!_stopped && failure == null) {
        final central = _central.takeBytes();
        final centralOffset = _written;
        await sink.writeFrom(central);
        await sink.writeFrom(
          _endOfCentralDirectory(
            entries: _entryCount,
            size: central.length,
            offset: centralOffset,
          ),
        );
        _written += central.length + _endOfCentralDirectoryBytes;
        _report();
      }
    } on FileSystemException catch (error) {
      failure = error.toString();
    } finally {
      try {
        await sink.close();
      } on FileSystemException catch (error) {
        // A close that failed may mean buffered bytes never reached the disk,
        // so even a run that had otherwise finished is not reported as one.
        failure ??= error.toString();
      }
    }

    return ZipWriteResult(
      outcome: _stopped
          ? ZipWriteOutcome.stopped
          : failure != null
          ? ZipWriteOutcome.failed
          : refused.isEmpty
          ? ZipWriteOutcome.completed
          : ZipWriteOutcome.incomplete,
      bytesWritten: _written,
      entryCount: _entryCount,
      refusedSources: List<String>.unmodifiable(refused),
      failureDetail: failure,
    );
  }

  /// Opens [entry]'s source, and hands it to [_copy] while it is open.
  ///
  /// Separate from the copy so the two failures stay distinguishable: a source
  /// that will not open has cost the archive nothing and is refused, while one
  /// that fails after its header has gone out has cost it the bytes it
  /// promised, which is fatal — see [_copy].
  Future<_EntryResult> _writeEntry(_PlannedEntry entry) async {
    final RandomAccessFile source;
    try {
      source = await entry.source.open();
    } on FileSystemException {
      return _EntryResult.refused;
    }
    try {
      return await _copy(entry, source);
    } on FileSystemException catch (error) {
      // A read that failed part way, or a sink that would not take the bytes:
      // either way the entry's header is already on disk promising a size and a
      // checksum the archive no longer holds, and no later record can repair
      // that. So the run ends here, unfinished and clearly so.
      _failureDetail = error.toString();
      return _EntryResult.unreadable;
    } finally {
      // Closing a read handle releases a descriptor and nothing else: a failure
      // there says nothing about the bytes already read out of it, and turning
      // a finished archive into a failed one over it would report the wrong
      // thing.
      try {
        await source.close();
      } on FileSystemException {
        // Nothing depends on it.
      }
    }
  }

  /// Writes [entry]'s local header, its data and its central directory record.
  Future<_EntryResult> _copy(
    _PlannedEntry entry,
    RandomAccessFile source,
  ) async {
    final localOffset = _written;
    final header = _localHeader(entry);
    await sink.writeFrom(header);
    _written += header.length;
    _report();

    var crc = _crc32Seed;
    var read = 0;
    while (read < entry.size) {
      if (shouldStop?.call() ?? false) return _EntryResult.stopped;
      final remaining = entry.size - read;
      final chunk = await source.read(
        remaining < zipChunkBytes ? remaining : zipChunkBytes,
      );
      // Nothing left to read, though the file was longer when it was measured:
      // it was truncated while being archived, and the header above already
      // promised the size it used to be.
      if (chunk.isEmpty) break;
      crc = _crc32Update(crc, chunk);
      // Awaited rather than queued: this is the backpressure that keeps a
      // 500 MB source from becoming 500 MB of pending writes.
      await sink.writeFrom(chunk);
      read += chunk.length;
      _written += chunk.length;
      _report();
    }
    if (read != entry.size) {
      _failureDetail =
          '${entry.path} changed size while it was being archived: '
          'the header says ${entry.size} bytes and $read were read';
      return _EntryResult.unreadable;
    }

    // The checksum is the one local-header field that cannot be known when the
    // header is written, and there is no data descriptor behind the entry to
    // carry it — see the file comment on why there is none. So it is patched in
    // now, at the four bytes the format reserves for it; the alternative,
    // reading every source twice so the first pass can checksum it, would
    // double the I/O this exists to keep cheap.
    await sink.setPosition(localOffset + _localHeaderCrcOffset);
    await sink.writeFrom(_le32(crc ^ _crc32Seed));
    await sink.setPosition(_written);

    _central.add(
      _centralHeader(entry: entry, crc: crc ^ _crc32Seed, offset: localOffset),
    );
    _entryCount++;
    return _EntryResult.written;
  }

  /// Tells the caller where the write has got to.
  void _report() => onProgress?.call(_written, _total);
}

/// What one entry's trip through [_ZipRun._writeEntry] produced.
enum _EntryResult {
  /// In the archive.
  written,
  /// Left out, and why is in [ZipWriteResult.refusedSources].
  refused,
  /// The caller asked to stop part way through it.
  stopped,
  /// The run cannot continue past it.
  unreadable,
}

/// One entry that got as far as knowing its size and its timestamps.
class _PlannedEntry {
  _PlannedEntry({
    required this.source,
    required this.path,
    required this.name,
    required this.flags,
    required this.size,
    required this.dos,
  });

  /// The file the bytes come from.
  final File source;
  /// The caller's own spelling of the path, kept for reporting.
  final String path;
  /// The path as the archive stores it, in UTF-8.
  final Uint8List name;
  /// General purpose bit flags for this entry's headers.
  final int flags;
  /// The file's length, taken once, before anything was written.
  final int size;
  /// When it was last changed, in the archive's own date format.
  final _DosTimestamp dos;

  /// Bytes this entry adds to the archive: local header, data, and the central
  /// directory record it will also need.
  int get plannedBytes =>
      _localHeaderBytes + name.length + size + _centralHeaderBytes + name.length;
}

/// [path] as the archive will store it, or null when it is not a usable archive
/// path.
///
/// Two jobs. Backslashes become forward slashes, because the separator is the
/// caller's platform's business and the archive's format says `/`: a tree walked
/// on a machine that spells paths with `\` would otherwise arrive as one file
/// whose name contains them.
///
/// And a path that could escape the directory it is extracted into is refused
/// rather than cleaned up. An empty segment means an absolute path, a trailing
/// separator or a doubled one; a `.` or `..` segment is how an archive writes
/// outside the folder it was unpacked into. Both are caller bugs — these paths
/// are built from names a remote server chose — and a silent rewrite would leave
/// the bug in place while hiding that the archive no longer matches the tree
/// the user asked for.
Uint8List? _archiveName(String path) {
  final normalized = path.replaceAll(r'\', '/');
  for (final segment in normalized.split('/')) {
    if (segment.isEmpty || segment == '.' || segment == '..') return null;
  }
  return utf8.encode(normalized);
}

/// The general purpose flags for an entry named [name].
///
/// Bit 11 says "this name is UTF-8" and is set only when it has to be: the flag
/// is advice to the extracting tool, an accurate one costs nothing, and one set
/// on pure ASCII names has been known to make an old reader second guess a name
/// it could have read. A folder of remote files meets both kinds.
int _nameFlags(Uint8List name) {
  for (final byte in name) {
    if (byte >= 0x80) return _utf8NameFlag;
  }
  return 0;
}

/// [planned]'s total size on disk: headers, data, central directory, and the
/// record that closes it.
int _plannedTotal(List<_PlannedEntry> planned) {
  var total = _endOfCentralDirectoryBytes;
  for (final entry in planned) {
    total += entry.plannedBytes;
  }
  return total;
}

/// The local file header for [entry], checksum field left at zero.
///
/// The sizes are written here because they are known here: each source was
/// measured before anything was written, so no data descriptor is needed to
/// carry them. The checksum is the exception the format leaves — it is known
/// only once the last chunk has gone past, and [_ZipRun._copy] patches it in.
Uint8List _localHeader(_PlannedEntry entry) {
  return (BytesBuilder(copy: false)
        ..add(_le32(_localHeaderSignature))
        ..add(_le16(_versionNeeded))
        ..add(_le16(entry.flags))
        ..add(_le16(_storeMethod))
        ..add(_le16(entry.dos.time))
        ..add(_le16(entry.dos.date))
        ..add(_le32(0))
        ..add(_le32(entry.size))
        // Compressed size, which for a stored entry is the size itself. Two
        // fields, one number, and a reader that finds them different is right
        // to call the archive broken.
        ..add(_le32(entry.size))
        ..add(_le16(entry.name.length))
        // No extra field: nothing here needs one, and the ZIP64 records this
        // writer refuses to emit are the usual reason to want one.
        ..add(_le16(0))
        ..add(entry.name))
      .takeBytes();
}

/// The central directory record for [entry], whose local header sits at
/// [offset] with a final [crc].
Uint8List _centralHeader({
  required _PlannedEntry entry,
  required int crc,
  required int offset,
}) {
  return (BytesBuilder(copy: false)
        ..add(_le32(_centralHeaderSignature))
        // Version made by: 2.0, MS-DOS host. Not a Unix host, deliberately:
        // that would promise the external attributes below are Unix
        // permissions, and this writer carries no permissions across — a folder
        // handed to the user should unpack with that user's own defaults, not
        // whatever mode someone's server happened to have.
        ..add(_le16(_versionMadeBy))
        ..add(_le16(_versionNeeded))
        ..add(_le16(entry.flags))
        ..add(_le16(_storeMethod))
        ..add(_le16(entry.dos.time))
        ..add(_le16(entry.dos.date))
        ..add(_le32(crc))
        ..add(_le32(entry.size))
        ..add(_le32(entry.size))
        ..add(_le16(entry.name.length))
        // Extra field, comment, disk number, internal attributes, external
        // attributes: none of them apply to a file in a single-volume archive,
        // and the format's own default for each is zero.
        ..add(_le16(0))
        ..add(_le16(0))
        ..add(_le16(0))
        ..add(_le16(0))
        ..add(_le32(0))
        ..add(_le32(offset))
        ..add(entry.name))
      .takeBytes();
}

/// The end of central directory record, which is what makes everything before
/// it an archive.
Uint8List _endOfCentralDirectory({
  required int entries,
  required int size,
  required int offset,
}) {
  return (BytesBuilder(copy: false)
        ..add(_le32(_endOfCentralDirectorySignature))
        // Disk numbers, both zero: an archive spanning disks is a format of its
        // own and this is not it.
        ..add(_le16(0))
        ..add(_le16(0))
        ..add(_le16(entries))
        ..add(_le16(entries))
        ..add(_le32(size))
        ..add(_le32(offset))
        // No trailing comment. The field exists so a self-extracting archive
        // can carry its own installer, which a downloaded folder has not.
        ..add(_le16(0)))
      .takeBytes();
}

/// A moment, as the pair of 16-bit fields a ZIP header carries it in.
///
/// Two properties of the format decide the conversion. It has no timezone, so
/// the hour it stores is read back as the extracting machine's own clock, which
/// makes local time the reading that shows the user the hour their file really
/// changed. And it counts years from 1980 in seven bits, so a moment outside
/// 1980-2107 is clamped: an epoch-zero or clock-skewed file is an ordinary
/// thing to meet on a server, and refusing to archive a real file over its date
/// would trade the file for a rule about a field.
class _DosTimestamp {
  /// Packs [when]'s own clock reading into the format's two fields, in which
  /// seconds go in halves: the smallest unit is two seconds, so 26 seconds past
  /// the minute is stored as 13, and the minute and hour above it are untouched.
  _DosTimestamp(DateTime when) {
    final local = when.toLocal();
    var year = local.year;
    if (year < 1980) year = 1980;
    if (year > 2107) year = 2107;
    date = ((year - 1980) << 9) | (local.month << 5) | local.day;
    time = (local.hour << 11) | (local.minute << 5) | (local.second >> 1);
  }

  /// Month, day and year, packed as the format's date field.
  late final int date;
  /// Hour, minute and two-second step, packed as the format's time field.
  late final int time;
}

/// The CRC-32 table for the reflected polynomial 0xEDB88320, built once.
///
/// Built rather than spelled out so the polynomial is the only thing to get
/// right, and it is the one the format names. The table is what makes this
/// cheap enough to run over every byte of a 500 MB file: one array lookup per
/// byte instead of eight shifts.
final Uint32List _crc32Table = _buildCrc32Table();

Uint32List _buildCrc32Table() {
  final table = Uint32List(256);
  for (var index = 0; index < 256; index++) {
    var value = index;
    for (var bit = 0; bit < 8; bit++) {
      value = (value & 1) != 0 ? _crc32Polynomial ^ (value >> 1) : value >> 1;
    }
    table[index] = value;
  }
  return table;
}

/// [crc], a running value, advanced over [bytes].
int _crc32Update(int crc, List<int> bytes) {
  var value = crc;
  for (var index = 0; index < bytes.length; index++) {
    value = _crc32Table[(value ^ bytes[index]) & 0xFF] ^ (value >> 8);
  }
  return value;
}

/// Two little-endian bytes holding [value].
Uint8List _le16(int value) {
  final bytes = Uint8List(2);
  ByteData.view(bytes.buffer).setUint16(0, value, Endian.little);
  return bytes;
}

/// Four little-endian bytes holding [value].
Uint8List _le32(int value) {
  final bytes = Uint8List(4);
  ByteData.view(bytes.buffer).setUint32(0, value, Endian.little);
  return bytes;
}

/// The polynomial the format's CRC-32 is built on, reflected.
const int _crc32Polynomial = 0xEDB88320;

/// The value a CRC-32 starts from and the mask it is inverted with at the end:
/// both halves of one convention, which is why they are one constant.
const int _crc32Seed = 0xFFFFFFFF;

/// Signature of a local file header: `PK\3\4`.
const int _localHeaderSignature = 0x04034B50;
/// Signature of a central directory record: `PK\1\2`.
const int _centralHeaderSignature = 0x02014B50;
/// Signature of the end of central directory record: `PK\5\6`.
const int _endOfCentralDirectorySignature = 0x06054B50;

/// Compression method 0, stored: the bytes in the archive are the file.
const int _storeMethod = 0;
/// Version 2.0: a stored entry alone would need only 1.0, but 2.0 is what every
/// other writer emits and what readers have expected for decades.
const int _versionNeeded = 20;
/// [_versionNeeded] with host system 0 (MS-DOS) in the upper byte — see
/// [_centralHeader] on why not Unix.
const int _versionMadeBy = 20;
/// Bit 11 of the general purpose flags: the entry's name is UTF-8.
const int _utf8NameFlag = 0x0800;

/// Bytes of a local file header before its name: signature and ten fields.
const int _localHeaderBytes = 30;
/// Offset of the CRC-32 field inside a local file header.
const int _localHeaderCrcOffset = 14;
/// Bytes of a central directory record before its name.
const int _centralHeaderBytes = 46;
/// Bytes of an end of central directory record, whose comment is empty.
const int _endOfCentralDirectoryBytes = 22;
