import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:neko_mux/models/credential.dart';
import 'package:neko_mux/models/host.dart';
import 'package:neko_mux/pages/console/resource_probe.dart';
import 'package:neko_mux/services/disk_usage.dart';
import 'package:neko_mux/services/ssh_service.dart';

/// The disk probe against a real server, run ON THE PHONE.
///
/// The parser's own tests run against a `df` fixture this repository wrote, and
/// a fixture can only confirm that the parser agrees with its author. What this
/// suite adds is the part a fixture cannot: that the command produces output of
/// the shape the parser expects, on a machine nobody tuned for it — the columns,
/// the units, the pseudo-filesystems, the mount points.
///
/// Requirements: the transfer fixture container up and `adb reverse tcp:2222
/// tcp:2222`.
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

  testWidgets('the command the app runs produces output the parser reads', (
    tester,
  ) async {
    // The raw command, first: a probe that runs something `df` does not
    // understand fails here with the server's own words rather than as an empty
    // panel on a phone.
    final result = await ssh.runCommand(ResourceProbe.diskCommand);

    expect(result.exitCode, 0, reason: result.stderr);
    expect(
      result.stdout,
      contains('Filesystem'),
      reason: 'the POSIX header is what proves -P was honoured',
    );

    final filesystems = parseDf(result.stdout);
    expect(
      filesystems,
      isNotEmpty,
      reason: 'the container has a root filesystem; if this is empty the '
          'parser and the command disagree',
    );
  });

  testWidgets('the probe reads a root filesystem with plausible numbers', (
    tester,
  ) async {
    final probe = ResourceProbe(run: ssh.runCommand);
    final filesystems = await probe.readDisk();

    expect(filesystems, isNotEmpty);
    final root = filesystems.firstWhere(
      (f) => f.mountPoint == '/',
      orElse: () => throw StateError(
        'no / among ${filesystems.map((f) => f.mountPoint).toList()}',
      ),
    );

    expect(root.totalBytes, greaterThan(0));
    expect(root.usedBytes, greaterThan(0));
    expect(
      root.usedBytes,
      lessThanOrEqualTo(root.totalBytes),
      reason: 'used above total means the columns were read out of order',
    );
    expect(root.usedPercent, inInclusiveRange(0, 100));
  });

  testWidgets('the list comes back ordered by fullness', (tester) async {
    final filesystems = await ResourceProbe(run: ssh.runCommand).readDisk();

    final percentages = [
      for (final f in filesystems)
        if (f.usedPercent != null) f.usedPercent!,
    ];
    for (var i = 1; i < percentages.length; i++) {
      expect(
        percentages[i],
        lessThanOrEqualTo(percentages[i - 1]),
        reason: 'the fullest filesystem has to be the first one a user reads',
      );
    }
  });

  testWidgets('a directory that is not there is reported, not guessed', (
    tester,
  ) async {
    // The command is fixed, so this pins the failure path instead: a `df` aimed
    // at something that does not exist exits non-zero, and the probe must say so
    // rather than returning an empty list as though the host had no disks.
    final result = await ssh.runCommand('df -Pk /no/such/path');

    expect(result.exitCode, isNot(0));
    expect(
      parseDf(result.stdout),
      isEmpty,
      reason: 'error output must not be read as a filesystem',
    );
  });
}
