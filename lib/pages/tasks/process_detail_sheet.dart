import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/i18n/strings.dart';
import '../../core/theme/app_fonts.dart';
import '../../widgets/app_ui.dart';

/// The colour a CPU or memory percentage is shown in.
///
/// Shared with the list rows, so a process that reads as alarming in the list
/// reads the same in its detail — two scales for one number is how a screen ends
/// up contradicting itself.
Color processUsageColor(BuildContext context, double percent) {
  final cs = Theme.of(context).colorScheme;
  if (percent >= 50) return cs.error;
  if (percent >= 10) return const Color(0xFFD29922);
  return cs.primary;
}

/// Shows one process: what it is, what it is using, and how to stop it.
///
/// The command is the reason this sheet exists. A process list can only show a
/// truncated command line, and a long one — the case where the user actually
/// needs to tell two `python` processes apart — is exactly the case that does
/// not fit. It is fully shown here and copies on tap, because the next thing the
/// user does with it is paste it somewhere else.
void showProcessDetailSheet(
  BuildContext context, {
  required Map<String, dynamic> process,
  required VoidCallback onKill,
}) {
  final cs = Theme.of(context).colorScheme;
  final command = process['command'] as String? ?? '';
  final pid = '${process['pid']}';
  final user = process['user'] as String? ?? '';
  final cpu = (process['cpu'] as num?)?.toDouble() ?? 0;
  final mem = (process['mem'] as num?)?.toDouble() ?? 0;

  showModalBottomSheet<void>(
    context: context,
    backgroundColor: cs.surface,
    showDragHandle: true,
    // The command can be arbitrarily long; the sheet scrolls instead of
    // clipping it, which is the whole point of opening this at all.
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(8)),
    ),
    builder: (ctx) => SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(ctx).height * 0.8,
        ),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              InkWell(
                onTap: () {
                  Clipboard.setData(ClipboardData(text: command));
                  ScaffoldMessenger.of(
                    ctx,
                  ).showSnackBar(SnackBar(content: Text(t('copied'))));
                },
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Text(
                        command,
                        style: TextStyle(
                          color: cs.onSurface,
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          fontFamily: AppFonts.mono,
                          height: 1.35,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Icon(
                      Icons.copy,
                      size: 15,
                      color: cs.onSurface.withValues(alpha: 0.4),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  AppBadge(label: 'PID: $pid', color: cs.primary, maxWidth: 180),
                  AppBadge(label: 'USER: $user', color: cs.onSurfaceVariant, maxWidth: 180),
                  AppBadge(
                    label: 'CPU: ${cpu.toStringAsFixed(1)}%',
                    color: processUsageColor(ctx, cpu),
                    maxWidth: 180,
                  ),
                  AppBadge(
                    label: 'MEM: ${mem.toStringAsFixed(1)}%',
                    color: processUsageColor(ctx, mem),
                    maxWidth: 180,
                  ),
                ],
              ),
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: () {
                    Navigator.pop(ctx);
                    onKill();
                  },
                  icon: const Icon(Icons.close, size: 18, color: Colors.white),
                  label: Text(
                    t('kill_process_label'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white),
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: cs.error,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
