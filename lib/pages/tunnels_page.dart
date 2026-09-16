import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/i18n/strings.dart';
import '../models/credential.dart';
import '../models/host.dart';
import '../providers/providers.dart';
import '../providers/tunnel_provider.dart';
import '../services/known_hosts_store.dart';
import '../services/port_forward_service.dart';
import '../services/ssh_service.dart';
import '../widgets/app_ui.dart';
import '../widgets/host_key_prompt.dart';
import 'console/ssh_error_text.dart';

/// Local port forwarding for one host.
///
/// What this is for: an admin panel bound to `127.0.0.1` on the server, a
/// database console, a Prometheus that only listens on the box. None of those
/// can be reached by typing an address into a phone browser — they are not
/// listening on the internet — and through a tunnel they are a local URL.
///
/// The lifetime is stated on the page rather than implied: tunnels live as long
/// as this process, there is no foreground service, and the operating system may
/// end them when the app is not in use.
class TunnelsPage extends ConsumerStatefulWidget {
  final Host host;

  const TunnelsPage({super.key, required this.host});

  @override
  ConsumerState<TunnelsPage> createState() => _TunnelsPageState();
}

class _TunnelsPageState extends ConsumerState<TunnelsPage> {
  bool _starting = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _ensureSession());
  }

  /// Opens the host's forwarding session, asking about its host key like every
  /// other connection does.
  Future<void> _ensureSession() async {
    final host = widget.host;
    Credential? credential;
    try {
      final all = await ref.read(credentialListProvider.future);
      credential = all.where((c) => c.id == host.credentialId).firstOrNull;
    } catch (_) {
      credential = null;
    }
    if (!mounted) return;
    if (credential == null) {
      _showSnack(t('credential_not_found'), isError: true);
      return;
    }

    await ref
        .read(tunnelProvider.notifier)
        .ensureSession(
          host,
          credential: credential,
          onPrompt: (String fingerprint, HostKeyVerdict verdict) async {
            // Raised from inside connect(), so the page may already be gone.
            if (!mounted) return false;
            return showHostKeyPrompt(
              context,
              fingerprint: fingerprint,
              verdict: verdict,
            );
          },
        );
  }

  Future<void> _startTunnel() async {
    if (_starting) return;
    setState(() => _starting = true);
    try {
      final request = await showDialog<_TunnelRequest>(
        context: context,
        builder: (_) => const _NewTunnelDialog(),
      );
      if (request == null || !mounted) return;

      await ref
          .read(tunnelProvider.notifier)
          .start(
            widget.host,
            remoteHost: request.remoteHost,
            remotePort: request.remotePort,
            localPort: request.localPort,
          );
        if (mounted) _showSnack(t('tunnel_started'));
    } on PortForwardException catch (e) {
      if (mounted) _showSnack(_tunnelErrorText(e), isError: true);
    } catch (e) {
      if (mounted) {
        _showSnack(t('tunnel_failed').replaceAll('{0}', '$e'), isError: true);
      }
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  /// Turns a forwarding failure into something the user can act on.
  String _tunnelErrorText(PortForwardException e) {
    return switch (e.kind) {
      PortForwardFailure.bindFailed => t('tunnel_port_in_use'),
      PortForwardFailure.sessionClosed => t('ssh_not_connected'),
    };
  }

  void _showSnack(String message, {bool isError = false}) {
    final cs = Theme.of(context).colorScheme;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isError ? cs.error : cs.primary,
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.all(16),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tunnels = ref.watch(tunnelProvider)[widget.host.id] ?? const HostTunnels();

    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(
        backgroundColor: cs.surface,
        leading: IconButton(
          icon: Icon(Icons.arrow_back, color: cs.onSurface.withValues(alpha: 0.7)),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text(
          t('port_forwarding'),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          IconButton(
            icon: Icon(Icons.add, color: cs.secondary),
            tooltip: t('new_tunnel'),
            onPressed: tunnels.ready && !_starting ? _startTunnel : null,
          ),
        ],
      ),
      body: Column(
        children: [
          _LifetimeNotice(),
          if (tunnels.connecting)
            Expanded(
              child: Center(
                child: CircularProgressIndicator(color: cs.primary),
              ),
            )
          else if (!tunnels.ready)
            Expanded(
              child: AppEmptyState(
                icon: Icons.sync_problem,
                title: t('connection_failed'),
                message: tunnels.error == null
                    ? t('tunnel_needs_session')
                    : sshFailureText(SshFailure.connect, tunnels.error!),
                actionLabel: t('retry'),
                onAction: _ensureSession,
                color: cs.error,
              ),
            )
          else if (tunnels.active.isEmpty)
            Expanded(
              child: AppEmptyState(
                icon: Icons.swap_horiz,
                title: t('no_tunnels'),
                message: t('no_tunnels_hint'),
                actionLabel: t('new_tunnel'),
                onAction: _startTunnel,
                color: cs.primary,
              ),
            )
          else
            Expanded(
              child: ListView.builder(
                padding: const EdgeInsets.symmetric(vertical: 8),
                itemCount: tunnels.active.length,
                itemBuilder: (context, index) {
                  final forward = tunnels.active[index];
                  return _TunnelCard(
                    forward: forward,
                    onCopy: (value) {
                      Clipboard.setData(ClipboardData(text: value));
                      _showSnack(t('copied'));
                    },
                    onStop: () =>
                        ref.read(tunnelProvider.notifier).stop(widget.host, forward.id),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }
}

/// The one thing about a tunnel that a user has to know before relying on it.
class _LifetimeNotice extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      color: cs.onSurface.withValues(alpha: 0.04),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline, size: 14, color: cs.onSurface.withValues(alpha: 0.5)),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              t('tunnel_lifetime_notice'),
              style: TextStyle(
                color: cs.onSurface.withValues(alpha: 0.6),
                fontSize: 11,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// One running tunnel: where it listens, where it leads, and how to stop it.
class _TunnelCard extends StatelessWidget {
  final LocalForward forward;
  final void Function(String value) onCopy;
  final VoidCallback onStop;

  const _TunnelCard({
    required this.forward,
    required this.onCopy,
    required this.onStop,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return AppCard(
      margin: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
      padding: const EdgeInsets.all(14),
      borderColor: Theme.of(context).dividerColor.withValues(alpha: 0.5),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Tapping the address copies it: the address is the whole point of the
          // tunnel, and it is meant to be pasted into a browser's address bar.
          InkWell(
            onTap: () => onCopy('http://${forward.localAddress}'),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    forward.localAddress,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: cs.primary,
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      fontFamily: 'JetBrainsMono',
                    ),
                  ),
                ),
                Icon(Icons.copy, size: 14, color: cs.onSurface.withValues(alpha: 0.4)),
              ],
            ),
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Icon(Icons.arrow_forward, size: 12, color: cs.onSurface.withValues(alpha: 0.5)),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  forward.remoteAddress,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: cs.onSurface.withValues(alpha: 0.6),
                    fontSize: 12,
                    fontFamily: 'JetBrainsMono',
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Text(
                '${t('connections')}: ${forward.connections}',
                style: TextStyle(
                  color: cs.onSurface.withValues(alpha: 0.5),
                  fontSize: 11,
                ),
              ),
              const Spacer(),
              TextButton.icon(
                onPressed: onStop,
                icon: Icon(Icons.stop_circle_outlined, size: 16, color: cs.error),
                label: Text(t('stop'), style: TextStyle(color: cs.error)),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// What the user asked to forward.
class _TunnelRequest {
  final String remoteHost;
  final int remotePort;
  final int localPort;

  const _TunnelRequest({
    required this.remoteHost,
    required this.remotePort,
    required this.localPort,
  });
}

/// Asks for the two ends of a tunnel, with the common case prefilled.
class _NewTunnelDialog extends StatefulWidget {
  const _NewTunnelDialog();

  @override
  State<_NewTunnelDialog> createState() => _NewTunnelDialogState();
}

class _NewTunnelDialogState extends State<_NewTunnelDialog> {
  // Loopback on the server is the overwhelming majority of what gets forwarded —
  // that is exactly why the port is not reachable from a phone without this.
  final _remoteHost = TextEditingController(text: '127.0.0.1');
  final _remotePort = TextEditingController();
  final _localPort = TextEditingController();

  @override
  void dispose() {
    _remoteHost.dispose();
    _remotePort.dispose();
    _localPort.dispose();
    super.dispose();
  }

  /// The port to forward, or null when what was typed is not one.
  ///
  /// Port 0 is accepted for the local end: "any free port" is a real answer, and
  /// the page reports the one that was granted.
  int? _port(TextEditingController controller, {required bool allowZero}) {
    final text = controller.text.trim();
    if (text.isEmpty) return allowZero ? 0 : null;
    final value = int.tryParse(text);
    if (value == null) return null;
    if (value == 0) return allowZero ? 0 : null;
    return (value > 0 && value < 65536) ? value : null;
  }

  void _submit() {
    final remotePort = _port(_remotePort, allowZero: false);
    final localPort = _port(_localPort, allowZero: true);
    if (remotePort == null || localPort == null) return;
    Navigator.pop(
      context,
      _TunnelRequest(
        remoteHost: _remoteHost.text.trim().isEmpty
            ? '127.0.0.1'
            : _remoteHost.text.trim(),
        remotePort: remotePort,
        localPort: localPort,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return AlertDialog(
      backgroundColor: cs.surface,
      title: Text(t('new_tunnel'), style: TextStyle(color: cs.onSurface)),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              t('tunnel_explain'),
              style: TextStyle(
                color: cs.onSurface.withValues(alpha: 0.6),
                fontSize: 12,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 16),
            _field(cs, _remoteHost, t('tunnel_remote_host'), '127.0.0.1'),
            const SizedBox(height: 12),
            _field(cs, _remotePort, t('tunnel_remote_port'), '5432', number: true),
            const SizedBox(height: 12),
            _field(cs, _localPort, t('tunnel_local_port'), '0', number: true),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(
            t('cancel'),
            style: TextStyle(color: cs.onSurface.withValues(alpha: 0.62)),
          ),
        ),
        TextButton(
          onPressed: _submit,
          child: Text(t('start'), style: TextStyle(color: cs.primary)),
        ),
      ],
    );
  }

  Widget _field(
    ColorScheme cs,
    TextEditingController controller,
    String label,
    String hint, {
    bool number = false,
  }) {
    return TextField(
      controller: controller,
      keyboardType: number ? TextInputType.number : TextInputType.text,
      style: TextStyle(color: cs.onSurface, fontFamily: 'JetBrainsMono', fontSize: 13),
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        border: const OutlineInputBorder(),
      ),
    );
  }
}
