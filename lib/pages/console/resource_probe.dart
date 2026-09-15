import '../../services/monitoring_service.dart';
import 'probe_command.dart';

/// One round of resource readings, taken together.
/// 一轮资源读取，同批取得。
class ResourceSample {
  /// The raw CPU counters this sample was built from; the next sample needs
  /// them to compute a usage delta.
  /// 本样本所依据的原始 CPU 计数器；下一个样本需要它来计算使用率增量。
  final CpuTimes cpuTimes;

  /// CPU usage in percent since the previous sample, or `null` when there is no
  /// previous one. Usage is a *delta* between two counter snapshots, so the
  /// first sample of a session genuinely has no value — reporting 0 for it
  /// would be inventing a measurement, and reusing the previous session's
  /// number would be worse.
  /// 自上一样本以来的 CPU 使用率（百分比）；没有上一样本时为 `null`。使用率是两次
  /// 计数器快照之间的**增量**，因此一次会话的首个样本本就没有数值——给它填 0 等于
  /// 凭空造出一个测量值，而沿用上一次会话的数值只会更糟。
  final double? cpuUsage;

  /// Memory usage in percent, from `free -m`.
  /// 内存使用率（百分比），来自 `free -m`。
  final double memoryUsage;

  const ResourceSample({
    required this.cpuTimes,
    required this.cpuUsage,
    required this.memoryUsage,
  });

  @override
  String toString() =>
      'ResourceSample(cpu: $cpuUsage, ram: $memoryUsage, $cpuTimes)';
}

/// Reads CPU and memory from a host over one SSH connection.
/// 通过一条 SSH 连接读取主机的 CPU 与内存。
///
/// The two commands are the ones `docs/MAINTENANCE.md` prescribes — `/proc/stat`
/// counters for CPU, `free -m` for memory — and both are read through
/// [probeCommand], so each has a deadline and each failure mode is classed
/// instead of being flattened into a zero.
/// 两条命令即 `docs/MAINTENANCE.md` 规定的来源——CPU 用 `/proc/stat` 计数器，
/// 内存用 `free -m`——且都经由 [probeCommand] 读取，因此各有截止时间，各种失败
/// 方式也被分类，而不是被压成 0。
///
/// Why "no value" must not become 0: `parseProcStat` returns null on output it
/// cannot read, and the page used to return early on that — one silently
/// skipped tick. `parseFree` is worse: it returns `[0, 0, 0]`, which
/// `memoryUsagePercentFromFree` turns into a perfectly plausible `0.0%`, so a
/// failed read looked like an idle machine. Both are raised here instead.
/// 为什么「没有数值」不能变成 0：`parseProcStat` 对读不懂的输出返回 null，页面过去
/// 对此直接 return——静默跳过了一个 tick。`parseFree` 更糟：它返回 `[0, 0, 0]`，
/// 经 `memoryUsagePercentFromFree` 变成完全可信的 `0.0%`，于是失败的读取看起来像
/// 一台空闲的机器。两者都在此改为抛出。
class ResourceProbe {
  ResourceProbe({
    required this.run,
    this.timeout = const Duration(seconds: 10),
  });

  /// The command used for the CPU counters.
  /// 用于读取 CPU 计数器的命令。
  static const String cpuCommand = 'cat /proc/stat | head -1';

  /// The command used for memory.
  /// 用于读取内存的命令。
  static const String memoryCommand = 'free -m';

  /// Executes one command on the monitored host.
  /// 在被监控主机上执行一条命令。
  final ProbeRunner run;

  /// Deadline for each of the two commands.
  /// 两条命令各自的截止时间。
  ///
  /// Deliberately longer than the polling period: a slow link is allowed to
  /// take its time — the poll loop skips ticks that arrive while one is still
  /// running — but a server that has stopped answering must not be waited on
  /// forever.
  /// 有意长于轮询周期：慢链路可以慢慢来（轮询循环会跳过在途期间的 tick），但停止
  /// 应答的服务器不能被无限等待。
  final Duration timeout;

  /// Takes one sample. [previous] is the counter snapshot of the previous
  /// sample, or null for the first one.
  /// 取一个样本。[previous] 为上一次的计数器快照，首个样本传 null。
  ///
  /// Throws [ProbeException] when either command fails, times out, or returns
  /// something that is not the expected counter — never returns a made-up 0.
  /// 任一命令失败、超时或返回的不是预期计数器时抛出 [ProbeException]，
  /// 绝不返回编造的 0。
  Future<ResourceSample> read({CpuTimes? previous}) async {
    final stat = await probeCommand(run, cpuCommand, timeout: timeout);
    final current = MonitoringService.parseProcStat(stat.stdout);
    if (current == null) {
      throw ProbeException(
        ProbeFailure.failed,
        '$cpuCommand: ${describeOutput(stat.stdout)}',
      );
    }

    final free = await probeCommand(run, memoryCommand, timeout: timeout);
    final memory = MonitoringService.parseFree(free.stdout);
    // `isEmpty` first: a `free` with no memory row now parses to an empty list
    // rather than to the swap row's numbers or to a believable all-zero row.
    // 先判 `isEmpty`：没有内存行的 `free` 现在解析为空列表，而不再是交换行的数字，
    // 也不再是一行看起来可信的全零。
    if (memory.isEmpty || memory[0] <= 0) {
      throw ProbeException(
        ProbeFailure.failed,
        '$memoryCommand: ${describeOutput(free.stdout)}',
      );
    }

    return ResourceSample(
      cpuTimes: current,
      cpuUsage: previous == null
          ? null
          : MonitoringService.cpuUsageBetween(previous, current),
      // Non-null by construction: the guard above already rejected an empty or
      // non-positive parse of this same output.
      // 由构造保证非空：上面的守卫已经拒绝对同一份输出的空解析与非正解析。
      memoryUsage:
          MonitoringService.memoryUsagePercentFromFree(free.stdout) ?? 0,
    );
  }
}
