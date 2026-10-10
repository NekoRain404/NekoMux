// The container page's three non-list states: loading, failed, and empty.
//
// Presentation only, and every input is an argument — the page keeps the
// connection, the list and the error text, and these render them. Extracted
// when the page reached 795 lines: the project's limit is 800, the next change
// to that page would have crossed it, and these were the coherent unit to move
// rather than a block of lines shaved off to fit.

import 'package:flutter/material.dart';

import '../../core/i18n/strings.dart';
import '../../widgets/app_ui.dart';

/// Shown while the first listing is in flight.
class ContainerLoadingView extends StatelessWidget {
  const ContainerLoadingView({super.key});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          CircularProgressIndicator(color: cs.primary),
          const SizedBox(height: 16),
          Text(
            t('loading_containers'),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: cs.onSurface.withValues(alpha: 0.6),
              fontSize: 14,
            ),
          ),
        ],
      ),
    );
  }
}

/// Shown when the listing failed, with both ways out of it.
///
/// Two buttons rather than one because the two failures look identical on
/// screen and need different answers: a dropped session is fixed by
/// reconnecting, while a `docker` that refused the command is fixed by running
/// it again on the session that is already up. Offering only "retry" leaves the
/// first case looping against a dead connection.
class ContainerErrorView extends StatelessWidget {
  /// The failure text, already assembled by the page — it is the only thing
  /// that knows whether this came from the daemon, the socket, or neither.
  final String message;

  /// Establishes a new session and lists again.
  final VoidCallback onReconnect;

  /// Lists again on the current session.
  final VoidCallback onRetry;

  const ContainerErrorView({
    super.key,
    required this.message,
    required this.onReconnect,
    required this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline, color: cs.error, size: 48),
            const SizedBox(height: 16),
            Text(
              message,
              textAlign: TextAlign.center,
              maxLines: 6,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: cs.onSurface.withValues(alpha: 0.6),
                fontSize: 14,
              ),
            ),
            const SizedBox(height: 24),
            Wrap(
              alignment: WrapAlignment.center,
              spacing: 12,
              runSpacing: 10,
              children: [
                OutlinedButton.icon(
                  onPressed: onReconnect,
                  icon: const Icon(Icons.link, size: 18),
                  label: Text(
                    t('reconnect'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: cs.secondary,
                    side: BorderSide(color: cs.secondary),
                  ),
                ),
                OutlinedButton.icon(
                  onPressed: onRetry,
                  icon: const Icon(Icons.refresh, size: 18),
                  label: Text(
                    t('retry'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: cs.primary,
                    side: BorderSide(color: cs.primary),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Shown when the host answered and had no containers to report.
///
/// Scrollable and refreshable rather than a bare centred message: "no
/// containers" is the state a user sees right after starting one elsewhere, and
/// pulling down has to work here or the only way to find out is to leave the
/// page and come back.
class ContainerEmptyView extends StatelessWidget {
  /// Re-reads the listing.
  final Future<void> Function() onRefresh;

  const ContainerEmptyView({super.key, required this.onRefresh});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return RefreshIndicator(
      color: cs.primary,
      backgroundColor: cs.surface,
      onRefresh: onRefresh,
      child: ListView(
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 120),
            child: Center(
              child: Column(
                children: [
                  AppIconBox(
                    icon: Icons.inventory_2_outlined,
                    color: cs.primary,
                    size: 64,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    t('no_containers'),
                    textAlign: TextAlign.center,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: cs.onSurface.withValues(alpha: 0.6),
                      fontSize: 16,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    t('no_containers_hint'),
                    textAlign: TextAlign.center,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: cs.onSurface.withValues(alpha: 0.56),
                      fontSize: 13,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
