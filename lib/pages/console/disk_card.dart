import 'package:flutter/material.dart';

import '../../core/format/bytes.dart';
import '../../core/i18n/strings.dart';
import '../../core/theme/app_fonts.dart';
import '../../services/disk_usage.dart';
import '../../widgets/app_ui.dart';

/// How full a filesystem has to be before it is drawn as a warning.
///
/// 85% is where a filesystem stops being able to absorb anything: logs, a
/// package upgrade, a database checkpoint. Below it a bar is information; above
/// it a bar is a thing to act on, and the colour is what makes that distinction
/// readable at a glance from across a room.
const double _warnPercent = 85;

/// How full before the bar is drawn in the theme's error colour.
const double _criticalPercent = 95;

/// The disk panel: the filesystems a phone user needs to see, fullest first.
///
/// It exists because "disk full" is the failure that takes a server down while
/// the app's CPU and memory charts look perfectly calm — those are the two
/// numbers a console usually shows and the two that tell you nothing about it.
///
/// Only the fullest few are drawn. A host has a dozen mounts and a phone has one
/// screen; the question is "is anything about to fill", so the list is ordered by
/// that and cut where it stops being an answer.
class DiskCard extends StatelessWidget {
  /// Filesystems to show, already ordered by fullness.
  final List<DiskUsage> filesystems;

  /// How many to draw. The rest are counted, not hidden silently.
  final int maxRows;

  /// Called when a filesystem is tapped, to show what is using its space.
  ///
  /// Null leaves the rows inert, which is what a caller with no session to
  /// scan over should pass — a chevron that opens nothing is worse than no
  /// chevron.
  final void Function(DiskUsage filesystem)? onTap;

  const DiskCard({
    super.key,
    required this.filesystems,
    this.maxRows = 3,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    if (filesystems.isEmpty) return const SizedBox.shrink();

    final shown = filesystems.take(maxRows).toList();
    final hidden = filesystems.length - shown.length;

    return AppCard(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.storage_outlined, color: cs.primary, size: 16),
              const SizedBox(width: 8),
              Text(
                t('disk_usage'),
                style: TextStyle(
                  color: cs.onSurface,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (hidden > 0) ...[
                const Spacer(),
                Text(
                  t('disk_more_filesystems').replaceAll('{0}', '$hidden'),
                  style: TextStyle(
                    color: cs.onSurface.withValues(alpha: 0.45),
                    fontSize: 11,
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 10),
          for (final filesystem in shown) ...[
            if (onTap == null)
              _DiskRow(filesystem: filesystem)
            else
              InkWell(
                onTap: () => onTap!(filesystem),
                borderRadius: BorderRadius.circular(6),
                child: _DiskRow(filesystem: filesystem, tappable: true),
              ),
            if (filesystem != shown.last) const SizedBox(height: 10),
          ],
        ],
      ),
    );
  }
}

/// One filesystem: where it is mounted, how full, and a bar.
class _DiskRow extends StatelessWidget {
  final DiskUsage filesystem;

  /// Whether to draw the chevron that says this row opens something.
  final bool tappable;

  const _DiskRow({required this.filesystem, this.tappable = false});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final percent = filesystem.usedPercent;
    // Unknown is drawn as unknown — a muted bar with no fill and "—" where the
    // number would be. A missing size shown as 0% is the kind of wrong reading
    // a user acts on.
    final colour = percent == null
        ? cs.onSurface.withValues(alpha: 0.3)
        : percent >= _criticalPercent
        ? cs.error
        : percent >= _warnPercent
        ? const Color(0xFFD29922)
        : cs.primary;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                filesystem.mountPoint,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: cs.onSurface,
                  fontSize: 12,
                  fontFamily: AppFonts.mono,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Text(
              '${formatBytes(filesystem.usedBytes)} / '
              '${formatBytes(filesystem.totalBytes)}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: cs.onSurface.withValues(alpha: 0.5),
                fontSize: 10,
                fontFamily: AppFonts.mono,
              ),
            ),
            const SizedBox(width: 8),
            Text(
              percent == null ? '—' : '${percent.toStringAsFixed(0)}%',
              maxLines: 1,
              style: TextStyle(
                color: colour,
                fontSize: 12,
                fontWeight: FontWeight.w700,
                fontFamily: AppFonts.mono,
              ),
            ),
            if (tappable) ...[
              const SizedBox(width: 2),
              Icon(
                Icons.chevron_right,
                size: 15,
                color: cs.onSurface.withValues(alpha: 0.35),
              ),
            ],
          ],
        ),
        const SizedBox(height: 4),
        ClipRRect(
          borderRadius: BorderRadius.circular(2),
          child: LinearProgressIndicator(
            // A null value is the indeterminate state, which would animate — so
            // an unknown filesystem gets a zero-length fill instead, and its
            // "—" above says why.
            value: (percent ?? 0) / 100,
            minHeight: 4,
            backgroundColor: cs.onSurface.withValues(alpha: 0.08),
            valueColor: AlwaysStoppedAnimation<Color>(colour),
          ),
        ),
      ],
    );
  }
}
