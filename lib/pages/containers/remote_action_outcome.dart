// The one decision shared by the service manager, the process manager and the
// container page: "did this remote action actually do what it was asked?".
// 服务管理、进程管理与容器页共用的唯一判断：「这条远端操作是否真的完成了？」
//
// All three pages used to answer that question by looking at the *text* the
// command printed — `'$out\n$err'`, with the exit status thrown away. That made
// a failed `systemctl stop` and a failed `kill -9` indistinguishable from
// successes, and made a *successful* `docker stop` of a container named
// `error-logger` look like a failure. The answer now comes from the exit status
// alone ([CommandResult.ok]); output is only ever used to explain a failure.
// 三个页面过去都靠**输出文本**回答这个问题——退出状态被丢弃的 `'$out\n$err'`——
// 于是失败的 `systemctl stop`、失败的 `kill -9` 与成功毫无区别，而给名为
// `error-logger` 的容器执行**成功**的 `docker stop` 反倒像失败。现在答案只来自
// 退出状态（[CommandResult.ok]），输出只用于解释失败。
//
// It lives here rather than next to a single caller because no page owns it:
// this file is the only place the rule can be stated once and tested once.
// 它不放在任何单个调用方旁边，因为没有哪个页面拥有它：只有在这里，这条规则才能
// 被写一次、测一次。

import '../../services/command_result.dart';

/// Why [result] must not be reported as a success, or `null` when it may be.
/// [result] 不得被当作成功的原因；可以算成功时返回 `null`。
///
/// A null return is the *only* success signal, and it is derived purely from the
/// exit status: a server that reports none yields a failure, because a success
/// that was never reported is exactly what used to be invented here.
/// 返回 null 是**唯一**的成功信号，且完全由退出状态推导：服务端没有上报状态时
/// 判为失败——「未经上报的成功」正是这里过去凭空捏造出来的东西。
///
/// The returned text is the remote's own words (`Interactive authentication
/// required`, `Unit not found`, `kill: (1) - Operation not permitted`), which
/// callers append after their own localised prefix. It is deliberately not
/// wrapped in prose: only the remote knows *why*, and replacing it with a
/// generic "failed" is how the user ends up unable to fix anything.
/// 返回的文本是远端自己的话（`Interactive authentication required`、
/// `Unit not found`、`kill: (1) - Operation not permitted`），调用方把它接在
/// 自己的本地化前缀之后。刻意不加工成句子：只有远端知道**原因**，把它换成一句
/// 笼统的「失败」正是用户无从下手的原因。
String? remoteActionFailure(CommandResult result) =>
    result.ok ? null : remoteFailureText(result);

/// The text that explains why [result] failed, for a caller that has already
/// decided it did.
/// 说明 [result] 为何失败的文本，供已经判定其失败的调用方使用。
///
/// Split out from [remoteActionFailure] because the container listing asks a
/// different question: it tolerates a *missing* status (the rows it received
/// are still usable) but must explain an explicitly non-zero one. Both ends
/// still describe a failure the same way — the remote's words if it said
/// anything, otherwise the status it reported.
/// 它与 [remoteActionFailure] 分开，是因为容器列表问的是另一个问题：它容忍状态
/// **缺失**（收到的行依然可用），但必须解释明确的非零状态。两者描述失败的方式仍然
/// 一致——远端有话说就用它的话，否则就照实报出状态。
String remoteFailureText(CommandResult result) {
  // `combined` keeps both streams: `systemctl` prints its refusal on stderr,
  // `kill` too, while some Docker errors arrive on stdout.
  // `combined` 同时保留两条流：`systemctl` 的拒绝写在 stderr，`kill` 也是，
  // 而某些 Docker 错误走 stdout。
  final remote = result.combined.trim();
  if (remote.isNotEmpty) return remote;

  // Nothing came back at all. The exit status is then the only fact left, and a
  // missing one is reported as missing rather than guessed at: the exit status
  // is a technical detail, so it is stated in technical terms instead of being
  // pushed through an unrelated translation key.
  // 远端什么都没返回。此时退出状态是唯一剩下的事实，缺失就照实说缺失，不做猜测：
  // 退出状态属于技术细节，直接照实陈述，而不是硬套一个语义不符的翻译键。
  final code = result.exitCode;
  return code == null ? 'exit status unknown' : 'exit status $code';
}
