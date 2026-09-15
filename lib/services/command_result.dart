/// Outcome of a single non-interactive remote command.
/// 单条非交互式远程命令的执行结果。
///
/// This type carries *data*, never prose: [ok] is derived from the remote exit
/// status, so a caller never has to guess success from the shape of the output
/// (a container named `error-logger` used to make a successful `docker stop`
/// look like a failure, because the old check was `output.contains('error')`).
/// The human-readable message belongs to the caller / the i18n table.
/// 本类型只承载数据，不承载文案：[ok] 由远端退出状态推导，调用方无需再凭输出
/// 的形态猜测成败（以前 `output.contains('error')` 会把一个名为 `error-logger`
/// 的容器导致的成功 `docker stop` 误判为失败）。面向用户的文案属于调用方／
/// i18n 表。
class CommandResult {
  /// Everything the command wrote to stdout, decoded as UTF-8.
  /// 命令写入 stdout 的全部内容，按 UTF-8 解码。
  final String stdout;

  /// Everything the command wrote to stderr, decoded as UTF-8.
  /// 命令写入 stderr 的全部内容，按 UTF-8 解码。
  final String stderr;

  /// The exit status reported by the remote host, or `null` when there is none.
  /// 远端上报的退出状态；没有时（或无法获知时）为 `null`。
  ///
  /// `dartssh2` leaves this null when the server does not report an exit
  /// status, when the process has not exited yet, and when the remote process
  /// was terminated by a signal (`ssh_session.dart`: "May be null if the
  /// process has not yet exited, the remote process has been terminated due to
  /// a signal, or the remote ssh implementation does not report exit codes").
  /// Null is *unknown*, not *success* — see [ok].
  /// `dartssh2` 在服务端不上报退出状态、进程尚未退出、或远端进程被信号终止时都会
  /// 保留 null（见 `ssh_session.dart` 的注释）。null 表示「未知」而非「成功」，
  /// 详见 [ok]。
  final int? exitCode;

  const CommandResult({
    required this.stdout,
    this.stderr = '',
    this.exitCode,
  });

  /// Whether the remote command reported success.
  /// 远端命令是否上报了成功。
  ///
  /// True only for an exit status of exactly `0`. A null [exitCode] — an older
  /// or unusual server that reports none — is deliberately **not** success:
  /// silently reporting a failed `systemctl stop` as "succeeded" is the bug
  /// this exists to prevent, and guessing from the output cannot be made
  /// reliable. Callers that must tolerate a missing status can compare
  /// [exitCode] to null themselves.
  /// 仅当退出状态恰为 `0` 时为真。刻意**不**把 null（服务端不上报退出状态）
  /// 当作成功：把失败的 `systemctl stop` 报成「成功」正是本类型要消除的缺陷，
  /// 而凭输出猜测并不可靠。确实需要容忍状态缺失的调用方可自行比较 [exitCode]
  /// 是否为 null。
  bool get ok => exitCode == 0;

  /// `stderr` and `stdout` in one string, laid out the way `executeCommand`
  /// has always returned them.
  /// 合并后的 `stdout` 与 `stderr`，布局与 `executeCommand` 一贯的返回一致。
  ///
  /// The rules are frozen, because `executeCommand` is defined as this getter
  /// and its callers' output must not change:
  /// 规则已冻结：`executeCommand` 即以本 getter 定义，其调用方看到的输出不得变化：
  ///
  /// * stderr empty → stdout, unchanged (no trailing newline added)
  /// * stdout empty → stderr, unchanged (no leading newline added)
  /// * both non-empty → `stdout`, one `\n`, `stderr`
  /// * both empty → the empty string
  ///
  /// stderr 为空 → 原样返回 stdout（不追加换行）；
  /// stdout 为空 → 原样返回 stderr（不添加前导换行）；
  /// 两者均非空 → `stdout` + 一个 `\n` + `stderr`；两者均为空 → 空字符串。
  String get combined {
    if (stderr.isEmpty) return stdout;
    if (stdout.isEmpty) return stderr;
    return '$stdout\n$stderr';
  }

  @override
  String toString() =>
      'CommandResult(exitCode: $exitCode, '
      'stdout: ${stdout.length} chars, stderr: ${stderr.length} chars)';
}
