import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

/// A channel to a remote endpoint, opened through an SSH session.
///
/// The narrowest thing a tunnel needs, and the seam a test replaces: the
/// forwarding itself is real sockets and real pipes, so what has to be fakeable
/// is only the SSH hop.
abstract class ForwardChannel {
  /// Bytes arriving from the remote endpoint.
  Stream<Uint8List> get stream;

  /// Sends bytes to the remote endpoint.
  void write(List<int> data);

  /// Closes this channel.
  Future<void> close();
}

/// Opens forwarded channels.
abstract class ForwardOpener {
  /// Opens a channel to [remoteHost]:[remotePort], as seen by the server.
  Future<ForwardChannel> openForward({
    required String remoteHost,
    required int remotePort,
  });
}

/// One running tunnel.
class LocalForward {
  /// Stable id, used to stop it.
  final String id;

  /// What the server is asked to connect to, from the server's own point of
  /// view — `127.0.0.1` means the server itself, which is the usual case.
  final String remoteHost;
  final int remotePort;

  /// The port this device is listening on.
  final int localPort;

  /// Connections carried so far, for display.
  int connections;

  LocalForward({
    required this.id,
    required this.remoteHost,
    required this.remotePort,
    required this.localPort,
    this.connections = 0,
  });

  /// Where the user points a browser or a client: the address this app serves.
  String get localAddress => '127.0.0.1:$localPort';

  /// What the tunnel leads to, for display.
  String get remoteAddress => '$remoteHost:$remotePort';
}

/// Local port forwarding: listens on this device and carries every connection to
/// a port the server can reach.
///
/// This is the capability that makes a phone a usable client for anything with a
/// web interface — a database console, an admin panel bound to loopback, a
/// Prometheus that only listens on the box. None of those are reachable by
/// typing an address into a phone browser; through a forward they are one tap.
///
/// Honest scope: the tunnels live as long as this process does. There is no
/// foreground service, so the operating system may end them when the app is
/// backgrounded and reclaimed, and closing the app ends them for certain. The UI
/// says so rather than implying a permanent tunnel.
class PortForwardService {
  /// The session the channels are opened on.
  final ForwardOpener _opener;

  /// Listening sockets, by forward id.
  final Map<String, ServerSocket> _sockets = {};

  /// The forwards currently up, in the order they were started.
  final List<LocalForward> _forwards = [];

  var _nextId = 0;
  var _closed = false;

  PortForwardService(this._opener);

  /// The forwards currently running.
  List<LocalForward> get forwards => List.unmodifiable(_forwards);

  /// Whether [id] is still up.
  bool isRunning(String id) => _sockets.containsKey(id);

  /// Starts a tunnel from a port on this device to [remoteHost]:[remotePort].
  ///
  /// [localPort] is a request, not a promise: 0 (the default) asks the operating
  /// system for any free port, and the answer is on [LocalForward.localPort].
  /// Asking for a specific port is honoured when it is free and fails loudly
  /// when it is not — silently falling back to another port would leave the user
  /// with a URL that does not match what they configured.
  Future<LocalForward> start({
    required String remoteHost,
    required int remotePort,
    int localPort = 0,
    String? label,
  }) async {
    if (_closed) {
      throw const PortForwardException(
        PortForwardFailure.sessionClosed,
        'the session is closed',
      );
    }

    final ServerSocket socket;
    try {
      socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, localPort);
    } on SocketException catch (e) {
      throw PortForwardException(PortForwardFailure.bindFailed, e.message);
    }

    final id = 'f${_nextId++}';
    final forward = LocalForward(
      id: id,
      remoteHost: remoteHost,
      remotePort: remotePort,
      localPort: socket.port,
    );
    _sockets[id] = socket;
    _forwards.add(forward);

    // Every accepted connection gets its own channel: an SSH forward carries one
    // TCP stream, so a browser's parallel connections need a channel each.
    socket.listen(
      (client) => unawaited(_carry(forward, client)),
      // A listening socket that errors (the interface went away) takes its
      // forward with it rather than staying listed and dead.
      onError: (_) => unawaited(stop(id)),
      cancelOnError: true,
    );

    return forward;
  }

  /// Stops the tunnel [id], closing its listening socket and every channel still
  /// open on it.
  Future<void> stop(String id) async {
    final socket = _sockets.remove(id);
    _forwards.removeWhere((forward) => forward.id == id);
    await socket?.close();
  }

  /// Stops everything and refuses to start anything else.
  Future<void> close() async {
    _closed = true;
    for (final socket in _sockets.values.toList()) {
      await socket.close();
    }
    _sockets.clear();
    _forwards.clear();
  }

  /// Pipes one accepted connection through a fresh channel.
  Future<void> _carry(LocalForward forward, Socket client) async {
    final ForwardChannel channel;
    try {
      channel = await _opener.openForward(
        remoteHost: forward.remoteHost,
        remotePort: forward.remotePort,
      );
    } catch (_) {
      // The server refused the channel — the port is closed there, or the
      // server's `AllowTcpForwarding` is off. Closing the client's connection is
      // the honest outcome: it can then see the failure at once instead of
      // waiting on a socket that will never answer.
      client.destroy();
      return;
    }
    forward.connections++;

    // Both directions are wired before either is listened to, so no byte can
    // arrive in the gap where a listener does not exist yet.
    final toRemote = client.listen(
      channel.write,
      onDone: channel.close,
      onError: (_) => channel.close(),
      cancelOnError: true,
    );
    channel.stream.listen(
      client.add,
      onDone: () async {
        await toRemote.cancel();
        client.destroy();
      },
      onError: (_) => client.destroy(),
      cancelOnError: true,
    );
  }
}

/// Why a tunnel could not be started.
enum PortForwardFailure {
  /// The local port is taken, or the address cannot be bound.
  bindFailed,

  /// There is no session to forward over.
  sessionClosed,
}

/// A failure with a code, so the message is chosen by the UI and translated
/// rather than baked in here.
class PortForwardException implements Exception {
  final PortForwardFailure kind;
  final String? detail;

  const PortForwardException(this.kind, [this.detail]);

  @override
  String toString() => 'PortForwardException($kind${detail == null ? '' : ': $detail'})';
}
