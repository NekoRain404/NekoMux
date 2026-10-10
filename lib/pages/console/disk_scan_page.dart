// What is using the space in a directory, and a way to keep asking.
//
// The console reports that a filesystem is nearly full; this answers the
// question that follows. It is the one screen in the app that may take a
// minute to answer — `du` has to walk the tree — so it says what it is doing
// and stays honest about what it could not read.

import 'package:flutter/material.dart';

import '../../core/format/bytes.dart';
import '../../core/i18n/strings.dart';
import '../../core/theme/app_fonts.dart';
import '../../services/disk_scan.dart';
import '../../services/ssh_service.dart';
import '../../widgets/app_ui.dart';

/// The result of asking for one directory's scan.
class DiskScanOutcome {
  /// What the scan measured; null when nothing could be run at all.
  final DiskScan? scan;

  /// Why nothing ran — no connection, or a path that cannot be quoted.
  final String? failure;

  /// What `du` reported it could not read, when it ran but was refused
  /// somewhere in the tree.
  ///
  /// Separate from [failure] because the two mean opposite things: a failure
  /// has no numbers to show, while an incomplete scan has real numbers that
  /// are a *lower bound*. A user who is not told the difference reads a list
  /// of small directories as proof that the space is elsewhere.
  final String? incomplete;

  const DiskScanOutcome({this.scan, this.failure, this.incomplete});

  bool get hasScan => scan != null;
}

/// Runs one scan over [ssh]. Never throws; every failure becomes text.
Future<DiskScanOutcome> loadDiskScan(SshConnection? ssh, String path) async {
  final command = diskScanCommand(path);
  if (command == null) {
    // Refused rather than run unquoted. A path a POSIX shell cannot carry
    // inside single quotes is not one this app will guess at.
    return DiskScanOutcome(failure: t('disk_path_unusable'));
  }
  if (ssh == null || ssh.state != SshConnectionState.connected) {
    return DiskScanOutcome(failure: t('ssh_not_connected'));
  }

  try {
    final result = await ssh.runCommand(command);
    final scan = parseDiskScan(result.stdout);

    // `du` exits non-zero when it could not read something, and still prints
    // what it did measure. That is not the container rule — where a non-zero
    // status means the action did not happen — so the exit status is read for
    // what it means here: the numbers are real, and they are not the whole
    // picture.
    final incomplete = result.ok
        ? null
        : (result.stderr.trim().isNotEmpty
              ? result.stderr.trim()
              : 'exit status ${result.exitCode ?? 'unknown'}');

    return DiskScanOutcome(scan: scan, incomplete: incomplete);
  } catch (e) {
    return DiskScanOutcome(failure: '${t('error')}: $e');
  }
}

/// Reads one directory's scan; provided by the page that owns the connection.
///
/// It takes the path rather than closing over one, so drilling down reuses the
/// same loader instead of each level needing its own.
typedef DiskScanLoader = Future<DiskScanOutcome> Function(String path);

/// Shows the largest children of one directory, and opens the next one down.
class DiskScanPage extends StatefulWidget {
  /// The directory to measure.
  final String path;

  /// Reads a scan for any directory.
  final DiskScanLoader load;

  const DiskScanPage({super.key, required this.path, required this.load});

  @override
  State<DiskScanPage> createState() => _DiskScanPageState();
}

class _DiskScanPageState extends State<DiskScanPage> {
  DiskScanOutcome? _outcome;
  bool _running = true;

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    setState(() => _running = true);
    final outcome = await widget.load(widget.path);
    if (!mounted) return;
    setState(() {
      _outcome = outcome;
      _running = false;
    });
  }

  /// Opens a scan of [entry], pushed rather than replaced so the back button
  /// walks the path the user came down.
  void _drill(DiskEntry entry) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => DiskScanPage(
          path: entry.path,
          load: widget.load,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(
        backgroundColor: cs.surface,
        title: Text(
          widget.path,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: AppFonts.monoText(color: cs.onSurface, fontSize: 15),
        ),
        actions: [
          IconButton(
            icon: Icon(
              Icons.refresh,
              size: 20,
              color: cs.onSurface.withValues(alpha: 0.7),
            ),
            tooltip: t('refresh'),
            onPressed: _running ? null : _run,
          ),
        ],
      ),
      body: _body(cs),
    );
  }

  Widget _body(ColorScheme cs) {
    if (_running && _outcome == null) return const _ScanningView();

    final outcome = _outcome;
    if (outcome == null || !outcome.hasScan) {
      return _ScanFailure(message: outcome?.failure ?? '', onRetry: _run);
    }

    final scan = outcome.scan!;
    return RefreshIndicator(
      color: cs.primary,
      backgroundColor: cs.surface,
      onRefresh: _run,
      child: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          if (outcome.incomplete != null)
            _IncompleteNotice(detail: outcome.incomplete!),
          if (scan.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 80),
              child: Center(
                child: Text(
                  t('disk_nothing_measured'),
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: cs.onSurface.withValues(alpha: 0.6),
                    fontSize: 14,
                  ),
                ),
              ),
            ),
          for (final entry in scan.entries)
            _EntryRow(
              entry: entry,
              // Relative to the largest, so the bars compare within the screen
              // the user is looking at rather than against a filesystem total
              // that is not on screen.
              fraction: scan.entries.first.bytes == 0
                  ? 0
                  : entry.bytes / scan.entries.first.bytes,
              onTap: () => _drill(entry),
            ),
          if (scan.truncated)
            _Footer(text: t('disk_truncated').replaceAll('{0}', '40')),
          if (scan.total != null && !scan.isEmpty)
            _Footer(
              text: '${t('disk_total')}: ${formatBytes(scan.total!.bytes)}',
            ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}

/// Shown while the tree is being walked.
class _ScanningView extends StatelessWidget {
  const _ScanningView();

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(color: cs.primary),
            const SizedBox(height: 18),
            Text(
              t('disk_measuring'),
              textAlign: TextAlign.center,
              style: TextStyle(
                color: cs.onSurface.withValues(alpha: 0.75),
                fontSize: 14,
              ),
            ),
            const SizedBox(height: 8),
            // Said up front rather than discovered by waiting: a full disk
            // holds a lot of files, and a scan that has not finished is not a
            // scan that has failed.
            Text(
              t('disk_measuring_hint'),
              textAlign: TextAlign.center,
              style: TextStyle(
                color: cs.onSurface.withValues(alpha: 0.5),
                fontSize: 12,
                height: 1.4,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Shown when nothing could be measured at all.
class _ScanFailure extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;

  const _ScanFailure({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline, color: cs.error, size: 44),
            const SizedBox(height: 16),
            SelectableText(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: cs.onSurface.withValues(alpha: 0.7),
                fontSize: 13,
              ),
            ),
            const SizedBox(height: 20),
            OutlinedButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh, size: 18),
              label: Text(t('retry')),
              style: OutlinedButton.styleFrom(
                foregroundColor: cs.primary,
                side: BorderSide(color: cs.primary),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The banner that stops a partial answer from reading as a complete one.
class _IncompleteNotice extends StatelessWidget {
  final String detail;

  const _IncompleteNotice({required this.detail});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: cs.secondary.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: cs.secondary.withValues(alpha: 0.35)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.visibility_off_outlined, color: cs.secondary, size: 17),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  t('disk_incomplete'),
                  style: TextStyle(
                    color: cs.secondary,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                SelectableText(
                  detail,
                  style: AppFonts.monoText(
                    color: cs.onSurface.withValues(alpha: 0.7),
                    fontSize: 10.5,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// One directory: its name, its size, and how it compares.
class _EntryRow extends StatelessWidget {
  final DiskEntry entry;
  final double fraction;
  final VoidCallback onTap;

  const _EntryRow({
    required this.entry,
    required this.fraction,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return AppCard(
      margin: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  entry.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppFonts.monoText(
                    color: cs.onSurface,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                formatBytes(entry.bytes),
                style: AppFonts.monoText(
                  color: cs.secondary,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
              Icon(
                Icons.chevron_right,
                color: cs.onSurface.withValues(alpha: 0.4),
                size: 18,
              ),
            ],
          ),
          const SizedBox(height: 7),
          ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: LinearProgressIndicator(
              value: fraction.clamp(0.0, 1.0),
              minHeight: 3,
              backgroundColor: cs.onSurface.withValues(alpha: 0.08),
              valueColor: AlwaysStoppedAnimation(cs.primary),
            ),
          ),
        ],
      ),
    );
  }
}

/// A note under the list.
class _Footer extends StatelessWidget {
  final String text;

  const _Footer({required this.text});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 10, 18, 0),
      child: Text(
        text,
        style: TextStyle(
          color: cs.onSurface.withValues(alpha: 0.45),
          fontSize: 11,
        ),
      ),
    );
  }
}
