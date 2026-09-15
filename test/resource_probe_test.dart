import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:neko_mux/pages/console/probe_command.dart';
import 'package:neko_mux/pages/console/resource_probe.dart';
import 'package:neko_mux/services/command_result.dart';

// ---------------------------------------------------------------------------
// Fixtures — real command output, kept byte-exact.
// 用例数据——真实命令输出，逐字节保留。
// ---------------------------------------------------------------------------

/// `cat /proc/stat | head -1` on the development machine (Linux 7.2.4-zen2,
/// 16 cores), captured three seconds apart while the machine was busy.
/// 开发机（Linux 7.2.4-zen2，16 核）上 `cat /proc/stat | head -1` 的输出，间隔
/// 三秒，其间机器处于忙碌状态。
///
/// These are the captured lines, not values picked to make the delta land on a
/// round percentage: the numbers the tests below assert — idle, total, and the
/// 63.74 % between them — are simply what this pair of snapshots produces.
/// 这两行是抓取所得，而不是为了让增量凑成一个好看的百分比而挑的数值：下面测试断言的
/// 数字——idle、total，以及两者之间的 63.74 %——就是这一对快照实际产生的结果。
///
/// The arithmetic they feed: idle = fields 4 + 5 (idle + iowait); total = the
/// sum of the counters.
/// 它们参与的运算：idle = 第 4、5 个字段之和（idle + iowait）；total = 各计数器之和。
const String statBefore =
    'cpu  280869144 476059 15316359 179087251 867619 1985275 1122280 0 0 0';
const String statAfter =
    'cpu  280871631 476059 15316665 179088844 867637 1985295 1122299 0 0 0';

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
      // idle = 179087251 + 867619, total = the sum of the ten counters.
      expect(sample.cpuTimes.idle, 179954870);
      expect(sample.cpuTimes.total, 479723987);
    });

    test('the second sample is the delta since the first', () async {
      final runner = _Runner({
        cpuCommand: [() => _result(statBefore), () => _result(statAfter)],
        memoryCommand: [() => _result(freeOutput), () => _result(freeOutput)],
      });
      final probe = ResourceProbe(run: runner.call);

      final first = await probe.read();
      final second = await probe.read(previous: first.cpuTimes);

      // The captured pair: total +4443, idle +1611 → (4443 - 1611) / 4443 =
      // 63.74 %.
      expect(second.cpuUsage, closeTo(63.74, 0.01));
      expect(second.cpuTimes.total, 479728430);
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
      expect(sample.cpuTimes.total, 479723987);
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

      // The content, not its length. A 61-character result is also what
      // dropping the ellipsis and keeping one more character produces, and the
      // ellipsis is the only thing telling the reader the text was cut — the
      // whole point of bounding it rather than pretending that is all there
      // was.
      // 断言的是内容而非长度。丢掉省略号、再多留一个字符同样会得到 61 个字符的结果，
      // 而省略号正是唯一告诉读者文本被截断了的标记——这正是要限长而不是假装这就是
      // 全部内容的意义所在。
      expect(describeOutput('x' * 200), '${'x' * 60}…');
      // The boundary: exactly the limit is passed through untouched.
      // 边界：恰好等于上限的内容原样返回。
      expect(describeOutput('y' * 60), 'y' * 60);
      expect(describeOutput('y' * 61), '${'y' * 60}…');
    });
  });
}
