import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:neko_mux/services/port_forward_service.dart';

/// The tunnel, tested over real sockets.
///
/// Only the SSH hop is faked. The listening socket, the accepted connections and
/// the two pipes that carry bytes are the real thing, because they are the part
/// that can be wrong in ways a `expect(...)` on a mock call would never see: a
/// pipe wired in one direction passes any test that only counts opens, and a
/// client left un-destroyed looks identical to one that was closed cleanly.
class _FakeChannel implements ForwardChannel {
  _FakeChannel(this._controller);

  final StreamController<Uint8List> _controller;
  final List<int> received = [];
  bool closed = false;

  /// What the fake "server" sends back.
  void emit(List<int> bytes) => _controller.add(Uint8List.fromList(bytes));

  @override
  Stream<Uint8List> get stream => _controller.stream;

  @override
  void write(List<int> data) => received.addAll(data);

  @override
  Future<void> close() async {
    closed = true;
    await _controller.close();
  }
}

class _FakeOpener implements ForwardOpener {
  /// When true, opening a channel throws — a closed port on the server.
  /// Set by the test that exercises a refused channel.
  bool refuse = false;

  final List<_FakeChannel> channels = [];
  final List<String> opened = [];

  @override
  Future<ForwardChannel> openForward({
    required String remoteHost,
    required int remotePort,
  }) async {
    opened.add('$remoteHost:$remotePort');
    if (refuse) throw StateError('channel refused');
    final channel = _FakeChannel(StreamController<Uint8List>());
    channels.add(channel);
    return channel;
  }
}

Future<List<int>> readSome(Socket socket, {int bytes = 1}) async {
  final collected = <int>[];
  final done = Completer<void>();
  late StreamSubscription<Uint8List> sub;
  sub = socket.listen((data) {
    collected.addAll(data);
    if (collected.length >= bytes && !done.isCompleted) done.complete();
  }, onDone: () {
    if (!done.isCompleted) done.complete();
  });
  await done.future.timeout(const Duration(seconds: 5));
  await sub.cancel();
  return collected;
}

void main() {
  late _FakeOpener opener;
  late PortForwardService service;

  setUp(() {
    opener = _FakeOpener();
    service = PortForwardService(opener);
  });

  tearDown(() => service.close());

  test('a connection reaches the remote endpoint and comes back', () async {
    // The whole feature in one assertion: bytes written by the client arrive at
    // the far end, and bytes the far end sends arrive at the client.
    final forward = await service.start(
      remoteHost: '127.0.0.1',
      remotePort: 8080,
    );
    expect(forward.localPort, greaterThan(0));
    expect(opener.opened, isEmpty, reason: 'nothing opens until someone connects');

    final client = await Socket.connect(
      InternetAddress.loopbackIPv4,
      forward.localPort,
    );
    addTearDown(client.destroy);

    // Give the accept loop a turn to open the channel.
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(opener.opened, ['127.0.0.1:8080']);
    expect(opener.channels, hasLength(1));

    client.add(utf8.encode('GET / HTTP/1.0\r\n\r\n'));
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(
      utf8.decode(opener.channels.single.received),
      contains('GET / HTTP/1.0'),
      reason: 'client bytes must reach the remote endpoint',
    );

    opener.channels.single.emit(utf8.encode('HTTP/1.0 200 OK\r\n\r\n'));
    expect(utf8.decode(await readSome(client, bytes: 15)), contains('200 OK'));
  });

  test('each connection gets its own channel', () async {
    // An SSH forward carries one TCP stream, so a browser's parallel requests
    // need a channel each. Reusing one would interleave two responses into
    // nonsense.
    final forward = await service.start(remoteHost: '127.0.0.1', remotePort: 80);

    final first = await Socket.connect(
      InternetAddress.loopbackIPv4,
      forward.localPort,
    );
    final second = await Socket.connect(
      InternetAddress.loopbackIPv4,
      forward.localPort,
    );
    addTearDown(first.destroy);
    addTearDown(second.destroy);

    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(opener.channels, hasLength(2));
    expect(forward.connections, 2);
  });

  test('a refused channel closes the client instead of leaving it hanging',
      () async {
    // The server refusing (port closed there, or AllowTcpForwarding off) must
    // end the client's connection: a socket that never answers is worse than one
    // that closes, because the caller waits on it.
    opener.refuse = true;
    final forward = await service.start(remoteHost: '127.0.0.1', remotePort: 9);

    final client = await Socket.connect(
      InternetAddress.loopbackIPv4,
      forward.localPort,
    );
    final closed = Completer<void>();
    client.listen((_) {}, onDone: closed.complete, onError: (_) {});

    await closed.future.timeout(
      const Duration(seconds: 5),
      onTimeout: () => fail('the client was left open after the channel failed'),
    );
  });

  test('stop closes the listening socket', () async {
    final forward = await service.start(remoteHost: '127.0.0.1', remotePort: 80);
    expect(service.isRunning(forward.id), isTrue);

    await service.stop(forward.id);

    expect(service.isRunning(forward.id), isFalse);
    expect(service.forwards, isEmpty);
    await expectLater(
      Socket.connect(InternetAddress.loopbackIPv4, forward.localPort),
      throwsA(isA<SocketException>()),
    );
  });

  test('an occupied local port fails loudly rather than moving', () async {
    // Silently binding another port would leave the user with a URL that does
    // not match the one they configured, and no way to tell.
    final taken = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(taken.close);

    await expectLater(
      service.start(
        remoteHost: '127.0.0.1',
        remotePort: 80,
        localPort: taken.port,
      ),
      throwsA(
        isA<PortForwardException>().having(
          (e) => e.kind,
          'kind',
          PortForwardFailure.bindFailed,
        ),
      ),
    );
    expect(service.forwards, isEmpty);
  });

  test('a requested local port is honoured when it is free', () async {
    final free = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final wanted = free.port;
    await free.close();

    final forward = await service.start(
      remoteHost: '127.0.0.1',
      remotePort: 5432,
      localPort: wanted,
    );

    expect(forward.localPort, wanted);
  });

  test('closing the service stops the tunnels and refuses new ones', () async {
    final forward = await service.start(remoteHost: '127.0.0.1', remotePort: 80);

    await service.close();

    expect(service.forwards, isEmpty);
    await expectLater(
      Socket.connect(InternetAddress.loopbackIPv4, forward.localPort),
      throwsA(isA<SocketException>()),
    );
    await expectLater(
      service.start(remoteHost: '127.0.0.1', remotePort: 80),
      throwsA(
        isA<PortForwardException>().having(
          (e) => e.kind,
          'kind',
          PortForwardFailure.sessionClosed,
        ),
      ),
    );
  });

  test('the addresses it reports are the ones the user types', () async {
    final forward = await service.start(
      remoteHost: '127.0.0.1',
      remotePort: 9090,
    );
    // Pointing a browser at this app's own port is the entire point, so the
    // string has to be exactly what goes in the address bar.
    expect(forward.localAddress, '127.0.0.1:${forward.localPort}');
    expect(forward.remoteAddress, '127.0.0.1:9090');
  });
}
