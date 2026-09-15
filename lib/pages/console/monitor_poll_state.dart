/// Identity of one polling tick.
/// 一次轮询 tick 的身份标识。
///
/// The generation it carries is what makes an answer belong to the connection
/// that asked for it: a ticket from before a retry must not be able to commit
/// its sample, and must not be able to release the slot the new generation is
/// using.
/// 它携带的世代号决定了结果属于哪条连接：重试之前发出的票据不得提交自己的样本，
/// 也不得释放新世代正在使用的槽位。
class PollTicket {
  /// The polling generation this ticket belongs to.
  /// 本票据所属的轮询世代。
  final int generation;

  const PollTicket(this.generation);

  @override
  String toString() => 'PollTicket($generation)';
}

/// Scheduling state of one resource-polling loop.
/// 一个资源轮询循环的调度状态。
///
/// Why this exists / 存在的理由:
/// The loop used to start a tick every three seconds with nothing preventing a
/// tick from starting while the previous one was still running. Two probes
/// (`/proc/stat`, then `free -m`) cost two exec channels each, so on a link
/// slower than the period the ticks piled up: samples landed in completion
/// order, `cpuUsageBetween` occasionally saw a stale or zero delta (the 0 % dip
/// in the CPU chart), and a server that stopped answering accumulated two
/// never-completing channels every three seconds against sshd's `MaxSessions`.
/// 过去每三秒就发起一个 tick，且没有任何机制阻止上一个 tick 尚未结束时再开一个。
/// 每次探测（先 `/proc/stat` 再 `free -m`）要两条 exec 通道，因此在比周期更慢的
/// 链路上 tick 会堆叠：样本按完成顺序落地，`cpuUsageBetween` 偶尔看到陈旧或零的
/// 增量（CPU 图上的 0% 凹陷），而停止应答的服务器每三秒就积下两条永不完成的通道，
/// 直冲 sshd 的 `MaxSessions`。
///
/// Two rules implement the fix / 两条规则实现该修复:
/// 1. At most one tick in flight ([begin] returns null while one runs), so a
///    tick always compares against the counters of the tick before it.
///    同时在途的 tick 至多一个（有 tick 在跑时 [begin] 返回 null），因此每个 tick
///    比较的总是前一个 tick 的计数器。
/// 2. A generation per session ([restart]): a tick that was in flight when the
///    connection was replaced or the page was disposed is dropped whole instead
///    of applying a sample from a connection nobody owns any more.
///    每次会话一个世代（[restart]）：连接被替换或页面销毁时仍在途的 tick 被整体
///    丢弃，而不会把一条已无人持有的连接的样本写进界面。
class MonitorPollState {
  MonitorPollState({this.maxConsecutiveFailures = 2})
    : assert(maxConsecutiveFailures > 0);

  /// How many consecutive failed ticks mean the monitor is dead rather than
  /// momentarily unlucky.
  /// 连续多少个 tick 失败即认定监控已死，而非一时不走运。
  final int maxConsecutiveFailures;

  int _generation = 0;
  bool _inFlight = false;
  int _consecutiveFailures = 0;

  /// The generation a new tick would belong to.
  /// 新 tick 将属于的世代。
  int get generation => _generation;

  /// Whether a tick is currently running.
  /// 当前是否有 tick 在运行。
  bool get isInFlight => _inFlight;

  /// Failed ticks since the last successful one.
  /// 自上次成功以来的失败 tick 数。
  int get consecutiveFailures => _consecutiveFailures;

  /// Whether [ticket] still belongs to the live generation.
  /// [ticket] 是否仍属于当前世代。
  bool isCurrent(PollTicket ticket) => ticket.generation == _generation;

  /// Claims the single in-flight slot, or returns null when one is taken.
  /// 占用唯一的在途槽位；已被占用时返回 null。
  PollTicket? begin() {
    if (_inFlight) return null;
    _inFlight = true;
    return PollTicket(_generation);
  }

  /// Starts a new generation, abandoning whatever was in flight.
  /// 开启新世代，并放弃仍在途的一切。
  ///
  /// Called when the connection is replaced or the page goes away. The
  /// abandoned tick keeps running — an SSH command cannot be recalled — but
  /// [isCurrent] turns false for it, so its result and its failure both fall
  /// on the floor instead of reviving a dead session's numbers.
  /// 在连接被替换或页面销毁时调用。被放弃的 tick 仍会跑完——SSH 命令无法召回——
  /// 但 [isCurrent] 对它变为 false，因此它的结果与失败都会被丢弃，不会把已死会话的
  /// 数字复活到界面上。
  PollTicket restart() {
    _generation++;
    _inFlight = false;
    _consecutiveFailures = 0;
    return PollTicket(_generation);
  }

  /// Releases the slot after a tick that produced a sample.
  /// 在一个成功产出样本的 tick 之后释放槽位。
  ///
  /// Returns false when [ticket] belongs to a superseded generation, in which
  /// case nothing is touched — the new generation owns the slot now.
  /// [ticket] 属于已被取代的世代时返回 false 且不触碰任何状态：此刻槽位归新世代所有。
  bool finishSuccess(PollTicket ticket) {
    if (!isCurrent(ticket)) return false;
    _inFlight = false;
    _consecutiveFailures = 0;
    return true;
  }

  /// Releases the slot after a failed tick and reports whether the loop must
  /// give up.
  /// 在一个失败的 tick 之后释放槽位，并报告循环是否必须放弃。
  ///
  /// Giving up is what turns a silently frozen chart into an overlay that says
  /// the monitor is unavailable and offers a retry.
  /// 之所以要「放弃」，是为了把默默冻结的图表变成一块说明监控不可用并提供重试的覆盖层。
  bool finishFailure(PollTicket ticket) {
    if (!isCurrent(ticket)) return false;
    _inFlight = false;
    _consecutiveFailures++;
    return _consecutiveFailures >= maxConsecutiveFailures;
  }

  @override
  String toString() =>
      'MonitorPollState(generation: $_generation, inFlight: $_inFlight, '
      'failures: $_consecutiveFailures)';
}
