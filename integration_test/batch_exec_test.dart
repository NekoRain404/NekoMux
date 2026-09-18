import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:neko_mux/models/credential.dart';
import 'package:neko_mux/models/host.dart';
import 'package:neko_mux/services/batch_runner.dart';
import 'package:neko_mux/services/command_result.dart';
import 'package:neko_mux/services/ssh_service.dart';

/// Batch execution, run ON THE PHONE against two REAL servers.
///
/// The unit tests fake the sessions, which is what makes them fast and
/// deterministic — and also what stops them from answering the question a batch
/// feature actually has to answer: when the command goes out to several
/// machines at once, does each one get it, and does each answer arrive back on
/// the connection it belongs to? A fan-out bug that sent the same command twice
/// down one connection, or that attributed one server's output to another, would
/// pass every unit test here.
///
/// Requirements (see integration_test/README.md), BOTH containers:
///   * `nekomux-test-ssh` on 127.0.0.1:2222 (hostname is the container id)
///   * `nekomux-test-ssh-2` on 127.0.0.1:2223, started with `-h neko-target`
///   * `adb reverse tcp:2222 tcp:2222` and `adb reverse tcp:2223 tcp:2223`
///
/// The second container exists precisely so the two answers DIFFER: the test
/// asserts on distinct hostnames, which is only observable when the batch is
/// really talking to two machines.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  /// The host that answers with a name of its own choosing.
  final target = Host(
    id: 'target',
    alias: 'neko-target',
    ipAddress: '127.0.0.1',
    port: 2223,
    credentialId: 'integration',
  );

  /// The original fixture; its hostname is its container id, so the test only
  /// asserts that it differs from the target's.
  final fixture = Host(
    id: 'fixture',
    alias: 'fixture',
    ipAddress: '127.0.0.1',
    port: 2222,
    credentialId: 'integration',
  );

  /// A port nothing is listening on, for the failure-isolation case.
  final dead = Host(
    id: 'dead',
    alias: 'dead',
    ipAddress: '127.0.0.1',
    port: 2299,
    credentialId: 'integration',
  );

  const credential = Credential(
    id: 'integration',
    name: 'nekotest',
    authType: 0,
    username: 'nekotest',
    secretData: 'nekotest',
  );

  Future<bool> acceptAnyKey(String _) async => true;

  /// A real session, shaped for the runner.
  ///
  /// Built here rather than through the page's factory because the page's
  /// verifier needs the SQLite known-hosts table, and this suite deliberately
  /// has no database — see the file header of the transfer suite for why these
  /// tests are kept thin.
  BatchSession sessionFor(Host host, Credential credential) =>
      _RealSession(host: host, credential: credential, verify: acceptAnyKey);

  testWidgets('one command runs on two servers, each answering for itself', (
    tester,
  ) async {
    final runner = BatchRunner(onUpdate: (_) {});
    addTearDown(runner.cancel);

    await runner.run(
      hosts: [fixture, target],
      command: 'hostname',
      sessionFor: sessionFor,
      credentialFor: (_) => credential,
    );

    expect(runner.results, hasLength(2));
    for (final result in runner.results) {
      expect(
        result.status,
        BatchStatus.succeeded,
        reason: '${result.host.alias}: ${result.error ?? result.stderr}',
      );
      expect(result.exitCode, 0);
    }

    final names = runner.results.map((r) => r.stdout.trim()).toList();
    expect(
      names.toSet(),
      hasLength(2),
      reason: 'two servers must not answer with one name — that would mean the '
          'command reached only one of them',
    );
    expect(
      names,
      contains('neko-target'),
      reason: 'the command must have reached the second container',
    );
  });

  testWidgets('a host that cannot be reached does not stop the others', (
    tester,
  ) async {
    final runner = BatchRunner(onUpdate: (_) {});
    addTearDown(runner.cancel);

    await runner.run(
      hosts: [fixture, dead, target],
      command: 'hostname',
      sessionFor: sessionFor,
      credentialFor: (_) => credential,
    );

    expect(runner.results[0].status, BatchStatus.succeeded);
    expect(runner.results[1].status, BatchStatus.unreachable);
    expect(runner.results[2].status, BatchStatus.succeeded);
    expect(runner.results[2].stdout.trim(), 'neko-target');
  });

  testWidgets('a failing command is reported as failing, with its output', (
    tester,
  ) async {
    // The exit status is the whole point of running something on a server: a
    // batch that reported "done" for a command that exited 1 would be worse than
    // no batch at all.
    final runner = BatchRunner(onUpdate: (_) {});
    addTearDown(runner.cancel);

    await runner.run(
      hosts: [target],
      command: 'echo about-to-fail >&2; exit 3',
      sessionFor: sessionFor,
      credentialFor: (_) => credential,
    );

    final result = runner.results.single;
    expect(result.status, BatchStatus.failed);
    expect(result.exitCode, 3);
    expect(result.stderr, contains('about-to-fail'));
  });
}

/// A [BatchSession] over a real SSH connection.
class _RealSession implements BatchSession {
  final Host host;
  final Credential credential;
  final Future<bool> Function(String fingerprint) verify;

  SshConnection? _connection;

  _RealSession({
    required this.host,
    required this.credential,
    required this.verify,
  });

  @override
  bool trustRefused = false;

  @override
  Future<void> connect() async {
    final connection = SshConnection(
      host: host,
      credential: credential,
      onHostKeyVerify: verify,
    );
    _connection = connection;
    await connection.connect();
  }

  @override
  Future<CommandResult> run(String command) async {
    final connection = _connection!;
    return connection.runCommand(command);
  }

  @override
  void dispose() {
    _connection?.disconnect();
    _connection?.dispose();
    _connection = null;
  }
}
