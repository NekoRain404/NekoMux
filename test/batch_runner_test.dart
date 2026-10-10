import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:neko_mux/models/credential.dart';
import 'package:neko_mux/models/host.dart';
import 'package:neko_mux/services/batch_runner.dart';
import 'package:neko_mux/services/command_result.dart';

/// A session that answers with whatever the test scripted, and records the
/// order of what happened to it.
class _FakeSession implements BatchSession {
  _FakeSession(
    this.host, {
    this.failConnect = false,
    this.trustRefused = false,
    this.exitCode = 0,
    this.stdout = 'done',
    this.stderr = '',
    this.gate,
  });

  final Host host;
  final bool failConnect;
  final int? exitCode;
  final String stdout;
  final String stderr;

  /// When set, `run` waits on it — used to hold a session "in flight".
  final Completer<void>? gate;

  @override
  bool trustRefused;

  var connectCalls = 0;
  var runCalls = 0;
  var disposed = false;

  @override
  Future<void> connect() async {
    connectCalls++;
    if (failConnect) throw Exception('connect failed');
  }

  @override
  Future<CommandResult> run(String command) async {
    runCalls++;
    if (gate != null) await gate!.future;
    return CommandResult(stdout: stdout, stderr: stderr, exitCode: exitCode);
  }

  @override
  void dispose() => disposed = true;
}

/// A transfer session that records what it was asked to upload.
class _FakeTransferSession implements BatchTransferSession {
  _FakeTransferSession(this.host, {this.failUpload = false});

  final Host host;

  /// When set, [putFile] throws — one host's upload failing on its own.
  final bool failUpload;

  @override
  bool trustRefused = false;

  var connectCalls = 0;
  var disposed = false;
  final uploads = <String>[];

  @override
  Future<void> connect() async {
    connectCalls++;
  }

  @override
  Future<CommandResult> run(String command) =>
      throw UnsupportedError('a transfer session does not run commands');

  @override
  Future<void> putFile(String localPath, String remotePath) async {
    if (failUpload) throw Exception('upload failed');
    uploads.add('$localPath -> $remotePath');
  }

  @override
  void dispose() => disposed = true;
}

Host hostAt(int i) => Host(
  id: 'h$i',
  alias: 'host$i',
  ipAddress: '10.0.0.$i',
  credentialId: 'c$i',
);

const credential = Credential(
  id: 'c',
  name: 'c',
  authType: 0,
  username: 'root',
  secretData: 'x',
);

void main() {
  late List<BatchHostResult> updates;

  setUp(() => updates = []);

  BatchRunner runner({int concurrency = 4}) =>
      BatchRunner(concurrency: concurrency, onUpdate: updates.add);

  test('runs on every host and reports each one', () async {
    final sessions = <String, _FakeSession>{};
    final hosts = [hostAt(1), hostAt(2), hostAt(3)];

    final r = runner();
    await r.run(
      hosts: hosts,
      command: 'uptime',
      sessionFor: (host, _) =>
          sessions[host.id] = _FakeSession(host, stdout: 'up ${host.alias}'),
      credentialFor: (_) => credential,
    );

    expect(sessions, hasLength(3));
    expect(r.results, hasLength(3));
    expect(
      r.results.map((x) => x.status),
      everyElement(BatchStatus.succeeded),
    );
    expect(r.results.map((x) => x.stdout), [
      'up host1',
      'up host2',
      'up host3',
    ]);
    expect(
      sessions.values.every((s) => s.disposed),
      isTrue,
      reason: 'every session must be released, including on the error paths',
    );
  });

  test('one host failing does not stop the others', () async {
    // The contract that makes a batch usable: a machine that is down must not
    // hold up the twenty behind it.
    final hosts = [hostAt(1), hostAt(2), hostAt(3)];
    final r = runner();

    await r.run(
      hosts: hosts,
      command: 'uptime',
      sessionFor: (host, _) => _FakeSession(
        host,
        failConnect: host.id == 'h2',
      ),
      credentialFor: (_) => credential,
    );

    expect(r.results[0].status, BatchStatus.succeeded);
    expect(r.results[1].status, BatchStatus.unreachable);
    expect(r.results[2].status, BatchStatus.succeeded);
  });

  test('a refused host key is reported as needing trust, not as a failure',
      () async {
    // A batch never makes the trust decision, so the host is not run and the
    // user is told what to do about it — rather than being handed a generic
    // "connect failed" whose remedy is somewhere else entirely.
    final hosts = [hostAt(1), hostAt(2)];
    final r = runner();

    await r.run(
      hosts: hosts,
      command: 'uptime',
      sessionFor: (host, _) => _FakeSession(
        host,
        failConnect: true,
        trustRefused: host.id == 'h1',
      ),
      credentialFor: (_) => credential,
    );

    expect(r.results[0].status, BatchStatus.needsTrust);
    expect(r.results[1].status, BatchStatus.unreachable);
  });

  test('a host with no credential is reported, and the batch continues',
      () async {
    final hosts = [hostAt(1), hostAt(2)];
    final r = runner();

    await r.run(
      hosts: hosts,
      command: 'uptime',
      sessionFor: (host, _) => _FakeSession(host),
      credentialFor: (host) => host.id == 'h1' ? null : credential,
    );

    expect(r.results[0].status, BatchStatus.unreachable);
    expect(r.results[0].error, 'no_credential');
    expect(r.results[1].status, BatchStatus.succeeded);
  });

  test('the exit status decides success, and unknown is not success', () async {
    // `CommandResult.ok` documents that a null exit status is *unknown*: a
    // command whose result the server never reported must not be counted as
    // having worked.
    final hosts = [hostAt(1), hostAt(2), hostAt(3)];
    final r = runner();

    await r.run(
      hosts: hosts,
      command: 'systemctl restart nginx',
      sessionFor: (host, _) => switch (host.id) {
        'h1' => _FakeSession(host, exitCode: 0),
        'h2' => _FakeSession(host, exitCode: 1, stderr: 'failed'),
        _ => _FakeSession(host, exitCode: null),
      },
      credentialFor: (_) => credential,
    );

    expect(r.results[0].status, BatchStatus.succeeded);
    expect(r.results[1].status, BatchStatus.failed);
    expect(r.results[1].exitCode, 1);
    expect(r.results[1].stderr, 'failed');
    expect(r.results[2].status, BatchStatus.failed);
  });

  test('no more than the concurrency limit is in flight at once', () async {
    // Each host is a full SSH session; opening thirty at once is thirty
    // handshakes on the same phone radio, and the ones that time out first
    // would be reported as unreachable when they were merely queued.
    //
    // The measurement is "sessions created but not yet finished", which is what
    // in-flight means here: the runner publishes a terminal status only once it
    // is done with a session. Every session is released a round at a time, so
    // the batch always gets to make progress and the test cannot deadlock.
    final gates = <Completer<void>>[];
    var created = 0;
    var finished = 0;
    var peakInFlight = 0;

    final hosts = [for (var i = 0; i < 6; i++) hostAt(i)];
    final r = BatchRunner(
      concurrency: 2,
      onUpdate: (result) {
        updates.add(result);
        if (result.isTerminal) finished++;
      },
    );

    final running = r.run(
      hosts: hosts,
      command: 'uptime',
      sessionFor: (host, _) {
        created++;
        final inFlight = created - finished;
        if (inFlight > peakInFlight) peakInFlight = inFlight;
        final gate = Completer<void>();
        gates.add(gate);
        return _FakeSession(host, gate: gate);
      },
      credentialFor: (_) => credential,
    );

    for (var round = 0; round < 40 && r.isRunning; round++) {
      await Future<void>.delayed(Duration.zero);
      for (final gate in gates) {
        if (!gate.isCompleted) gate.complete();
      }
    }
    for (final gate in gates) {
      if (!gate.isCompleted) gate.complete();
    }
    await running;

    expect(peakInFlight, lessThanOrEqualTo(2));
    expect(r.results.where((x) => x.isTerminal), hasLength(6));
  });

  test('cancelling stops new hosts and marks the untouched as cancelled',
      () async {
    final gate = Completer<void>();
    final started = Completer<void>();
    final hosts = [hostAt(1), hostAt(2), hostAt(3), hostAt(4)];

    final r = BatchRunner(
      concurrency: 1,
      onUpdate: (result) {
        updates.add(result);
        if (result.status == BatchStatus.running && !started.isCompleted) {
          started.complete();
        }
      },
    );

    final running = r.run(
      hosts: hosts,
      command: 'sleep 100',
      sessionFor: (host, _) => _FakeSession(host, gate: gate),
      credentialFor: (_) => credential,
    );

    await started.future;
    r.cancel();
    gate.complete();
    await running;

    expect(r.results.first.status, BatchStatus.succeeded);
    expect(
      r.results.skip(1).map((x) => x.status),
      everyElement(BatchStatus.cancelled),
      reason: 'hosts that never started must say so, not look pending forever',
    );
    expect(r.isRunning, isFalse);
  });

  test('a second run while one is in flight is ignored', () async {
    final gate = Completer<void>();
    final started = Completer<void>();
    final hosts = [hostAt(1)];

    final r = BatchRunner(
      concurrency: 1,
      onUpdate: (x) {
        updates.add(x);
        if (x.status == BatchStatus.running && !started.isCompleted) {
          started.complete();
        }
      },
    );

    final first = r.run(
      hosts: hosts,
      command: 'sleep 1',
      sessionFor: (host, _) => _FakeSession(host, gate: gate),
      credentialFor: (_) => credential,
    );
    await started.future;

    await r.run(
      hosts: hosts,
      command: 'other',
      sessionFor: (host, _) => fail('a second run must not start sessions'),
      credentialFor: (_) => credential,
    );

    gate.complete();
    await first;
    expect(r.results, hasLength(1));
  });

  group('transferring a file', () {
    test('uploads the same file to every host, and reports each', () async {
      // The batch's whole point: the file is chosen once and the destination
      // typed once, however many hosts it goes to.
      final sessions = <String, _FakeTransferSession>{};
      final hosts = [hostAt(1), hostAt(2), hostAt(3)];

      final r = runner();
      await r.transfer(
        hosts: hosts,
        localPath: '/tmp/nginx.conf',
        remotePath: '/etc/nginx/nginx.conf',
        sessionFor: (host, _) =>
            sessions[host.id] = _FakeTransferSession(host),
        credentialFor: (_) => credential,
      );

      expect(sessions, hasLength(3));
      for (final session in sessions.values) {
        expect(session.uploads, ['/tmp/nginx.conf -> /etc/nginx/nginx.conf']);
        expect(
          session.disposed,
          isTrue,
          reason: 'every session must be released, error paths included',
        );
      }
      expect(
        r.results.map((x) => x.status),
        everyElement(BatchStatus.succeeded),
      );
    });

    test('one host failing to upload does not stop the others', () async {
      final hosts = [hostAt(1), hostAt(2), hostAt(3)];
      final r = runner();

      await r.transfer(
        hosts: hosts,
        localPath: '/tmp/nginx.conf',
        remotePath: '/etc/nginx/nginx.conf',
        sessionFor: (host, _) =>
            _FakeTransferSession(host, failUpload: host.id == 'h2'),
        credentialFor: (_) => credential,
      );

      expect(r.results[0].status, BatchStatus.succeeded);
      expect(r.results[1].status, BatchStatus.unreachable);
      expect(r.results[2].status, BatchStatus.succeeded);
    });

    test('a host with no credential is reported without being dialled', () async {
      final sessions = <String, _FakeTransferSession>{};
      final hosts = [hostAt(1), hostAt(2)];
      final r = runner();

      await r.transfer(
        hosts: hosts,
        localPath: '/tmp/nginx.conf',
        remotePath: '/etc/nginx/nginx.conf',
        sessionFor: (host, _) =>
            sessions[host.id] = _FakeTransferSession(host),
        credentialFor: (host) => host.id == 'h1' ? null : credential,
      );

      expect(r.results[0].status, BatchStatus.unreachable);
      expect(r.results[0].error, 'no_credential');
      expect(
        sessions.containsKey('h1'),
        isFalse,
        reason: 'a host with nothing to authenticate with must not be dialled',
      );
      expect(r.results[1].status, BatchStatus.succeeded);
    });
  });
}
