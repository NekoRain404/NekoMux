import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:neko_mux/models/credential.dart';
import 'package:neko_mux/models/host.dart';
import 'package:neko_mux/pages/containers/container_detail_loader.dart';
import 'package:neko_mux/pages/containers/docker_detail.dart';
import 'package:neko_mux/services/ssh_service.dart';

/// What CAN be verified about the detail view on a host without Docker.
///
/// The test server has no Docker daemon, so no real `docker inspect` happens
/// here. That is not the gap this file is for: the parser is covered by
/// `test/docker_detail_test.dart` against output captured from a real daemon,
/// which is stronger evidence than a made-up fixture could give.
///
/// What is left is the part a unit test structurally cannot reach — the trip.
/// The template is a long string of braces, quotes and backslashes, and it is
/// handed to a shell. If the quoting is wrong the daemon receives a mangled
/// template, and the failure is not a clean error: `{{.State.Error}}` losing a
/// brace still produces a line, just a wrong one. So the command goes through a
/// real SSH session to a real shell with the program swapped for one that
/// prints its own argument list, exactly as the `docker run` suite does.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final host = Host(
    id: 'integration',
    alias: 'docker-test-ssh',
    ipAddress: '127.0.0.1',
    port: 2222,
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

  late SshConnection ssh;

  setUp(() async {
    ssh = SshConnection(
      host: host,
      credential: credential,
      onHostKeyVerify: acceptAnyKey,
    );
    await ssh.connect();
  });

  tearDown(() => ssh.dispose());

  testWidgets('the inspect template arrives at the shell byte for byte', (
    tester,
  ) async {
    final command = dockerDetailCommand('web');
    expect(command, startsWith('docker inspect --format '));

    // Swap the program for one that reports the arguments the shell handed it,
    // keeping the template exactly as the app built it.
    final probe = command.replaceFirst(
      'docker inspect --format',
      "printf '%s\\n'",
    );
    final result = await ssh.runCommand(probe);

    expect(result.exitCode, 0, reason: result.combined);
    final parts = result.stdout.split('\n');

    expect(
      parts.first,
      dockerInspectTemplate,
      reason: 'the template must survive the shell untouched: a single dropped '
          'brace or backslash makes the daemon answer with a Go template error, '
          'and a subtly wrong one still produces a line that parses into wrong '
          'fields rather than failing loudly',
    );
    expect(
      parts.length,
      greaterThan(1),
      reason: 'the container name has to remain its own argument, not be '
          'swallowed into the template',
    );
    expect(parts[1], 'web');
    expect(
      result.combined,
      isNot(contains('backslash')),
      reason: 'two backslashes reaching printf would print an escape sequence '
          'instead of the tab the template asks for',
    );
  });

  testWidgets('the template names every field the parser reads', (tester) async {
    // A guard against the two halves drifting: the parser reads twelve header
    // fields, and a template that stopped asking for one of them would leave
    // the parser reading a column that is now something else.
    for (final field in const [
      '.Name',
      '.State.Status',
      '.State.ExitCode',
      '.State.OOMKilled',
      '.RestartCount',
      '.HostConfig.RestartPolicy.Name',
      '.Config.Image',
      '.HostConfig.Memory',
      '.State.Health',
      '.State.StartedAt',
      '.State.FinishedAt',
      '.State.Error',
    ]) {
      expect(
        dockerInspectTemplate,
        contains(field),
        reason: '$field is read by the parser and must be requested here',
      );
    }

    // And the sections, which carry their own row prefixes.
    for (final section in const ['MOUNT', 'ENV', 'NET']) {
      expect(dockerInspectTemplate, contains(section));
    }
  });

  testWidgets('a host without docker fails rather than showing an empty '
      'container', (tester) async {
    // The failure path of the whole feature, over a real session. This fixture
    // has no `docker`, so the command exits non-zero with `command not found`,
    // and the loader the page uses must report that.
    //
    // The alternative is the bad outcome: `docker inspect` printing nothing to
    // stdout and the loader reading it as a container with no environment, no
    // mounts and no networks. That renders as a perfectly real-looking detail
    // page for a command that never ran — and the fields it leaves blank are
    // exactly the ones someone opens this view to check.
    final outcome = await loadContainerDetail(ssh, 'anything');

    expect(outcome.isLoaded, isFalse);
    expect(outcome.detail, isNull);
    expect(
      outcome.failure,
      isNotNull,
      reason: 'no detail and no failure would leave the page with nothing to '
          'render and nothing to say',
    );
    expect(outcome.failure, isNotEmpty);
  });
}
