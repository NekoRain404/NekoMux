import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/credential.dart';
import '../models/host.dart';
import '../services/host_connection.dart';
import '../services/known_hosts_store.dart';
import '../services/port_forward_service.dart';
import '../services/ssh_service.dart';
import 'providers.dart';
import 'ssh_provider.dart';

/// One host's tunnels, with the session that carries them.
class HostTunnels {
  /// The session the channels are opened on, or null before it is up.
  final SshConnection? session;

  /// The forwards running on that session.
  final PortForwardService? forwards;

  /// Why there are no tunnels, when that is the state: a connection that failed,
  /// or a host key the user refused.
  final String? error;

  /// True while the session is being established.
  final bool connecting;

  const HostTunnels({
    this.session,
    this.forwards,
    this.error,
    this.connecting = false,
  });

  /// The tunnels currently up.
  List<LocalForward> get active => forwards?.forwards ?? const [];

  /// Whether this host has a live session to forward over.
  bool get ready => forwards != null;
}

/// Tunnels per host, kept outside the widget tree.
///
/// Deliberately not auto-disposed: a tunnel that ended when its page was popped
/// would be useless — the whole point is to leave it running while the user
/// switches to the browser that is about to use it. The session therefore
/// outlives the screen that started it, and is released only when the user stops
/// the last tunnel or leaves the app.
class TunnelNotifier extends Notifier<Map<String, HostTunnels>> {
  @override
  Map<String, HostTunnels> build() => const {};

  /// Opens a session for [host] if there is not one already.
  ///
  /// [onPrompt] answers the host-key question; the page passes its own dialog,
  /// so a tunnel verifies the server exactly like every other connection in this
  /// app — the one thing a tunnel must not do is reach a machine whose identity
  /// nobody confirmed, because the port it forwards to is chosen on the strength
  /// of that identity.
  Future<void> ensureSession(
    Host host, {
    required Credential credential,
    required Future<bool> Function(String fingerprint, HostKeyVerdict verdict)
    onPrompt,
  }) async {
    final existing = state[host.id];
    if (existing != null && (existing.ready || existing.connecting)) return;

    _update(host.id, const HostTunnels(connecting: true));
    final db = await ref.read(databaseProvider.future);
    final hosts = ref.read(hostListProvider).value ?? const <Host>[];
    final credentials = await ref.read(credentialListProvider.future);
    final session = buildHostConnection(
      host: host,
      credential: credential,
      db: db,
      // The tunnel session is the one that must survive idleness: a forward
      // carries nothing until someone connects to it, so a carrier NAT would
      // drop it long before the user notices. The factory keeps the app's own
      // keepalive interval.
      connectTimeout: ref.read(connectTimeoutProvider),
      jump: jumpRouteFor(host, hosts: hosts, credentials: credentials),
      onPrompt: onPrompt,
    );
    try {
      await session.connect();
    } catch (e) {
      session.dispose();
      _update(
        host.id,
        HostTunnels(error: e is SshException ? e.kind.name : '$e'),
      );
      return;
    }

    _update(
      host.id,
      HostTunnels(session: session, forwards: PortForwardService(session)),
    );
  }

  /// Starts a tunnel on [host]'s session.
  Future<LocalForward> start(
    Host host, {
    required String remoteHost,
    required int remotePort,
    int localPort = 0,
  }) async {
    final forwards = state[host.id]?.forwards;
    if (forwards == null) {
      throw const PortForwardException(
        PortForwardFailure.sessionClosed,
        'no session',
      );
    }
    final forward = await forwards.start(
      remoteHost: remoteHost,
      remotePort: remotePort,
      localPort: localPort,
    );
    _notify(host.id);
    return forward;
  }

  /// Stops one tunnel, and the session itself once the last one is gone.
  ///
  /// The session is closed with the last tunnel rather than kept for a later
  /// one: an idle authenticated session left open on a server is a thing the
  /// user did not ask for and cannot see, and reopening it costs one connect.
  Future<void> stop(Host host, String forwardId) async {
    final entry = state[host.id];
    final forwards = entry?.forwards;
    if (entry == null || forwards == null) return;

    await forwards.stop(forwardId);
    if (forwards.forwards.isEmpty) {
      await forwards.close();
      entry.session?.disconnect();
      entry.session?.dispose();
      _update(host.id, const HostTunnels());
      return;
    }
    _notify(host.id);
  }

  /// Closes every tunnel on [host] and its session.
  Future<void> closeAll(Host host) async {
    final entry = state[host.id];
    await entry?.forwards?.close();
    entry?.session?.disconnect();
    entry?.session?.dispose();
    _update(host.id, const HostTunnels());
  }

  /// The tunnels for [host], empty when none were ever started.
  HostTunnels forHost(Host host) => state[host.id] ?? const HostTunnels();

  void _update(String hostId, HostTunnels value) {
    state = {...state, hostId: value};
  }

  void _notify(String hostId) {
    // The lists are mutated in place by the service, so the map has to be
    // replaced to make Riverpod rebuild the page.
    final entry = state[hostId];
    if (entry == null) return;
    _update(
      hostId,
      HostTunnels(
        session: entry.session,
        forwards: entry.forwards,
        error: entry.error,
        connecting: entry.connecting,
      ),
    );
  }
}

/// Global tunnels provider.
final tunnelProvider =
    NotifierProvider<TunnelNotifier, Map<String, HostTunnels>>(
      TunnelNotifier.new,
    );
