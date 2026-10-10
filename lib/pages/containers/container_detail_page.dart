// The container detail view: what `docker inspect` knows and `docker ps` does
// not.
//
// The list card answers "is it up". This answers the question that follows —
// "then why not", "what is it mounting", "what is it configured with" — which
// until now a phone could not answer at all: `docker ps` renders `Exited (127)`
// and the daemon's explanation sits in a JSON blob with no `jq` in reach.
//
// The page holds no connection. It is handed a [ContainerDetailLoader] by the
// page that owns the SSH session, exactly as the log viewer is, so the only
// thing that talks to a server is the caller.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/theme/app_fonts.dart';
import '../../core/i18n/strings.dart';
import '../../widgets/app_ui.dart';
import 'container_detail_loader.dart';
import 'docker_detail.dart';

/// Shows everything the daemon knows about one container.
class ContainerDetailPage extends StatefulWidget {
  /// The container to describe, as `docker ps` named it.
  final String containerName;

  /// Reads the detail; provided by the page that owns the connection.
  final ContainerDetailLoader load;

  const ContainerDetailPage({
    super.key,
    required this.containerName,
    required this.load,
  });

  @override
  State<ContainerDetailPage> createState() => _ContainerDetailPageState();
}

class _ContainerDetailPageState extends State<ContainerDetailPage> {
  ContainerDetailOutcome? _outcome;
  bool _isLoading = true;

  /// Whether secrets in the environment are currently shown.
  ///
  /// Off by default and never persisted: the point of hiding them is that they
  /// are not on screen at rest, and a setting that remembered "shown" would
  /// defeat exactly that.
  bool _secretsRevealed = false;

  @override
  void initState() {
    super.initState();
    _fetch();
  }

  Future<void> _fetch() async {
    setState(() => _isLoading = true);
    final outcome = await widget.load();
    if (!mounted) return;
    setState(() {
      _outcome = outcome;
      _isLoading = false;
      // A refresh may return a container whose variables have changed; keeping
      // the old reveal state would show the new values unasked.
      _secretsRevealed = false;
    });
  }

  void _copy(String text) {
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(t('copied'))));
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final detail = _outcome?.detail;

    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(
        backgroundColor: cs.surface,
        title: Text(
          widget.containerName,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: AppFonts.monoText(color: cs.onSurface, fontSize: 16),
        ),
        actions: [
          IconButton(
            icon: Icon(
              Icons.copy,
              size: 20,
              color: cs.onSurface.withValues(alpha: 0.7),
            ),
            tooltip: t('copy'),
            onPressed: () => _copy(widget.containerName),
          ),
          IconButton(
            icon: Icon(
              Icons.refresh,
              size: 20,
              color: cs.onSurface.withValues(alpha: 0.7),
            ),
            tooltip: t('refresh'),
            onPressed: _isLoading ? null : _fetch,
          ),
        ],
      ),
      body: _isLoading && detail == null
          ? Center(
              child: SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: cs.primary,
                ),
              ),
            )
          : detail == null
          ? _FailureView(message: _outcome?.failure ?? '', onRetry: _fetch)
          : RefreshIndicator(
              color: cs.primary,
              backgroundColor: cs.surface,
              onRefresh: _fetch,
              child: ListView(
                padding: const EdgeInsets.symmetric(vertical: 8),
                children: [
                  // First, and above everything else: if the daemon explained
                  // why this container will not run, that explanation is the
                  // only thing the user came here for.
                  if (detail.hasStateError)
                    _FailureCard(
                      message: detail.stateError,
                      onCopy: () => _copy(detail.stateError),
                    ),
                  _StateSection(detail: detail),
                  if (detail.mounts.isNotEmpty)
                    _MountSection(mounts: detail.mounts),
                  if (detail.networks.isNotEmpty)
                    _NetworkSection(networks: detail.networks),
                  if (detail.env.isNotEmpty)
                    _EnvSection(
                      env: detail.env,
                      revealed: _secretsRevealed,
                      onToggle: () => setState(
                        () => _secretsRevealed = !_secretsRevealed,
                      ),
                    ),
                  const SizedBox(height: 24),
                ],
              ),
            ),
    );
  }
}

/// What to show when the detail could not be read at all.
class _FailureView extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;

  const _FailureView({required this.message, required this.onRetry});

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

/// The daemon's own explanation of why the container is not running.
class _FailureCard extends StatelessWidget {
  final String message;
  final VoidCallback onCopy;

  const _FailureCard({required this.message, required this.onCopy});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: cs.error.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: cs.error.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.report_gmailerrorred, color: cs.error, size: 18),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  t('container_why_stopped'),
                  style: TextStyle(
                    color: cs.error,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              IconButton(
                icon: Icon(
                  Icons.copy,
                  size: 16,
                  color: cs.error.withValues(alpha: 0.8),
                ),
                tooltip: t('copy'),
                visualDensity: VisualDensity.compact,
                onPressed: onCopy,
              ),
            ],
          ),
          const SizedBox(height: 6),
          // Selectable as well as copyable: this text is pasted into an issue
          // or a search box far more often than it is read to the end.
          SelectableText(
            message,
            style: TextStyle(
              color: cs.onSurface.withValues(alpha: 0.85),
              fontSize: 11.5,
              height: 1.5,
              fontFamily: AppFonts.mono,
            ),
          ),
        ],
      ),
    );
  }
}

/// One labelled value row inside a section.
class _Row extends StatelessWidget {
  final String label;
  final String value;
  final Color? valueColor;

  const _Row({required this.label, required this.value, this.valueColor});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 104,
            child: Text(
              label,
              style: TextStyle(
                color: cs.onSurface.withValues(alpha: 0.5),
                fontSize: 12,
              ),
            ),
          ),
          Expanded(
            child: SelectableText(
              value,
              style: AppFonts.monoText(
                color: valueColor ?? cs.onSurface.withValues(alpha: 0.9),
                fontSize: 12,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A titled group of rows.
class _Section extends StatelessWidget {
  final String title;
  final Widget child;
  final Widget? trailing;

  const _Section({required this.title, required this.child, this.trailing});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return AppCard(
      margin: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: TextStyle(
                    color: cs.onSurface,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              ?trailing,
            ],
          ),
          const SizedBox(height: 8),
          child,
        ],
      ),
    );
  }
}

/// Status, exit code, restarts, policy, image and times.
class _StateSection extends StatelessWidget {
  final ContainerDetail detail;

  const _StateSection({required this.detail});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final colour = detail.isRunning ? cs.primary : cs.error;

    return _Section(
      title: t('container_state'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: colour,
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: colour.withValues(alpha: 0.5),
                      blurRadius: 4,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Text(
                _statusLabel(detail.status),
                style: TextStyle(
                  color: colour,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (detail.health != null) ...[
                const SizedBox(width: 10),
                Text(
                  _healthLabel(detail.health!),
                  style: TextStyle(
                    color: detail.health == 'healthy'
                        ? cs.primary
                        : cs.error,
                    fontSize: 12,
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 8),
          _Row(label: t('container_image'), value: detail.image),
          // Only meaningful when it is not running: a live container reports 0,
          // which is not an exit status but the absence of one.
          if (!detail.isRunning && detail.exitCode != null)
            _Row(
              label: t('container_exit_code'),
              value: detail.oomKilled
                  ? '${detail.exitCode} · ${t('container_oom_killed')}'
                  : '${detail.exitCode}',
              valueColor: detail.exitCode == 0 ? null : cs.error,
            ),
          if (detail.restartCount > 0)
            _Row(
              label: t('container_restarts'),
              value: '${detail.restartCount}',
            ),
          _Row(
            label: t('container_restart_policy'),
            value: detail.restartPolicy,
          ),
          _Row(
            label: t('container_memory_limit'),
            value: detail.memoryUnlimited
                ? t('container_unlimited')
                : formatBytes(detail.memoryLimitBytes),
          ),
          _Row(
            label: t('container_started_at'),
            value: detail.startedAt == null
                ? t('container_never')
                : formatDockerTime(detail.startedAt!),
          ),
          if (!detail.isRunning)
            _Row(
              label: t('container_finished_at'),
              value: detail.finishedAt == null
                  ? t('container_never')
                  : formatDockerTime(detail.finishedAt!),
            ),
        ],
      ),
    );
  }
}

/// Where the container's data lives.
class _MountSection extends StatelessWidget {
  final List<ContainerMount> mounts;

  const _MountSection({required this.mounts});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return _Section(
      title: t('container_mounts'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final mount in mounts)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 5),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          mount.destination,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppFonts.monoText(
                            color: cs.onSurface,
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      if (mount.isReadOnly)
                        Text(
                          t('container_read_only'),
                          style: TextStyle(
                            color: cs.secondary,
                            fontSize: 10,
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  // The host path is what the user has to act on — a backup, a
                  // `du`, a file to edit — so it is shown in full and is not
                  // truncated to one line.
                  SelectableText(
                    '${mount.type} · ${mount.source}',
                    style: AppFonts.monoText(
                      color: cs.onSurface.withValues(alpha: 0.55),
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

/// Which networks the container is on, and where.
class _NetworkSection extends StatelessWidget {
  final List<ContainerNetwork> networks;

  const _NetworkSection({required this.networks});

  @override
  Widget build(BuildContext context) {
    return _Section(
      title: t('container_networks'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final network in networks)
            _Row(
              label: network.name,
              value: network.address.isEmpty ? '—' : network.address,
            ),
        ],
      ),
    );
  }
}

/// The environment, with anything that looks like a credential hidden.
class _EnvSection extends StatelessWidget {
  final List<ContainerEnvVar> env;
  final bool revealed;
  final VoidCallback onToggle;

  const _EnvSection({
    required this.env,
    required this.revealed,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final hasSecrets = env.any((e) => e.sensitive);

    return _Section(
      title: t('container_environment'),
      trailing: hasSecrets
          ? TextButton.icon(
              onPressed: onToggle,
              icon: Icon(
                revealed ? Icons.visibility_off : Icons.visibility,
                size: 15,
              ),
              label: Text(
                revealed ? t('container_hide_values') : t('container_show_values'),
                style: const TextStyle(fontSize: 11),
              ),
              style: TextButton.styleFrom(
                foregroundColor: cs.secondary,
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 6),
              ),
            )
          : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final entry in env)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: SelectableText.rich(
                TextSpan(
                  children: [
                    TextSpan(
                      text: entry.key,
                      style: TextStyle(
                        color: cs.onSurface.withValues(alpha: 0.75),
                      ),
                    ),
                    TextSpan(
                      text: '=',
                      style: TextStyle(
                        color: cs.onSurface.withValues(alpha: 0.35),
                      ),
                    ),
                    TextSpan(
                      text: entry.sensitive && !revealed
                          ? '••••••••'
                          : entry.value,
                      style: TextStyle(
                        // A hidden value is marked in the accent colour rather
                        // than left looking like an ordinary one, so the user
                        // can see that something is being withheld instead of
                        // reading `••••••••` as the value itself.
                        color: entry.sensitive && !revealed
                            ? cs.secondary
                            : cs.onSurface.withValues(alpha: 0.9),
                      ),
                    ),
                  ],
                ),
                style: AppFonts.monoText(color: cs.onSurface, fontSize: 11.5),
              ),
            ),
          if (hasSecrets && !revealed)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                t('container_values_hidden'),
                style: TextStyle(
                  color: cs.onSurface.withValues(alpha: 0.45),
                  fontSize: 10.5,
                  height: 1.4,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// The localised word for a daemon state.
///
/// `running` and `exited` are the two that happen constantly and are translated.
/// The rest are rare, and the daemon's own word is kept: `paused` and
/// `restarting` are Docker's terms, and inventing a translation for a state the
/// user is about to read about in Docker's own documentation helps nobody.
String _statusLabel(String status) => switch (status) {
  'running' => t('container_running'),
  'exited' || 'dead' => t('container_stopped'),
  _ => status,
};

/// The localised word for a healthcheck result.
String _healthLabel(String health) => switch (health) {
  'healthy' => t('container_healthy'),
  'unhealthy' => t('container_unhealthy'),
  'starting' => t('container_starting'),
  _ => health,
};

/// A byte count in the units a person reads.
String formatBytes(int bytes) {
  if (bytes <= 0) return t('container_unlimited');
  const units = ['B', 'KiB', 'MiB', 'GiB', 'TiB'];
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  final text = value >= 100 || unit == 0
      ? value.toStringAsFixed(0)
      : value.toStringAsFixed(1);
  return '$text ${units[unit]}';
}

String _two(int value) => value.toString().padLeft(2, '0');

/// A timestamp in the layout the rest of the app uses.
///
/// Year first and 24-hour, for the reasons the known-hosts page gives: it is
/// unambiguous in all eight languages the app ships and it sorts the way a log
/// does. Local time, because the user is comparing it against their own clock
/// and not against the server's.
String formatDockerTime(DateTime when) {
  final local = when.toLocal();
  return '${local.year}-${_two(local.month)}-${_two(local.day)} '
      '${_two(local.hour)}:${_two(local.minute)}';
}
