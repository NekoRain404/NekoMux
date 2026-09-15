import 'package:flutter_test/flutter_test.dart';
import 'package:neko_mux/pages/console/host_identity.dart';
import 'package:neko_mux/pages/console/probe_command.dart';
import 'package:neko_mux/services/command_result.dart';

/// Byte-exact `uname -a` output from a Debian host.
const String unameOutputLinux =
    'Linux build01 6.8.0-45-generic #45-Ubuntu SMP PREEMPT_DYNAMIC '
    'Fri Aug 16 13:04:46 UTC 2024 x86_64 x86_64 x86_64 GNU/Linux';

/// The BSD shape, which starts with the host name.
const String unameOutputBsd =
    'FreeBSD host02 14.1-RELEASE-p5 FreeBSD 14.1-RELEASE-p5 GENERIC amd64';

/// `cat /etc/os-release | head -4`
const String osReleaseOutput = '''
PRETTY_NAME="Debian GNU/Linux 12 (bookworm)"
NAME="Debian GNU/Linux"
VERSION_ID="12"
VERSION="12 (bookworm)"
''';

/// A runner that answers from a fixed table, and records what was asked.
class _TableRunner {
  _TableRunner(this.responses);

  final Map<String, Future<CommandResult> Function()> responses;
  final List<String> commands = [];

  Future<CommandResult> call(String command) {
    commands.add(command);
    final response = responses[command];
    if (response == null) {
      throw StateError('unexpected command: $command');
    }
    return response();
  }
}

CommandResult _ok(String stdout) => CommandResult(stdout: stdout, exitCode: 0);

void main() {
  group('parseKernelTriple', () {
    test('takes the first three tokens of a real uname line', () {
      expect(
        parseKernelTriple(unameOutputLinux),
        'Linux build01 6.8.0-45-generic',
      );
      expect(
        parseKernelTriple(unameOutputBsd),
        'FreeBSD host02 14.1-RELEASE-p5',
      );
    });

    test('collapses extra whitespace instead of counting empty tokens', () {
      expect(parseKernelTriple('Linux   host01\t6.8.0'), 'Linux host01 6.8.0');
    });

    test('returns null for every short output', () {
      // This is the defect: `split(' ').sublist(0, 3)` threw
      // `RangeError: Invalid value: Not in inclusive range 0..1: 3` on output
      // this short, the empty catch swallowed it, and the header stayed blank.
      expect(parseKernelTriple('Linux'), isNull);
      expect(parseKernelTriple('Linux host01'), isNull);
      expect(parseKernelTriple(''), isNull);
      expect(parseKernelTriple('   '), isNull);
      expect(parseKernelTriple('\n'), isNull);
    });

    test('never throws, whatever the error string looks like', () {
      for (final output in [
        'sh: uname: not found',
        'Connection closed by remote host',
        '\t\n ',
        'uname -a',
      ]) {
        expect(
          () => parseKernelTriple(output),
          returnsNormally,
          reason: output,
        );
      }
    });
  });

  group('parsePrettyName', () {
    test('strips the quotes and keeps the inner spacing', () {
      expect(
        parsePrettyName(osReleaseOutput),
        'Debian GNU/Linux 12 (bookworm)',
      );
    });

    test('returns null when the line is absent or empty', () {
      expect(parsePrettyName('NAME="Debian"'), isNull);
      expect(parsePrettyName('PRETTY_NAME=""'), isNull);
      expect(parsePrettyName(''), isNull);
    });
  });

  group('HostIdentity.osInfo', () {
    test('puts the distro above the kernel', () {
      const identity = HostIdentity(
        prettyName: 'Debian GNU/Linux 12',
        kernel: 'Linux build01 6.8.0-45-generic',
      );
      expect(
        identity.osInfo,
        'Debian GNU/Linux 12\nLinux build01 6.8.0-45-generic',
      );
    });

    test('drops an empty part rather than leaving a blank line', () {
      const kernelOnly = HostIdentity(kernel: 'Linux build01 6.8.0');
      expect(kernelOnly.osInfo, 'Linux build01 6.8.0');

      const distroOnly = HostIdentity(prettyName: 'Debian GNU/Linux 12');
      expect(distroOnly.osInfo, 'Debian GNU/Linux 12');

      expect(HostIdentity.unknown.osInfo, '');
      expect(HostIdentity.unknown.isEmpty, isTrue);
    });
  });

  group('fetchHostIdentity', () {
    test('reads all three fields', () async {
      final runner = _TableRunner({
        'hostname': () async => _ok('build01\n'),
        'cat /etc/os-release 2>/dev/null | head -4': () async =>
            _ok(osReleaseOutput),
        'uname -a': () async => _ok(unameOutputLinux),
      });

      final identity = await fetchHostIdentity(
        runner.call,
        timeout: const Duration(seconds: 1),
      );

      expect(identity.hostname, 'build01');
      expect(identity.prettyName, 'Debian GNU/Linux 12 (bookworm)');
      expect(identity.kernel, 'Linux build01 6.8.0-45-generic');
    });

    test('a short uname does not throw and keeps the rest', () async {
      final runner = _TableRunner({
        'hostname': () async => _ok('build01\n'),
        'cat /etc/os-release 2>/dev/null | head -4': () async =>
            _ok(osReleaseOutput),
        // What a dropped connection or a missing `uname` leaves behind.
        'uname -a': () async => _ok(''),
      });

      final identity = await fetchHostIdentity(
        runner.call,
        timeout: const Duration(seconds: 1),
      );

      expect(identity.kernel, '');
      expect(identity.hostname, 'build01');
      expect(identity.osInfo, 'Debian GNU/Linux 12 (bookworm)');
    });

    test('a failing command leaves only its own field empty', () async {
      final runner = _TableRunner({
        'hostname': () async => _ok('build01\n'),
        'cat /etc/os-release 2>/dev/null | head -4': () async =>
            throw StateError('channel closed'),
        'uname -a': () async => _ok(unameOutputLinux),
      });

      final identity = await fetchHostIdentity(
        runner.call,
        timeout: const Duration(seconds: 1),
      );

      expect(identity.prettyName, '');
      expect(identity.hostname, 'build01');
      expect(identity.kernel, startsWith('Linux build01'));
    });

    test('raises when nothing could be read', () async {
      final runner = _TableRunner({
        'hostname': () async => _ok(''),
        'cat /etc/os-release 2>/dev/null | head -4': () async =>
            _ok('No such file or directory'),
        'uname -a': () async => _ok(''),
      });

      // The old code answered this with a blank header and an empty catch.
      // Silence here is what let a dropped link look like a host with no name.
      await expectLater(
        fetchHostIdentity(runner.call, timeout: const Duration(seconds: 1)),
        throwsA(isA<ProbeException>()),
      );
    });

    test('raises the reason a dead link gives', () async {
      final runner = _TableRunner({
        'hostname': () async => throw StateError('SSH 未连接'),
        'cat /etc/os-release 2>/dev/null | head -4': () async =>
            throw StateError('SSH 未连接'),
        'uname -a': () async => throw StateError('SSH 未连接'),
      });

      await expectLater(
        fetchHostIdentity(runner.call, timeout: const Duration(seconds: 1)),
        throwsA(
          isA<ProbeException>().having(
            (e) => e.detail,
            'detail',
            contains('SSH 未连接'),
          ),
        ),
      );
    });
  });
}
