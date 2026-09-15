import 'package:flutter_test/flutter_test.dart';
import 'package:neko_mux/services/command_result.dart';

/// Tests for [CommandResult] — the data a remote command reports back.
///
/// Two properties matter and both are load-bearing for callers that judge a
/// remote action by its outcome:
///
/// * `ok` must be false when the exit code is *unknown*. Some servers do not
///   report one, and treating "unknown" as success is exactly the bug this
///   type exists to fix (a failed `systemctl stop` still reporting "succeeded").
/// * `combined` must reproduce, byte for byte, what `executeCommand` has always
///   returned, because six pages still call it and their output is frozen.
///   `executeCommand` is now `(await runCommand(cmd)).combined`, so these four
///   cases are the regression guard for that frozen behaviour.
void main() {
  group('CommandResult.ok', () {
    test('is true for exit code 0', () {
      expect(const CommandResult(stdout: 'x', exitCode: 0).ok, isTrue);
    });

    test('is true for exit code 0 even with empty output', () {
      expect(const CommandResult(stdout: '', exitCode: 0).ok, isTrue);
    });

    test('is false when the server reports no exit code', () {
      expect(const CommandResult(stdout: 'x', exitCode: null).ok, isFalse);
    });

    test('is false when there is no exit code and no output either', () {
      const result = CommandResult(stdout: '', stderr: '', exitCode: null);
      expect(result.ok, isFalse);
    });

    test('is false for a non-zero exit code', () {
      expect(const CommandResult(stdout: '', exitCode: 1).ok, isFalse);
      expect(const CommandResult(stdout: '', exitCode: 255).ok, isFalse);
    });

    test('is false for a non-zero exit code even when stdout looks fine', () {
      const result = CommandResult(
        stdout: 'Stopping docker.service...',
        exitCode: 1,
      );
      expect(result.ok, isFalse);
      expect(result.combined, 'Stopping docker.service...');
    });
  });

  group('CommandResult.combined', () {
    // The four combinations of empty / non-empty stdout and stderr. Each one is
    // pinned to the exact string `executeCommand` returns today.
    test('both empty -> empty string', () {
      const result = CommandResult(stdout: '', stderr: '', exitCode: 0);
      expect(result.combined, '');
    });

    test('stdout only -> stdout, with no trailing newline', () {
      const result = CommandResult(stdout: 'hi\n', stderr: '', exitCode: 0);
      expect(result.combined, 'hi\n');
    });

    test('stderr only -> stderr, with no leading separator', () {
      const result = CommandResult(
        stdout: '',
        stderr: 'Failed to stop docker.service\n',
        exitCode: 1,
      );
      expect(result.combined, 'Failed to stop docker.service\n');
    });

    test('both -> stdout, one more newline, then stderr', () {
      const result = CommandResult(
        stdout: 'out\n',
        stderr: 'err\n',
        exitCode: 1,
      );
      // The separator is added unconditionally, so the trailing newline of a
      // typical tool's stdout is kept and the two streams end up separated by a
      // blank line. That looks redundant, but it is what `executeCommand`
      // returns today and its output is frozen — "tidying" it here would change
      // what six pages display.
      expect(result.combined, 'out\n\nerr\n');
    });

    test('the separator is exactly one newline, not the join of the pieces',
        () {
      const result = CommandResult(stdout: 'a', stderr: 'b', exitCode: 2);
      expect(result.combined, 'a\nb');
      expect(result.combined.split('\n').length, 2);
    });
  });
}
