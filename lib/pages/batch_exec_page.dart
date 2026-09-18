import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/i18n/strings.dart';
import '../core/theme/app_fonts.dart';
import '../models/credential.dart';
import '../models/host.dart';
import '../providers/providers.dart';
import '../providers/ssh_provider.dart';
import 'package:sqflite/sqflite.dart';

import '../services/batch_runner.dart';
import '../services/host_connection.dart';
import '../services/command_result.dart';
import '../services/ssh_service.dart';
import '../widgets/app_ui.dart';

/// Runs one command on many hosts.
///
/// The reason this exists is the keyboard: a command that has to be sent to five
/// machines is otherwise typed five times on a phone, and each of those typings
/// is a chance to get it wrong on exactly one host without noticing.
///
/// Two things are deliberate about how it behaves. It never makes a host-key
/// decision — a host whose key is not trusted is reported as such, not prompted
/// for, because a modal per host is a storm and accepting silently is what the
/// known-hosts table exists to prevent. And it stops at the app's side only: a
/// command already running on a server cannot be recalled.
class BatchExecPage extends ConsumerStatefulWidget {
  /// Hosts offered for selection; when non-empty they start ticked.
  final List<Host> preselected;

  const BatchExecPage({super.key, this.preselected = const []});

  @override
  ConsumerState<BatchExecPage> createState() => _BatchExecPageState();
}

class _BatchExecPageState extends ConsumerState<BatchExecPage> {
  final _commandController = TextEditingController();
  final _selected = <String>{};
  BatchRunner? _runner;
  List<BatchHostResult> _results = const [];
  bool _isRunning = false;

  @override
  void initState() {
    super.initState();
    for (final host in widget.preselected) {
      _selected.add(host.id);
    }
  }

  @override
  void dispose() {
    _runner?.cancel();
    _commandController.dispose();
    super.dispose();
  }

  /// Builds the session factory the runner uses.
  ///
  /// The verifier refuses every key it is not already told to trust, and records
  /// that it was asked — the same policy the background probe follows, with the
  /// difference that here the refusal is reported to the user per host instead
  /// of being silent.
  BatchSessionFactory _sessionFactory(
    Duration connectTimeout,
    Database db, {
    required List<Host> hosts,
    required List<Credential> credentials,
  }) {
    return (host, credential) => _RealBatchSession(
      host: host,
      credential: credential,
      connectTimeout: connectTimeout,
      database: db,
      jump: jumpRouteFor(host, hosts: hosts, credentials: credentials),
    );
  }

  Future<void> _run(List<Host> hosts) async {
    if (_isRunning) return;
    final command = _commandController.text.trim();
    if (command.isEmpty || _selected.isEmpty) return;

    final targets = [
      for (final host in hosts)
        if (_selected.contains(host.id)) host,
    ];
    if (targets.isEmpty) return;

    final credentials = await ref.read(credentialListProvider.future);
    final byId = {for (final c in credentials) c.id: c};
    final db = await ref.read(databaseProvider.future);
    if (!mounted) return;

    late final BatchRunner runner;
    runner = BatchRunner(
      onUpdate: (_) {
        if (!mounted) return;
        setState(() => _results = runner.results);
      },
    );
    setState(() {
      _runner = runner;
      _isRunning = true;
      _results = const [];
    });

    await runner.run(
      hosts: targets,
      command: command,
      sessionFor: _sessionFactory(
        ref.read(connectTimeoutProvider),
        db,
        hosts: hosts,
        credentials: credentials,
      ),
      credentialFor: (host) => byId[host.credentialId],
    );

    if (mounted) setState(() => _isRunning = false);
  }

  /// Leaves the page, asking first when hosts are still being worked through.
  Future<void> _handleBack() async {
    if (!_isRunning) {
      Navigator.pop(context);
      return;
    }
    final leave = await showAppConfirmDialog(
      context,
      title: t('batch_leave_title'),
      message: t('batch_leave_body'),
      cancelLabel: t('cancel'),
      confirmLabel: t('batch_leave_confirm'),
      destructive: true,
    );
    if (!leave || !mounted) return;
    _runner?.cancel();
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final hostsAsync = ref.watch(hostListProvider);

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _handleBack();
      },
      child: Scaffold(
        backgroundColor: Theme.of(context).scaffoldBackgroundColor,
        appBar: AppBar(
          backgroundColor: cs.surface,
          leading: IconButton(
            icon: Icon(
              Icons.arrow_back,
              color: cs.onSurface.withValues(alpha: 0.7),
            ),
            onPressed: _handleBack,
          ),
          title: Text(
            t('batch_title'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        body: hostsAsync.when(
          loading: () =>
              Center(child: CircularProgressIndicator(color: cs.primary)),
          error: (e, _) => AppLoadFailure(
            detail: t('load_failed_msg').replaceAll('{0}', '$e'),
            onRetry: () => ref.invalidate(hostListProvider),
          ),
          data: (hosts) => _buildBody(hosts),
        ),
      ),
    );
  }

  Widget _buildBody(List<Host> hosts) {
    final cs = Theme.of(context).colorScheme;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: _commandController,
                enabled: !_isRunning,
                maxLines: 3,
                minLines: 1,
                style: TextStyle(
                  color: cs.onSurface,
                  fontFamily: AppFonts.mono,
                  fontSize: 13,
                ),
                decoration: InputDecoration(
                  hintText: t('batch_command_hint'),
                  hintStyle: TextStyle(
                    color: cs.onSurface.withValues(alpha: 0.42),
                  ),
                  filled: true,
                  fillColor: cs.surface,
                  border: const OutlineInputBorder(),
                ),
                // Submitted from the keyboard runs the batch, since the field is
                // the only thing the user came here to fill in.
                onSubmitted: (_) => _run(hosts),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      t('batch_targets').replaceAll(
                        '{0}',
                        '${_selected.length}/${hosts.length}',
                      ),
                      style: TextStyle(
                        color: cs.onSurface.withValues(alpha: 0.6),
                        fontSize: 12,
                      ),
                    ),
                  ),
                  if (_isRunning)
                    TextButton.icon(
                      onPressed: () {
                        _runner?.cancel();
                        setState(() => _isRunning = false);
                      },
                      icon: Icon(Icons.stop_circle_outlined, color: cs.error, size: 18),
                      label: Text(
                        t('batch_cancel'),
                        style: TextStyle(color: cs.error),
                      ),
                    )
                  else
                    FilledButton.icon(
                      onPressed: _selected.isEmpty ? null : () => _run(hosts),
                      icon: const Icon(Icons.play_arrow, size: 18),
                      label: Text(t('batch_run')),
                      style: FilledButton.styleFrom(
                        backgroundColor: cs.primary,
                        foregroundColor: cs.onPrimary,
                      ),
                    ),
                ],
              ),
              if (_results.isNotEmpty) ...[
                const SizedBox(height: 8),
                _BatchSummary(results: _results),
              ],
            ],
          ),
        ),
        Divider(height: 1, color: Theme.of(context).dividerColor),
        Expanded(
          child: _results.isEmpty
              ? _HostPicker(
                  hosts: hosts,
                  selected: _selected,
                  enabled: !_isRunning,
                  onToggle: (id, on) => setState(() {
                    if (on) {
                      _selected.add(id);
                    } else {
                      _selected.remove(id);
                    }
                  }),
                  onSelectAll: () => setState(() {
                    _selected
                      ..clear()
                      ..addAll(hosts.map((h) => h.id));
                  }),
                  onSelectNone: () => setState(_selected.clear),
                )
              : ListView.builder(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  itemCount: _results.length,
                  itemBuilder: (context, index) =>
                      _ResultCard(result: _results[index]),
                ),
        ),
      ],
    );
  }
}

/// The host checklist, shown until a run starts.
class _HostPicker extends StatelessWidget {
  final List<Host> hosts;
  final Set<String> selected;
  final bool enabled;
  final void Function(String id, bool selected) onToggle;
  final VoidCallback onSelectAll;
  final VoidCallback onSelectNone;

  const _HostPicker({
    required this.hosts,
    required this.selected,
    required this.enabled,
    required this.onToggle,
    required this.onSelectAll,
    required this.onSelectNone,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    if (hosts.isEmpty) {
      return AppEmptyState(
        icon: Icons.dns_outlined,
        title: t('empty_hosts'),
        message: t('empty_hosts_hint'),
        color: cs.primary,
      );
    }
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          child: Row(
            children: [
              TextButton(
                onPressed: enabled ? onSelectAll : null,
                child: Text(t('batch_select_all')),
              ),
              TextButton(
                onPressed: enabled ? onSelectNone : null,
                child: Text(t('batch_select_none')),
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView.builder(
            itemCount: hosts.length,
            itemBuilder: (context, index) {
              final host = hosts[index];
              return CheckboxListTile(
                dense: true,
                value: selected.contains(host.id),
                onChanged: enabled
                    ? (value) => onToggle(host.id, value ?? false)
                    : null,
                activeColor: cs.primary,
                title: Text(
                  host.alias,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: cs.onSurface, fontSize: 14),
                ),
                subtitle: Text(
                  host.displayAddress,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: cs.onSurface.withValues(alpha: 0.5),
                    fontSize: 11,
                    fontFamily: AppFonts.mono,
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

/// "N succeeded · N failed · N unreachable", from the results themselves.
class _BatchSummary extends StatelessWidget {
  final List<BatchHostResult> results;

  const _BatchSummary({required this.results});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    int count(BatchStatus status) =>
        results.where((r) => r.status == status).length;

    final parts = <(String, Color)>[
      if (count(BatchStatus.succeeded) > 0)
        ('${count(BatchStatus.succeeded)} ${t('batch_ok')}', cs.primary),
      if (count(BatchStatus.failed) > 0)
        ('${count(BatchStatus.failed)} ${t('batch_failed')}', cs.error),
      if (count(BatchStatus.needsTrust) > 0)
        ('${count(BatchStatus.needsTrust)} ${t('batch_trust')}', cs.secondary),
      if (count(BatchStatus.unreachable) > 0)
        (
          '${count(BatchStatus.unreachable)} ${t('batch_unreachable')}',
          cs.onSurface.withValues(alpha: 0.6),
        ),
      if (count(BatchStatus.cancelled) > 0)
        ('${count(BatchStatus.cancelled)} ${t('batch_cancelled')}', cs.onSurface.withValues(alpha: 0.45)),
      if (count(BatchStatus.pending) + count(BatchStatus.running) > 0)
        (
          '${count(BatchStatus.pending) + count(BatchStatus.running)} ${t('batch_waiting')}',
          cs.onSurface.withValues(alpha: 0.6),
        ),
    ];

    return Wrap(
      spacing: 8,
      runSpacing: 4,
      children: [
        for (final (label, color) in parts)
          AppBadge(label: label, color: color, maxWidth: 200),
      ],
    );
  }
}

/// One host's row in the results: status, code, output.
class _ResultCard extends StatelessWidget {
  final BatchHostResult result;

  const _ResultCard({required this.result});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final (label, color) = switch (result.status) {
      BatchStatus.pending => (t('batch_waiting'), cs.onSurface.withValues(alpha: 0.45)),
      BatchStatus.running => (t('batch_running'), cs.secondary),
      BatchStatus.succeeded => (t('batch_ok'), cs.primary),
      BatchStatus.failed => (t('batch_failed'), cs.error),
      BatchStatus.needsTrust => (t('batch_trust'), cs.secondary),
      BatchStatus.unreachable => (t('batch_unreachable'), cs.onSurface.withValues(alpha: 0.6)),
      BatchStatus.cancelled => (t('batch_cancelled'), cs.onSurface.withValues(alpha: 0.45)),
    };

    final output = [
      if (result.stdout.trim().isNotEmpty) result.stdout.trim(),
      if (result.stderr.trim().isNotEmpty) result.stderr.trim(),
    ].join('\n');

    return AppCard(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      padding: const EdgeInsets.all(12),
      borderColor: color.withValues(alpha: 0.5),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  result.host.alias,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: cs.onSurface,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (result.status == BatchStatus.running)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(
                      strokeWidth: 1.6,
                      color: cs.secondary,
                    ),
                  ),
                ),
              AppBadge(label: label, color: color, maxWidth: 160),
            ],
          ),
          if (result.exitCode != null ||
              result.duration != null ||
              result.error != null) ...[
            const SizedBox(height: 4),
            Text(
              [
                if (result.exitCode != null) 'exit ${result.exitCode}',
                if (result.duration != null)
                  '${result.duration!.inMilliseconds} ms',
                if (result.error != null && output.isEmpty) result.error!,
              ].join(' · '),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: cs.onSurface.withValues(alpha: 0.5),
                fontSize: 11,
                fontFamily: AppFonts.mono,
              ),
            ),
          ],
          if (result.status == BatchStatus.needsTrust) ...[
            const SizedBox(height: 6),
            Text(
              t('batch_trust_hint'),
              style: TextStyle(
                color: cs.secondary,
                fontSize: 11,
                height: 1.4,
              ),
            ),
          ],
          if (output.isNotEmpty) ...[
            const SizedBox(height: 8),
            InkWell(
              // Tapping the output copies it: the next thing a user does with a
              // command's output from one of five machines is paste it
              // somewhere — an issue, a chat, a diff against another host's.
              onTap: () {
                Clipboard.setData(ClipboardData(text: output));
                ScaffoldMessenger.of(
                  context,
                ).showSnackBar(SnackBar(content: Text(t('copied'))));
              },
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Theme.of(context).scaffoldBackgroundColor,
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: Theme.of(context).dividerColor),
                ),
                child: Text(
                  output,
                  maxLines: 12,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: cs.onSurface.withValues(alpha: 0.85),
                    fontSize: 11,
                    height: 1.45,
                    fontFamily: AppFonts.mono,
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// A real SSH session, shaped for the batch runner.
class _RealBatchSession implements BatchSession {
  final Host host;
  final Credential credential;
  final Duration connectTimeout;
  final Database database;

  /// The bastion this host is reached through, already resolved.
  final JumpRoute? jump;

  SshConnection? _connection;

  _RealBatchSession({
    required this.host,
    required this.credential,
    required this.connectTimeout,
    required this.database,
    this.jump,
  });

  @override
  bool trustRefused = false;

  @override
  Future<void> connect() async {
    final connection = buildHostConnection(
      host: host,
      credential: credential,
      db: database,
      connectTimeout: connectTimeout,
      jump: jump,
      // Refused, and recorded. A batch is not a place to ask: the prompt would
      // have to be modal per host, and answering it on the user's behalf is the
      // one thing this app never does.
      refuseUntrusted: true,
      onTrustRefused: () => trustRefused = true,
      onPrompt: (_, _) async => false,
    );
    _connection = connection;
    await connection.connect();
  }

  @override
  Future<CommandResult> run(String command) async {
    final connection = _connection;
    if (connection == null) {
      throw const SshException(SshFailure.connect, 'not connected');
    }
    return connection.runCommand(command);
  }

  @override
  void dispose() {
    _connection?.disconnect();
    _connection?.dispose();
    _connection = null;
  }
}
