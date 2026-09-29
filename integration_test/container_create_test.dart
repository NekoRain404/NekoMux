import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:neko_mux/models/credential.dart';
import 'package:neko_mux/models/host.dart';
import 'package:neko_mux/pages/containers/docker_run_spec.dart';
import 'package:neko_mux/pages/containers/remote_action_outcome.dart';
import 'package:neko_mux/services/ssh_service.dart';

/// What CAN be verified about creating a container, on a host without Docker.
///
/// The test server has no Docker daemon, so a real `docker run` cannot be
/// observed here — and pretending otherwise by asserting on a fake would prove
/// nothing. What this suite does instead is verify the two halves that *are*
/// observable and that a bug would hide in:
///
///   1. the command the app builds is a well-formed shell command line, by
///      sending it to a real shell and reading what the shell makes of it
///      (argument boundaries, quoting) rather than what we assume;
///   2. a host that cannot run it says so, and the app's own failure classifier
///      turns that into something a page reports — rather than into a
///      success-looking empty answer.
///
/// A container actually appearing on a Docker host is the one claim this file
/// does not make.
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

  testWidgets('the built command reaches a real shell as separate arguments', (
    tester,
  ) async {
    // `printf '%s\n'` prints one line per argument the shell saw. If the quoting
    // were wrong, the argument list would come back split, merged, or with the
    // quotes still in it — which is exactly the class of bug that turns a
    // container name into a second command.
    final plan = buildDockerRun(
      const DockerRunSpec(
        image: 'nginx:alpine',
        name: 'web; rm -rf /tmp/nothing',
        ports: ['8080:80'],
      ),
    );
    expect(plan.isOk, isTrue);

    // Swap the program for one that reports its own argument list, keeping the
    // arguments the builder produced.
    final probe = plan.command!.replaceFirst('docker run', "printf '%s\\n'");
    final result = await ssh.runCommand(probe);

    expect(result.exitCode, 0);
    final args = result.stdout.trim().split('\n');
    expect(
      args,
      contains('web; rm -rf /tmp/nothing'),
      reason: 'the name must survive as ONE argument, semicolon and all',
    );
    expect(args, contains('8080:80'));
    expect(args, contains('nginx:alpine'));
    expect(
      args.any((a) => a.contains('rm -rf') && a != 'web; rm -rf /tmp/nothing'),
      isFalse,
      reason: 'nothing may have been split into a second argument',
    );
  });

  testWidgets('a host without docker reports it rather than looking successful', (
    tester,
  ) async {
    // The failure path of the create flow: the app runs the command, the shell
    // answers `docker: command not found` on stderr with a non-zero status, and
    // the classifier the page uses must see a failure — a create that reported
    // success here would be the worst outcome the feature has.
    final plan = buildDockerRun(const DockerRunSpec(image: 'nginx'));
    final result = await ssh.runCommand(plan.command!);

    expect(
      result.exitCode,
      isNot(0),
      reason: 'there is no docker on this fixture, so this cannot succeed',
    );
    expect(
      remoteActionFailure(result),
      isNotNull,
      reason: 'the page reports this with the shell’s own words; a null here '
          'would show "Container created" for a command that never ran',
    );
  });
}
