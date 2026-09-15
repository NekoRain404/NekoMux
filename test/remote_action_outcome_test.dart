import 'package:flutter_test/flutter_test.dart';
import 'package:neko_mux/pages/containers/remote_action_outcome.dart';
import 'package:neko_mux/services/command_result.dart';

/// The single rule the service manager, the process manager and the container
/// page share: a remote action is a success only when the remote said so.
/// 服务管理、进程管理与容器页共用的唯一规则：只有远端说成功，才算成功。
void main() {
  group('remoteActionFailure', () {
    test('reports nothing for exit status 0', () {
      expect(
        remoteActionFailure(const CommandResult(stdout: '', exitCode: 0)),
        isNull,
      );
    });

    test('a successful command whose output mentions "error" is a success', () {
      // The container page's regression, in one line: `docker stop error-logger`
      // succeeds and prints the container's name, and the old
      // `result.contains('error')` heuristic turned that into "Action failed".
      // 容器页的回归用例浓缩成一行：`docker stop error-logger` 成功并打印容器名，
      // 旧的 `result.contains('error')` 启发式却把它变成「操作失败」。
      expect(
        remoteActionFailure(
          const CommandResult(stdout: 'error-logger\n', exitCode: 0),
        ),
        isNull,
      );
      expect(
        remoteActionFailure(
          const CommandResult(
            stdout: '',
            stderr: 'WARNING: Error loading config file',
            exitCode: 0,
          ),
        ),
        isNull,
        reason: 'noise on stderr does not decide the outcome; the status does',
      );
    });

    test('the remote reason is returned verbatim', () {
      // What a non-root user gets from `systemctl stop docker.service`.
      // 非 root 用户执行 `systemctl stop docker.service` 得到的回应。
      const result = CommandResult(
        stdout: '',
        stderr:
            'Failed to stop docker.service: Interactive authentication '
            'required.',
        exitCode: 1,
      );
      expect(
        remoteActionFailure(result),
        'Failed to stop docker.service: Interactive authentication required.',
      );
    });

    test('a message on stdout alone is returned', () {
      expect(
        remoteActionFailure(
          const CommandResult(
            stdout:
                'Failed to enable unit: Unit file foo.service does not '
                'exist.',
            exitCode: 1,
          ),
        ),
        'Failed to enable unit: Unit file foo.service does not exist.',
      );
    });

    test('stdout and stderr both reach the user', () {
      // `kill` reports the failure on stderr after the shell may have printed
      // something on stdout; neither stream may be dropped.
      // `kill` 的失败写在 stderr，而 stdout 上可能已有输出；两条流都不能丢。
      expect(
        remoteActionFailure(
          const CommandResult(
            stdout: 'Stopping sshd...',
            stderr: 'kill: (1) - Operation not permitted',
            exitCode: 1,
          ),
        ),
        'Stopping sshd...\nkill: (1) - Operation not permitted',
      );
    });

    test('surrounding whitespace is trimmed away', () {
      expect(
        remoteActionFailure(
          const CommandResult(
            stdout: '',
            stderr: '  Unit not found.  \n',
            exitCode: 4,
          ),
        ),
        'Unit not found.',
      );
    });

    test('a null exit status is not a success', () {
      // The server reported no status: the action may have worked, but nothing
      // confirmed it, and inventing that confirmation is the bug being fixed.
      // 服务端没有上报状态：操作可能成功了，但没有任何确认，而凭空补上这个确认
      // 正是本次要修的缺陷。
      expect(
        remoteActionFailure(
          const CommandResult(
            stdout: '',
            stderr: 'Unit not found.',
            exitCode: null,
          ),
        ),
        'Unit not found.',
      );
    });

    test('a null exit status with no output is still a failure', () {
      final failure = remoteActionFailure(
        const CommandResult(stdout: '', stderr: '', exitCode: null),
      );
      expect(failure, isNotNull);
      expect(failure, contains('unknown'));
    });

    test('a non-zero status with no output states the status', () {
      expect(
        remoteActionFailure(const CommandResult(stdout: '', exitCode: 3)),
        'exit status 3',
      );
      expect(
        remoteActionFailure(const CommandResult(stdout: '', exitCode: 127)),
        'exit status 127',
      );
    });
  });

  group('remoteFailureText', () {
    // Used by the container listing, which decides for itself whether a status
    // even counts but must describe the failure the same way.
    // 供容器列表使用：它自己决定某个状态算不算数，但描述失败的方式必须一致。
    test('prefers the remote message over the status', () {
      expect(
        remoteFailureText(
          const CommandResult(
            stdout: '',
            stderr:
                'permission denied while trying to connect to the Docker '
                'daemon socket',
            exitCode: 1,
          ),
        ),
        'permission denied while trying to connect to the Docker daemon socket',
      );
    });

    test('falls back to the status when the remote said nothing', () {
      expect(
        remoteFailureText(const CommandResult(stdout: '   ', exitCode: 1)),
        'exit status 1',
      );
    });
  });
}
