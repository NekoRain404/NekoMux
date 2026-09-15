import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/i18n/strings.dart';
import '../models/host.dart';
import '../providers/providers.dart';
import '../providers/ssh_provider.dart';
import '../services/host_key_trust.dart';
import '../services/monitoring_service.dart';
import '../services/ssh_service.dart';
import '../widgets/host_key_prompt.dart';
import 'console/console_bars.dart';
import 'console/console_function_grid.dart';
import 'console/host_identity.dart';
import 'console/monitor_poll_state.dart';
import 'console/monitor_samples.dart';
import 'console/probe_command.dart';
import 'console/resource_monitor_card.dart';
import 'console/resource_probe.dart';
import 'console/ssh_error_text.dart';

/// Host detail console with real-time resource monitoring.
/// 主机详情控制台，带实时资源监控。
///
/// The page owns the session: it opens the SSH connection (host key verified by
/// [buildHostKeyVerifier]), drives the poll loop, and hands state to
/// presentation-only widgets. The rules that decide *when* a sample may be
/// committed and *what* a window of samples means live in `console/`, where
/// they can be tested without a server.
/// 本页持有会话：建立 SSH 连接（主机密钥由 [buildHostKeyVerifier] 校验）、驱动轮询
/// 循环，并把状态交给纯展示的组件。至于「一个样本何时可以提交」「一窗样本意味着
/// 什么」这类规则，放在 `console/` 下，无需服务器即可测试。
class HostConsolePage extends ConsumerStatefulWidget {
  /// The host this console monitors.
  /// 本控制台监控的主机。
  final Host host;

  const HostConsolePage({super.key, required this.host});

  @override
  ConsumerState<HostConsolePage> createState() => _HostConsolePageState();
}

class _HostConsolePageState extends ConsumerState<HostConsolePage>
    with SingleTickerProviderStateMixin {
  /// How often the resource probes run.
  /// 资源探测的运行频率。
  ///
  /// One constant for three things that must not disagree: the timer period,
  /// the chart's time axis, and the "Live · 3s" badge (whose text carries the
  /// interval in every translation).
  /// 同一个常量服务于三件不能互相矛盾的事：定时器周期、图表时间轴，以及
  /// 「实时 · 3s」徽标（其译文自带该间隔）。
  static const Duration _pollInterval = Duration(seconds: 3);

  /// Deadline for one probe command.
  /// 单条探测命令的截止时间。
  ///
  /// Longer than [_pollInterval] on purpose: a slow link is allowed to finish,
  /// and the poll loop simply skips the ticks that arrive meanwhile. What this
  /// prevents is a server that has stopped answering being waited on forever.
  /// 有意长于 [_pollInterval]：慢链路可以跑完，轮询循环只是跳过期间到来的 tick。
  /// 它真正要防止的，是对一台已停止应答的服务器无限期等待。
  static const Duration _commandTimeout = Duration(seconds: 10);

  /// Consecutive failed ticks after which monitoring is called dead.
  /// 连续多少个 tick 失败即认定监控已死。
  ///
  /// At two, a link that is merely slow (each tick taking up to
  /// [_commandTimeout]) has roughly twenty seconds to recover before the page
  /// tells the user monitoring stopped — long enough not to cry wolf, short
  /// enough that a frozen chart is explained before the user concludes the app
  /// hung.
  /// 取二意味着：只是慢（每个 tick 最多花 [_commandTimeout]）的链路大约有二十秒
  /// 的恢复时间，之后页面才会告知监控已停止——既不至于草木皆兵，也不至于让用户在
  /// 断定应用卡死之前一直得不到解释。
  static const int _failureLimit = 2;

  /// CPU/RAM history handed to the chart.
  /// 交给图表的 CPU/RAM 历史。
  final MonitorSamples _samples = MonitorSamples();

  /// Which tick may run, which tick may still commit its result, and how many
  /// failures have piled up.
  /// 哪个 tick 可以运行、哪个 tick 仍可提交结果，以及已累积多少失败。
  final MonitorPollState _poll = MonitorPollState(
    maxConsecutiveFailures: _failureLimit,
  );

  late final AnimationController _glowController;

  SshConnection? _monitorConn;
  ResourceProbe? _probe;
  Timer? _pollTimer;

  /// The tick currently running, so a manual refresh waits for it instead of
  /// starting a second one or reporting a refresh that never happened.
  /// 当前运行中的 tick，好让手动刷新等待它，而不是再起一个、或谎报刷新成功。
  Future<bool>? _tickInFlight;

  /// The newest connection attempt.
  /// 最新的连接尝试。
  ///
  /// A retry can start while the previous attempt is still waiting on the
  /// credential store or the TCP handshake. Without this, that abandoned
  /// attempt resumes afterwards and tears down the session its successor is
  /// building — it would dispose the live connection through [_stopMonitoring]
  /// and report "cannot connect" about a connection that never got its chance.
  /// 上一次尝试仍在等待凭据库或 TCP 握手时，重试就可能开始。若没有这个编号，被放弃
  /// 的尝试随后恢复执行，就会拆掉它的继任者正在建立的会话——通过 [_stopMonitoring]
  /// 释放尚在使用的连接，并对一次还没来得及尝试的连接报告「无法连接」。
  int _connectAttempt = 0;

  bool _isLive = false;
  bool _connecting = false;
  String? _monitorError;
  HostIdentity _identity = HostIdentity.unknown;
  CpuTimes? _lastCpuTimes;

  @override
  void initState() {
    super.initState();
    _glowController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat(reverse: true);

    WidgetsBinding.instance.addPostFrameCallback((_) => _initMonitoring());
  }

  @override
  void dispose() {
    // Invalidate a tick that is still in flight *before* the connection it is
    // using goes away: an SSH command cannot be recalled, but its answer can be
    // refused entry, and this is what refuses it.
    // 在它所使用的连接消失**之前**作废仍在途的 tick：SSH 命令无法召回，但它的应答
    // 可以不予接纳——此处正是不予接纳之处。
    _poll.restart();
    _connectAttempt++;
    _pollTimer?.cancel();
    _pollTimer = null;
    _teardownMonitor();
    _glowController.dispose();
    super.dispose();
  }

  // ===========================================================================
  // Connection
  // ===========================================================================

  /// Whether [attempt] is still the newest connection attempt.
  /// [attempt] 是否仍是最新的连接尝试。
  bool _isCurrentAttempt(int attempt) => attempt == _connectAttempt;

  Future<void> _initMonitoring() async {
    if (_connecting) return;
    _connecting = true;

    final host = widget.host;
    final attempt = ++_connectAttempt;
    try {
      final creds = await ref.read(credentialListProvider.future);
      if (!_isCurrentAttempt(attempt)) return;
      final cred = creds.where((c) => c.id == host.credentialId).firstOrNull;

      if (cred == null) {
        _stopMonitoring(t('cred_not_found_fallback'));
        return;
      }

      // The monitoring connection is a real SSH session, so it has to verify the
      // host key like every other one: `dartssh2` accepts any key when no
      // callback is passed, which is exactly what a machine-in-the-middle needs.
      // 监控连接是真实的 SSH 会话，必须和其它连接一样校验主机密钥：
      // 不传回调时 `dartssh2` 会接受任意密钥，这正是中间人想要的。
      final db = await ref.read(databaseProvider.future);
      if (!_isCurrentAttempt(attempt)) return;
      final conn = SshConnection(
        host: host,
        credential: cred,
        // Settings → connect timeout, honoured in full here — deliberately NOT
        // clamped the way the home page's background probe clamps it. The two
        // are opposites: the probe runs against every host, on every round, with
        // nobody watching, whereas this page opens exactly one session that the
        // user asked for by tapping the host. Clamping here would re-create the
        // very defect being fixed — someone on a slow link sets 30s and is still
        // cut off at 4 — and the cost of honouring it is paid once rather than
        // per tick, because a connect happens only on open, on retry and on
        // pull-to-refresh, all user-initiated; the poll timer never starts one.
        // Once connected, the poll loop is bounded by its own per-command
        // deadline ([_commandTimeout]), which is a separate budget and stays
        // exactly as it was.
        // 设置 → 连接超时，在这里被完整遵循——刻意**不**像主页后台探测那样钳制。两者
        // 恰好相反：探测每轮对每台主机执行且无人注视，而本页只打开用户点击主机所请求
        // 的那一条会话。在此钳制会重新造出正在修复的缺陷——慢链路上的用户设了 30 秒，
        // 却依然在 4 秒被切断——而遵循它的代价只付一次，不按 tick 重复：连接只发生在
        // 打开、重试与下拉刷新时，全部由用户发起，轮询定时器从不会触发它。连上之后，
        // 轮询循环由其各自的单命令截止时间（[_commandTimeout]）约束，那是另一笔预算，
        // 保持原样。
        connectTimeout: ref.read(connectTimeoutProvider),
        onHostKeyVerify: buildHostKeyVerifier(
          db: db,
          address: host.ipAddress,
          port: host.port,
          onPrompt: (fingerprint, verdict) async {
            // Runs after several awaits, so the page may already be gone; with
            // nobody left to ask, refusing is the only safe answer.
            // 该回调在多次 await 之后执行，页面可能已经销毁；此时无人可问，拒绝是唯一安全答案。
            if (!mounted) return false;
            return showHostKeyPrompt(
              context,
              fingerprint: fingerprint,
              verdict: verdict,
            );
          },
        ),
      );
      _monitorConn = conn;
      await conn.connect();
      // A retry that started during the handshake owns the state now, and it
      // has already disposed this connection.
      // 握手中途开始的重试现在拥有状态，并且已经释放了这条连接。
      if (!_isCurrentAttempt(attempt)) return;

      if (conn.state != SshConnectionState.connected) {
        // The reason, in the user's own language. The line used to show
        // `lastError`, which was a Chinese sentence whatever language the app
        // was set to; the connection now reports a code
        // (`SshConnection.failure`) and the sentence is chosen here. The slot is
        // for the *reason* — the overlay already prints
        // `monitor_unavailable_hint` underneath it, which is where "resource
        // monitoring unavailable" belongs.
        // 用用户自己的语言给出原因。此处过去展示 `lastError`，无论应用设成哪种语言它都是
        // 一句中文；现在连接上报编码（`SshConnection.failure`），句子在这里选择。这个位置
        // 属于**原因**——浮层已经在其下方打印 `monitor_unavailable_hint`，「资源监控不可用」
        // 的信息属于那里。
        _stopMonitoring(sshConnectErrorText(conn));
        return;
      }

      await _fetchOsInfo(conn);
      if (!mounted || !_isCurrentAttempt(attempt)) return;

      setState(() {
        _isLive = true;
        _connecting = false;
        _monitorError = null;
      });
      await ref.read(hostListProvider.notifier).setOnline(host.id, true);
      if (!_isCurrentAttempt(attempt)) return;

      _startPolling(conn);
    } catch (e) {
      if (!_isCurrentAttempt(attempt)) return;
      _stopMonitoring('${t('cannot_connect')}: $e');
    }
  }

  /// Reads the host name and OS banner shown in the header.
  /// 读取页头显示的主机名与系统信息。
  ///
  /// A failure here no longer disappears into an empty `catch`: the identity
  /// fetch either returns something to show, or raises, and the reason is put
  /// in front of the user. Previously a short or failed `uname -a` threw a
  /// `RangeError` inside the parse, was swallowed, and left the header showing
  /// the address with no hint that anything had gone wrong.
  /// 这里的失败不再消失于空 `catch`：身份读取要么返回可展示的内容，要么抛出，而
  /// 原因会呈现在用户面前。过去过短或失败的 `uname -a` 会在解析里抛 `RangeError`，
  /// 被吞掉后页头只剩地址，且毫无出错的提示。
  Future<void> _fetchOsInfo(SshConnection conn) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final identity = await fetchHostIdentity(
        conn.runCommand,
        timeout: _commandTimeout,
      );
      if (!mounted) return;
      setState(() => _identity = identity);
    } on ProbeException catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(content: Text(_probeMessage(e))));
    }
  }

  /// Runs the timer and starts polling [conn] for resources.
  /// 启动定时器，并开始为 [conn] 轮询资源。
  void _startPolling(SshConnection conn) {
    _pollTimer?.cancel();
    _probe = ResourceProbe(run: conn.runCommand, timeout: _commandTimeout);
    // A new generation: nothing the previous session still has in flight may
    // commit a sample into this one.
    // 新世代：上一次会话仍在途的 tick 不得把样本提交进本次会话。
    _poll.restart();
    unawaited(_pollOnce());
    _pollTimer = Timer.periodic(_pollInterval, (_) => unawaited(_pollOnce()));
  }

  /// Drops the monitoring connection and the probe bound to it.
  /// 丢弃监控连接以及绑定其上的探针。
  ///
  /// Disposing the connection is also how an abandoned probe command is cut
  /// short: its channel dies with the client, so a wedged server cannot leave
  /// a never-completing exec behind for the next attempt to inherit.
  /// 释放连接同时也是切断被放弃的探测命令的方式：其通道随客户端一同消亡，卡死的
  /// 服务器因此无法留下一条永不完成的 exec 给下一次尝试继承。
  void _teardownMonitor() {
    _probe = null;
    final conn = _monitorConn;
    _monitorConn = null;
    conn?.dispose();
  }

  // ===========================================================================
  // Polling
  // ===========================================================================

  /// Runs one polling tick.
  /// 运行一次轮询 tick。
  ///
  /// Returns true only when a fresh sample reached the chart. At most one tick
  /// is ever in flight: a tick that arrives while another is still running is
  /// dropped rather than queued, which is what keeps `previous` in
  /// [ResourceProbe.read] the sample immediately before the new one — the
  /// overlapping ticks that used to land in completion order and produce a
  /// stale or zero CPU delta are gone.
  /// 只有新样本真正进入图表时才返回 true。在途的 tick 至多一个：在另一个 tick 仍在
  /// 运行时到来的 tick 会被丢弃而非排队，这保证 [ResourceProbe.read] 的 `previous`
  /// 永远是紧邻的上一个样本——过去那些按完成顺序落地、导致 CPU 增量为陈旧值或零的
  /// 重叠 tick 已不存在。
  Future<bool> _pollOnce() async {
    final probe = _probe;
    if (probe == null || !_isLive) return false;

    final ticket = _poll.begin();
    if (ticket == null) return false;

    final tick = _runTick(ticket, probe);
    _tickInFlight = tick;
    try {
      return await tick;
    } finally {
      _tickInFlight = null;
    }
  }

  /// The body of a tick: two probe commands, then one chart sample.
  /// 一次 tick 的主体：两条探测命令，然后一个图表样本。
  Future<bool> _runTick(PollTicket ticket, ResourceProbe probe) async {
    try {
      final sample = await probe.read(previous: _lastCpuTimes);

      // A retry or a disposal happened while the commands were running. These
      // numbers belong to a connection nobody owns any more.
      // 命令运行期间发生了重试或销毁。这些数字属于一条已无人持有的连接。
      if (!_poll.isCurrent(ticket)) return false;

      _lastCpuTimes = sample.cpuTimes;
      if (mounted) {
        setState(() {
          _samples.commit(
            // No previous counter snapshot means no delta yet: the first CPU
            // point of a session is not measurable, so it stays at 0 instead of
            // inheriting the number a previous session left behind.
            // 没有上一份计数器快照就没有增量：本次会话的首个 CPU 点无法测量，因此
            // 保持 0，而不是沿用上一次会话遗留的数值。
            cpu: sample.cpuUsage ?? 0,
            ram: sample.memoryUsage,
          );
        });
      }
      _poll.finishSuccess(ticket);
      return true;
    } on ProbeException catch (e) {
      return _failTick(ticket, e);
    } catch (e) {
      return _failTick(ticket, ProbeException(ProbeFailure.failed, '$e'));
    }
  }

  /// Records a failed tick and stops monitoring once they pile up.
  /// 记录一次失败的 tick，并在失败累积到阈值时停止监控。
  ///
  /// A single lost tick is not news — it is re-tried on the next period, and the
  /// chart simply keeps the last real sample. Only the threshold turns it into
  /// something the user must be told about.
  /// 偶发的一次 tick 丢失不算新闻——下一个周期会重试，图表保留最后一个真实样本。
  /// 只有达到阈值，才必须告知用户。
  bool _failTick(PollTicket ticket, ProbeException e) {
    // A stale ticket's failure belongs to a connection that was already
    // replaced; letting it count would stop a session that is working.
    // 过期票据的失败属于已被替换的连接；让它计数会误停一个正常工作的会话。
    if (!_poll.finishFailure(ticket)) return false;
    _stopMonitoring(_probeMessage(e));
    return false;
  }

  /// Puts the page into its "no monitoring" state, for any reason.
  /// 无论原因如何，把页面置入「无监控」状态。
  ///
  /// One path for both "could not connect" and "stopped answering": both leave
  /// the user with no live data and the same two things to do about it, and
  /// keeping them apart is how the second one used to end up as a silently
  /// frozen chart.
  /// 「连不上」与「不再应答」共用一条路径：两者都让用户没有实时数据，也都给出同样
  /// 两条出路；把它们分开处理，正是后者过去变成图表静默冻结的原因。
  void _stopMonitoring(String message) {
    _pollTimer?.cancel();
    _pollTimer = null;
    _teardownMonitor();
    if (!mounted) return;

    ref.read(hostListProvider.notifier).setOnline(widget.host.id, false);
    setState(() {
      _isLive = false;
      _connecting = false;
      _monitorError = message;
      _lastCpuTimes = null;
      // No live data is being shown, so nothing may stay on screen looking like
      // it is.
      // 没有实时数据在显示，因此屏幕上不得留下像是实时数据的东西。
      _samples.clear();
    });
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  /// Turns a probe failure into the text the user reads.
  /// 把探测失败转成用户读到的文案。
  String _probeMessage(ProbeException e) {
    if (e.kind == ProbeFailure.timedOut) return t('conn_timeout');
    return t('load_failed_msg').replaceAll('{0}', e.detail);
  }

  // ===========================================================================
  // Refresh / retry
  // ===========================================================================

  /// Re-polls when live, reconnects otherwise.
  /// 实时时重新轮询，否则重新连接。
  Future<void> _handleRefresh() async {
    final messenger = ScaffoldMessenger.of(context);
    if (_isLive) {
      await _refreshResources();
      return;
    }
    await _retryMonitoring();
    // A retry that failed has already reported itself; a confirmation here
    // would contradict it.
    // 失败的重试已经自行报告过；此处再确认一次只会与之矛盾。
    if (!mounted || !_isLive) return;
    messenger.showSnackBar(SnackBar(content: Text(t('resource_refreshed'))));
  }

  /// Waits for fresh numbers and confirms them.
  /// 等待新的数据并给出确认。
  ///
  /// When a tick is already running, waiting for it is the only honest option:
  /// starting a second one is what the guard forbids, and reporting success
  /// without it would be a lie. A tick that fails reports its own reason.
  /// 已有 tick 在运行时，等待它是唯一诚实的做法：再起一个正是守门规则所禁止的，而
  /// 不刷新却报成功则是撒谎。失败的 tick 会自行报告原因。
  Future<void> _refreshResources() async {
    final messenger = ScaffoldMessenger.of(context);
    final inFlight = _tickInFlight;
    final refreshed = inFlight != null ? await inFlight : await _pollOnce();
    if (!mounted || !refreshed) return;
    messenger.showSnackBar(SnackBar(content: Text(t('resource_refreshed'))));
  }

  /// Drops the current connection and starts over.
  /// 丢弃当前连接并重新开始。
  Future<void> _retryMonitoring() async {
    _pollTimer?.cancel();
    _pollTimer = null;
    // Abandon whatever is in flight before the connection it uses is gone.
    // 在所用连接消失之前，放弃仍在途的一切。
    _poll.restart();
    _teardownMonitor();
    if (mounted) {
      setState(() {
        _monitorError = null;
        _connecting = false;
        _isLive = false;
        _lastCpuTimes = null;
        // Keep the last real points visible while reconnecting, but let the
        // first sample of the new session replace all of them.
        // 重连期间保留最后的真实数据点，但让新会话的首个样本整体替换它们。
        _samples.beginSession();
      });
    }
    await _initMonitoring();
  }

  // ===========================================================================
  // Build
  // ===========================================================================

  @override
  Widget build(BuildContext context) {
    final host = widget.host;

    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      body: RefreshIndicator(
        onRefresh: _handleRefresh,
        child: CustomScrollView(
          slivers: [
            HostConsoleAppBar(
              connecting: _connecting,
              live: _isLive,
              onBack: () => Navigator.pop(context),
              onRefresh: _handleRefresh,
            ),
            SliverToBoxAdapter(
              child: HostConsoleIdentityCard(
                host: host,
                hostname: _identity.hostname,
                osInfo: _identity.osInfo,
                live: _isLive,
              ),
            ),
            SliverToBoxAdapter(
              child: ResourceMonitorCard(
                glow: _glowController,
                cpuData: _samples.cpuData,
                ramData: _samples.ramData,
                latestCpu: _samples.latestCpu,
                latestRam: _samples.latestRam,
                live: _isLive,
                connecting: _connecting,
                error: _monitorError,
                sampleInterval: _pollInterval,
                onRetry: _retryMonitoring,
              ),
            ),
            SliverToBoxAdapter(child: ConsoleFunctionGrid(host: host)),
            SliverToBoxAdapter(
              child: SizedBox(
                height: 24 + MediaQuery.of(context).padding.bottom,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
