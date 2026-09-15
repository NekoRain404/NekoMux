import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:neko_mux/pages/console/probe_command.dart';
import 'package:neko_mux/pages/console/resource_probe.dart';
import 'package:neko_mux/services/command_result.dart';

// ---------------------------------------------------------------------------
// Fixtures — real command output, kept byte-exact.
// 用例数据——真实命令输出，逐字节保留。
// ---------------------------------------------------------------------------

/// `cat /proc/stat | head -1`, two snapshots taken 3 seconds apart.
/// idle = fields 4 + 5 (idle + iowait); total = the sum of the counters.
const String statBefore = 'cpu  100 10 50 800 40 0 10 0 0 0';
const String statAfter = 'cpu  140 12 60 900 45 0 12 0 0 0';

/// `LC_ALL=C free -m`
const String freeOutput = '''
               total        used        free      shared  buff/cache   available
Mem:          126435       66204       51765        1484       11238       60231
Swap:         163839       33033      130806
''';

/// Answers each command from a list, and records the order they were asked in.
class _Runner {
  _Runner(this.responses);

  final Map<String, List<Future<CommandResult> Function()>> responses;
  final List<String> commands = [];

  Future<CommandResult> call(String command) {
    commands.add(command);
    final queue = responses[command];
    if (queue == null || queue.isEmpty) {
      throw StateError('unexpected command: $command');
    }
    return queue.removeAt(0)();
  }
}

Future<CommandResult> _result(String stdout, {int? exitCode = 0}) async =>
    CommandResult(stdout: stdout, exitCode: exitCode);

void main() {
  const cpuCommand = ResourceProbe.cpuCommand;
  const memoryCommand = ResourceProbe.memoryCommand;

  group('ResourceProbe.read', () {
    test('asks for both sources, in a fixed order', () async {
      final runner = _Runner({
        cpuCommand: [() => _result(statBefore)],
        memoryCommand: [() => _result(freeOutput)],
      });

      final sample = await ResourceProbe(run: runner.call).read();

      expect(runner.commands, [cpuCommand, memoryCommand]);
      expect(sample.memoryUsage, closeTo(52.36, 0.01));
    });

    test('the first sample carries no CPU usage', () async {
      final runner = _Runner({
        cpuCommand: [() => _result(statBefore)],
        memoryCommand: [() => _result(freeOutput)],
      });

      final sample = await ResourceProbe(run: runner.call).read();

      // Usage is a delta between two counter snapshots, so the first one has no
      // value at all. Reporting 0 for it would invent a measurement — and an
      // idle-looking CPU is exactly what a wrong 0 reads as.
      expect(sample.cpuUsage, isNull);
      expect(sample.cpuTimes.idle, 840);
      expect(sample.cpuTimes.total, 1010);
    });

    test('the second sample is the delta since the first', () async {
      final runner = _Runner({
        cpuCommand: [() => _result(statBefore), () => _result(statAfter)],
        memoryCommand: [() => _result(freeOutput), () => _result(freeOutput)],
      });
      final probe = ResourceProbe(run: runner.call);

      final first = await probe.read();
      final second = await probe.read(previous: first.cpuTimes);

      // total +159, idle +105 → (159 - 105) / 159 = 33.96 %
      expect(second.cpuUsage, closeTo(33.96, 0.01));
      expect(second.cpuTimes.total, 1169);
    });

    test('rejects output that is not a cpu line', () async {
      final runner = _Runner({
        cpuCommand: [() => _result('sh: cat: /proc/stat: No such file')],
        memoryCommand: [() => _result(freeOutput)],
      });

      await expectLater(
        ResourceProbe(run: runner.call).read(),
        throwsA(
          isA<ProbeException>()
              .having((e) => e.kind, 'kind', ProbeFailure.failed)
              // The failure names what came back, so a wrong 0 can no longer be
              // the only trace of a failed read.
              .having((e) => e.detail, 'detail', contains('No such file')),
        ),
      );
      // The second command is not asked once the first has failed.
      expect(runner.commands, [cpuCommand]);
    });

    test('rejects a reported non-zero exit status', () async {
      final runner = _Runner({
        cpuCommand: [() => _result('', exitCode: 127)],
        memoryCommand: [() => _result(freeOutput)],
      });

      await expectLater(
        ResourceProbe(run: runner.call).read(),
        throwsA(
          isA<ProbeException>()
              .having((e) => e.kind, 'kind', ProbeFailure.rejected)
              .having((e) => e.detail, 'detail', contains('127')),
        ),
      );
    });

    test('accepts a server that reports no exit status at all', () async {
      final runner = _Runner({
        cpuCommand: [() => _result(statBefore, exitCode: null)],
        memoryCommand: [() => _result(freeOutput, exitCode: null)],
      });

      // `CommandResult.ok` treats an unreported status as "unknown", not
      // success. For these read-only probes the parse is the stronger check, so
      // the status is allowed through to it — otherwise a server that never
      // reports exit codes could not be monitored at all.
      final sample = await ResourceProbe(run: runner.call).read();
      expect(sample.memoryUsage, closeTo(52.36, 0.01));
      expect(sample.cpuTimes.total, 1010);
    });

    test('rejects a free output it cannot read', () async {
      final runner = _Runner({
        cpuCommand: [() => _result(statBefore)],
        memoryCommand: [() => _result('')],
      });

      // `parseFree` answers an unreadable table with `[0, 0, 0]`, which
      // `memoryUsagePercentFromFree` turns into a perfectly plausible 0.0 %.
      await expectLater(
        ResourceProbe(run: runner.call).read(),
        throwsA(
          isA<ProbeException>()
              .having((e) => e.kind, 'kind', ProbeFailure.failed)
              .having((e) => e.detail, 'detail', contains(memoryCommand)),
        ),
      );
    });

    test('gives up on a command that never answers', () async {
      final runner = _Runner({
        cpuCommand: [() => Completer<CommandResult>().future],
        memoryCommand: [() => _result(freeOutput)],
      });

      // A wedged server used to accumulate two never-completing channels every
      // three seconds, against sshd's MaxSessions.
      await expectLater(
        ResourceProbe(
          run: runner.call,
          timeout: const Duration(milliseconds: 50),
        ).read(),
        throwsA(
          isA<ProbeException>().having(
            (e) => e.kind,
            'kind',
            ProbeFailure.timedOut,
          ),
        ),
      );
    });
  });

  group('describeOutput', () {
    test('flattens and bounds what a probe returned', () {
      expect(describeOutput(''), '<empty>');
      expect(describeOutput('  \n\t '), '<empty>');
      expect(describeOutput('line one\nline two'), 'line one line two');
      expect(describeOutput('x' * 200).length, 61);
    });
  });
}
