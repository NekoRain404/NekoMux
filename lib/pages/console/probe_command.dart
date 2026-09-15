import 'dart:async';

import '../../services/command_result.dart';

/// Runs one non-interactive command and reports its output and exit status.
/// 运行一条非交互式命令并返回其输出与退出状态。
typedef ProbeRunner = Future<CommandResult> Function(String command);

/// Why a probe command did not produce a usable answer.
/// 探测命令为何没有给出可用结果。
enum ProbeFailure {
  /// The command did not finish inside its deadline, so whatever it is still
  /// doing on the server is no longer waited for.
  /// 命令未在截止时间内完成；它仍在服务器上做什么，已经不再等待。
  timedOut,

  /// The remote host reported a non-zero exit status.
  /// 远端上报了非零退出状态。
  rejected,

  /// The command could not be run at all, or it finished without the data
  /// that was expected — an error string where a counter should be, an empty
  /// read, output from a command that does not exist.
  /// 命令根本无法运行，或虽已结束却没有给出预期的数据——本应是计数器的地方
  /// 是错误串、读到了空内容、或命令并不存在。
  failed,
}

/// A probe command that could not be used, with the reason kept as data.
/// 一条无法使用的探测命令，原因以数据形式保留。
///
/// The text a user reads is chosen by the caller / the i18n table; this type
/// carries only the failure class and a technical detail (the command, the exit
/// status, what came back). Keeping prose out of the polling layer is what
/// makes a failed poll testable without a translation table — and what stops a
/// raw parser exception from being the only record of a failure.
/// 用户读到的文案由调用方／i18n 表决定；本类型只承载失败类别与技术细节（命令、
/// 退出状态、实际返回内容）。正是「轮询层不含文案」这一点，使失败无需翻译表即可
/// 测试，也避免「解析器抛出的异常」成为失败的唯一记录。
class ProbeException implements Exception {
  /// What went wrong.
  /// 出了什么问题。
  final ProbeFailure kind;

  /// Technical detail for the caller's message: the command, an exit status, a
  /// short rendering of the output. Never a sentence.
  /// 供调用方组装的细节：命令、退出状态、输出的简短呈现。不含句子。
  final String detail;

  const ProbeException(this.kind, this.detail);

  @override
  String toString() => '${kind.name}: $detail';
}

/// Runs [command] through [run] with a deadline and rejects an unusable answer.
/// 在截止时间内通过 [run] 运行 [command]，并拒绝不可用的结果。
///
/// Every way this can fail is turned into a [ProbeException], so a caller never
/// has to guess why nothing came back, and a `catch (_) {}` in the polling loop
/// cannot hide a dead link.
/// 所有失败路径都归一为 [ProbeException]，调用方无需猜测为何没有结果，轮询循环里
/// 的 `catch (_) {}` 也就无法掩盖掉断掉的链路。
Future<CommandResult> probeCommand(
  ProbeRunner run,
  String command, {
  required Duration timeout,
}) async {
  final CommandResult result;
  try {
    result = await run(command).timeout(timeout);
  } on TimeoutException {
    throw ProbeException(ProbeFailure.timedOut, command);
  } catch (e) {
    throw ProbeException(ProbeFailure.failed, '$command: $e');
  }

  // A *reported* non-zero status is a definite failure. A missing status
  // (`exitCode == null`) is *unknown*, not success — see [CommandResult.ok] —
  // and for these read-only probes the caller's parse is the stronger check,
  // so an unreported status is allowed through to it. This is the escape hatch
  // that getter's documentation points at; a reported failure still stops here.
  // 服务端**明确上报**的非零状态即为确定失败。状态缺失（`exitCode == null`）
  // 表示「未知」而非成功（见 [CommandResult.ok]）；对这类只读探针，调用方的解析
  // 是更强的校验，因此未上报的状态会继续交由解析判定——这正是该 getter 文档所指
  // 的例外。已上报的失败仍然在此终止。
  if (result.exitCode != null && !result.ok) {
    throw ProbeException(
      ProbeFailure.rejected,
      '$command: exit ${result.exitCode}',
    );
  }
  return result;
}

/// Renders [output] as a short single-line detail for a failure message.
/// 将 [output] 渲染为失败信息中简短的单行细节。
///
/// Bounded on purpose: a failure detail ends up inside a snackbar and on a
/// line of the overlay, and a probe that returned half a megabyte of garbage
/// must not be able to push the user's actual controls off the screen.
/// 有意限制长度：失败细节会进入浮层提示与覆盖层的一行文字，一个返回半兆垃圾的
/// 探针不该把用户真正要操作的控件挤出屏幕。
String describeOutput(String output, {int maxLength = 60}) {
  final flat = output.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (flat.isEmpty) return '<empty>';
  if (flat.length <= maxLength) return flat;
  return '${flat.substring(0, maxLength)}…';
}
