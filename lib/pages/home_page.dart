import 'package:flutter/foundation.dart' show setEquals;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/i18n/strings.dart';
import '../models/host.dart';
import '../providers/providers.dart';
import '../providers/ssh_provider.dart';
import '../services/host_key_trust.dart';
import '../services/ssh_service.dart';
import '../widgets/app_drawer.dart';
import '../widgets/app_ui.dart';
import 'batch_exec_page.dart';
import 'host_console_page.dart';
import 'add_host_page.dart';
import 'ssh_terminal_page.dart';
import 'hosts/host_list_model.dart';
import 'hosts/host_list_widgets.dart';
import 'hosts/host_list_view.dart';
import 'hosts/host_search_field.dart';

/// Home screen showing the host list, split by the three states a host can be
/// in: online, unverified, offline, and — inside each of those — by group.
/// 显示主机列表的主页，按主机可能处于的三种状态分组：在线、待验证、离线；每组内部
/// 再按分组切分。
///
/// Search and grouping compose inside that three-state split rather than over
/// it; the reasoning is written out at [buildHostSections], next to the rule
/// itself.
/// 搜索与分组是在三态切分**之内**组合，而不是压在它之上；理由写在
/// [buildHostSections] 旁边，与规则本身放在一起。
class HomePage extends ConsumerStatefulWidget {
  const HomePage({super.key});

  @override
  ConsumerState<HomePage> createState() => _HomePageState();
}

class _HomePageState extends ConsumerState<HomePage> {
  /// Minimum interval between two automatically scheduled probe rounds. A
  /// rebuild that does not change the host set and lands inside this window
  /// never starts a new round.
  /// 两轮自动安排的探测之间的最小间隔。未改变主机集合且落入该窗口的重建
  /// 不会发起新一轮探测。
  static const Duration _probeMinInterval = Duration(seconds: 30);

  /// Upper bound on the number of SSH sessions one probe round may have open
  /// at the same time.
  /// 单轮探测同时打开的 SSH 会话数上限。
  static const int _probeConcurrency = 4;

  final Set<String> _probingHosts = {};
  bool _probeScheduled = false;
  bool _isProbing = false;
  bool _probePending = false;

  /// The probe round currently in flight, if any, so a pull-to-refresh can wait
  /// for it instead of stacking a second round on top of the first.
  Future<void>? _probeRound;
  DateTime? _lastProbeAt;
  Set<String> _lastProbedHostIds = const <String>{};
  DateTime? _lastExitAttemptAt;

  /// Text currently in the search field. Owned by the page, so the field's
  /// clear button and the filtering below can never disagree about what is
  /// being searched for.
  /// 搜索框中的文字。由页面持有，因此清除按钮与下面的过滤逻辑对「在搜什么」永远不会
  /// 各执一词。
  final TextEditingController _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    // A listener rather than `onChanged`, so a clear through the field's own
    // button rebuilds the list exactly like typing does.
    // 使用监听器而非 `onChanged`，使通过输入框自身按钮的清除与手动输入一样触发重建。
    _searchController.addListener(_onSearchChanged);
  }

  void _onSearchChanged() {
    if (!mounted) return;
    setState(() {});
  }

  @override
  void dispose() {
    _searchController.dispose();
    _probingHosts.clear();
    super.dispose();
  }

  /// Arms a reachability probe for [hosts]; called from the `data:` builder, so
  /// it runs on every rebuild.
  /// 为 [hosts] 安排一次可达性探测；它由 `data:` 构建器调用，因此每次重建都会执行。
  ///
  /// Two independent guards keep a rebuild from starting a new round:
  /// * a rebuild whose host id set is unchanged and that lands within
  ///   [_probeMinInterval] is ignored;
  /// * [_lastProbeAt] is stamped here, when the round is *scheduled*, and is
  ///   never reset from inside the post-frame callback. The previous guard
  ///   cleared its flag before the `await`, so a rebuild that arrived while the
  ///   round was in flight sailed straight through.
  /// 两道独立防线阻止重建发起新一轮探测：主机 id 集合未变且处于
  /// [_probeMinInterval] 内的重建会被忽略；[_lastProbeAt] 在“安排”时打点，
  /// 且绝不在 post-frame 回调中重置——旧守卫在 `await` 之前就清除了标志，
  /// 使轮次在途时到来的重建得以长驱直入。
  void _scheduleStatusProbe(List<Host> hosts) {
    if (hosts.isEmpty) return;

    final ids = hosts.map((h) => h.id).toSet();
    final idsChanged = !setEquals(ids, _lastProbedHostIds);
    final now = DateTime.now();
    final lastAt = _lastProbeAt;
    final throttled =
        lastAt != null && now.difference(lastAt) < _probeMinInterval;

    // Plain rebuild (same hosts, still inside the throttle window): do nothing.
    // 普通重建（主机相同且仍在节流窗口内）：不做任何事。
    if (!idsChanged && throttled) return;

    if (_probeScheduled || _isProbing) {
      // A round is already on its way; pick up the new host set once it ends.
      // 已有一轮在途中；等它结束后再处理新的主机集合。
      if (idsChanged) _probePending = true;
      return;
    }

    _probeScheduled = true;
    _lastProbeAt = now;
    _lastProbedHostIds = ids;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      _probeScheduled = false;
      if (!mounted) return;
      await _probeHosts(hosts);
    });
  }

  /// Probes every host in [hosts] and pushes the result into [hostListProvider].
  /// 探测 [hosts] 中的每台主机，并把结果写入 [hostListProvider]。
  ///
  /// Probes run concurrently with a bounded concurrency of [_probeConcurrency],
  /// so one unreachable host no longer delays every host behind it (audit
  /// finding rob-3), while the number of simultaneous SSH sessions stays
  /// small. Failures stay isolated per host: one host failing never aborts the
  /// round or a sibling probe.
  /// 探测以 [_probeConcurrency] 为上限并发执行：一台不可达主机不再拖累其后的
  /// 所有主机（审计问题 rob-3），同时打开的 SSH 会话数仍然很少。失败按主机
  /// 隔离：单台主机失败不会中断整轮探测，也不会影响并发中的其他主机。
  Future<void> _probeHosts(List<Host> hosts) {
    // The round already running is returned rather than replaced: a caller that
    // awaited this expecting statuses to be fresh would otherwise resume while
    // the only round that could have refreshed them is still going.
    if (_isProbing) return _probeRound ?? Future<void>.value();
    _isProbing = true;
    final round = _runProbeRound(hosts);
    _probeRound = round;
    return round;
  }

  Future<void> _runProbeRound(List<Host> hosts) async {
    try {
      final credentials = await ref.read(credentialListProvider.future);
      final credMap = {for (final c in credentials) c.id: c};

      // One lookup per round is enough: every host's verifier reads the same
      // known-hosts table.
      // 每轮取一次即可：所有主机的校验器读的是同一张 known_hosts 表。
      final db = await ref.read(databaseProvider.future);

      // Read once per round, not per host: every probe in this sweep should be
      // judged by the same budget even if the user changes the setting midway.
      // The clamp itself — and the reasoning for why a background sweep must
      // not inherit a 30s interactive timeout — lives with the provider, next
      // to the setting it belongs to.
      // 每轮读取一次，而不是每台主机一次：即使中途改设置，本轮所有探测也应由同一预算
      // 判定。钳制本身（以及「后台扫描为何不能继承交互式的 30 秒超时」的理由）与它所属
      // 的设置一起，放在 provider 旁边。
      final probeTimeout = probeConnectTimeout(
        ref.read(connectTimeoutProvider),
      );

      final queue = <Host>[
        for (final host in hosts)
          if (!_probingHosts.contains(host.id)) host,
      ];

      // Each worker pulls the next host as soon as it finishes its current one.
      // 每个 worker 完成当前主机后立即领取下一台。
      Future<void> worker() async {
        while (queue.isNotEmpty) {
          if (!mounted) return;
          final host = queue.removeAt(0);
          // A single host must never take the whole round down with it.
          // 单台主机绝不能把整轮探测一并拖垮。
          try {
            final credential = credMap[host.credentialId];
            if (credential == null) {
              // Nothing to connect with, so the probe never ran: it has no
              // evidence either way and must not report the host as down.
              // 没有可用的连接凭据，探测根本没有发起：它两边都没有证据，绝不能把
              // 主机报成宕机。
              await ref
                  .read(hostListProvider.notifier)
                  .setStatus(
                    host.id,
                    Host.statusForProbe(
                      attempted: false,
                      connected: false,
                      trustRefused: false,
                    ),
                  );
              continue;
            }

            _probingHosts.add(host.id);
            // Set from inside `onPrompt` below, read once the attempt is over.
            // 由下面的 `onPrompt` 置位，在本次尝试结束后读取。
            var trustRefused = false;
            // A probe is a full SSH session with the stored credential, so it
            // must verify the host key like every other connection: `dartssh2`
            // accepts any key when no callback is passed, which is exactly what
            // a machine-in-the-middle needs.
            // 探测同样是一次带真实凭据的完整 SSH 会话，必须和其它连接一样校验
            // 主机密钥：不传回调时 `dartssh2` 会接受任意密钥，这正是中间人想要的。
            final conn = SshConnection(
              host: host,
              credential: credential,
              connectTimeout: probeTimeout,
              onHostKeyVerify: buildHostKeyVerifier(
                db: db,
                address: host.ipAddress,
                port: host.port,
                // `onPrompt` fires exactly when the presented key is not
                // trusted yet (see host_key_trust.dart) — the case that used to
                // raise a modal prompt from a background probe. It must not: a
                // dialog the user never asked for, once per untrusted host on
                // every launch, is one they learn to dismiss on reflex, and
                // then the one prompt that carries real signal — "this host's
                // key CHANGED" — is dismissed with the rest. Refusing silently
                // keeps the trust decision where it belongs, in a connection
                // the user asked for. Refusing stores nothing, so the host
                // stays untrusted and later rounds re-refuse just as silently.
                // `onPrompt` 恰在呈现的密钥尚未受信时触发（见 host_key_trust.dart）
                // ——这正是过去会从后台探测弹出模态提示的情形。它绝不能这么做：
                // 每次启动为每台未受信主机弹一个用户从未请求的对话框，只会让人条件
                // 反射地关掉，而真正承载信号的那一次提示「此主机的密钥已变更」也会
                // 被一并关掉。静默拒绝把信任决策留在它该在的地方——用户主动发起的
                // 连接里。拒绝不写入任何记录，主机保持未受信，后续轮次同样静默重拒。
                onPrompt: (_, _) async {
                  trustRefused = true;
                  return false;
                },
              ),
            );
            try {
              await conn.connect();
              await ref
                  .read(hostListProvider.notifier)
                  .setStatus(
                    host.id,
                    Host.statusForProbe(
                      attempted: true,
                      connected: conn.state == SshConnectionState.connected,
                      trustRefused: trustRefused,
                    ),
                  );
            } catch (_) {
              await ref
                  .read(hostListProvider.notifier)
                  .setStatus(
                    host.id,
                    Host.statusForProbe(
                      attempted: true,
                      connected: false,
                      trustRefused: trustRefused,
                    ),
                  );
            } finally {
              conn.dispose();
              _probingHosts.remove(host.id);
            }
          } catch (_) {
            _probingHosts.remove(host.id);
          }
        }
      }

      await Future.wait([for (var i = 0; i < _probeConcurrency; i++) worker()]);
    } finally {
      _isProbing = false;
      _probeRound = null;
      _resumePendingProbe();
    }
  }

  /// Runs a probe round that the rebuild throttle does not get to refuse, and
  /// waits for it.
  ///
  /// The throttle exists to keep ordinary rebuilds from launching rounds. A pull
  /// is not an ordinary rebuild: it is the user asking a direct question, and
  /// before this the answer was often "nothing" — a pull within 30 s of launch
  /// started no round at all, and one after it stopped the spinner before the
  /// round it appeared to be waiting for had finished, so statuses flipped a
  /// second later with nothing on screen to explain why.
  Future<void> _refreshHostStatuses(List<Host> hosts) async {
    if (hosts.isEmpty) return;
    // Let any round already in flight finish first, so the round below is not
    // refused by the guard above.
    await _probeRound;
    // Cleared so the throttle cannot swallow the round this pull is asking for.
    _lastProbeAt = null;
    await _probeHosts(hosts);
  }

  /// Re-arms a probe when the host set changed while a round was in flight.
  /// 当一轮探测在途期间主机集合发生变化时，重新安排探测。
  void _resumePendingProbe() {
    if (!_probePending) return;
    _probePending = false;
    if (!mounted) return;
    final latest = ref.read(hostListProvider).value;
    if (latest == null || latest.isEmpty) return;
    _scheduleStatusProbe(latest);
  }

  Future<void> _handleRootBack() async {
    final now = DateTime.now();
    final shouldExit =
        _lastExitAttemptAt != null &&
        now.difference(_lastExitAttemptAt!) < const Duration(seconds: 2);
    if (shouldExit) {
      await SystemNavigator.pop();
      return;
    }

    _lastExitAttemptAt = now;
    if (!mounted) return;
    final cs = Theme.of(context).colorScheme;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(t('press_back_again_to_exit')),
          backgroundColor: cs.surfaceContainerHighest,
          behavior: SnackBarBehavior.floating,
          margin: const EdgeInsets.all(16),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    // "Unknown" is not "down": the theme's error colour would assert an outage
    // nothing established, so unverified hosts get a muted, non-alarming tone.
    // Taken from the same helper the cards use, so the section header, its note
    // and the cards below cannot drift apart.
    // 「未知」不是「宕机」：主题的错误色会断言一次并无依据的故障，因此待验证的
    // 主机使用柔和、不刺眼的色调。取自卡片所用的同一个辅助函数，分组标题、说明与
    // 其下的卡片才不会各走各的。
    final hostAsync = ref.watch(hostListProvider);

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _handleRootBack();
      },
      child: Scaffold(
        drawer: const AppDrawer(currentModule: 'hosts', isTopLevel: true),
        appBar: AppBar(
          leading: Builder(
            builder: (ctx) => IconButton(
              icon: Icon(Icons.menu, color: cs.onSurface),
              onPressed: () => Scaffold.of(ctx).openDrawer(),
            ),
          ),
          title: Text(
            t('my_hosts'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          actions: [
            // The batch lives here rather than inside a host's console because
            // it is the one action that is about the list itself: pick several,
            // run one command on all of them.
            IconButton(
              icon: Icon(Icons.playlist_play, color: cs.secondary),
              tooltip: t('run_on_many'),
              // Always enabled, even with no hosts: the page it opens says so
              // and offers the way to add one, which is a better answer than a
              // button that silently does nothing.
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const BatchExecPage()),
              ),
            ),
            IconButton(
              icon: Icon(Icons.add, color: cs.secondary),
              onPressed: () => _openAddHost(context),
            ),
          ],
        ),
        body: hostAsync.when(
          loading: () =>
              Center(child: CircularProgressIndicator(color: cs.primary)),
          error: (e, _) => Center(
            child: Text(
              '${t('error')}: $e',
              style: TextStyle(color: cs.onSurface.withValues(alpha: 0.6)),
            ),
          ),
          data: (hosts) {
            _scheduleStatusProbe(hosts);
            final query = _searchController.text;
            final sections = buildHostSections(hosts, query);

            // The search field sits outside the scroll view on purpose: the
            // whole point of searching is that the list is long, and a field
            // that scrolls away is one the user has to scroll back to before
            // they can correct a typo.
            // 搜索框刻意放在滚动视图之外：搜索存在的理由正是列表很长，而一个会滚走的
            // 输入框意味着用户必须滚回去才能改一个错字。
            return Column(
              children: [
                if (shouldOfferSearch(hostCount: hosts.length, query: query))
                  HostSearchField(controller: _searchController),
                Expanded(
                  child: RefreshIndicator(
                    color: cs.primary,
                    onRefresh: () async {
                      ref.invalidate(hostListProvider);
                      final fresh = await ref.read(hostListProvider.future);
                      // The spinner covers the probe too, so it stops when the
                      // statuses on screen are the ones this pull produced.
                      if (mounted) await _refreshHostStatuses(fresh);
                    },
                    // The overview card, the section headers and the group
                    // headers all live inside the list, from the same
                    // `sections`, so their numbers cannot disagree.
                    // 摘要卡、分区标题与分组标题都在列表内部，且同出一份 `sections`，
                    // 因此它们的数字不可能互相矛盾。
                    child: HostListView(
                      sections: sections,
                      hasQuery: query.trim().isNotEmpty,
                      onAddHost: () => _openAddHost(context),
                      onOpenHost: (host) => _navigateToConsole(context, host),
                      onHostOptions: (host) =>
                          _showHostOptions(context, ref, host),
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  /// Opens the add-host form.
  /// 打开新增主机表单。
  ///
  /// Named rather than inlined at the app bar because the empty state offers the
  /// same action, and two call sites spelling the route out separately is how
  /// one of them ends up pointing somewhere else.
  /// 单独成方法而不是写在应用栏里，是因为空状态提供的是同一个动作；两处各写一遍路由，
  /// 正是其中一处最终指向别处的原因。
  Future<void> _openAddHost(BuildContext context) {
    return Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const AddHostPage()),
    );
  }

  /// Builds the card for [host], wiring up the interactions the list offers.
  /// 构建 [host] 的卡片，接上列表提供的各项交互。

  void _navigateToConsole(BuildContext context, Host host) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => HostConsolePage(host: host)),
    );
  }

  void _showHostOptions(BuildContext context, WidgetRef ref, Host host) {
    final cs = Theme.of(context).colorScheme;
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(8)),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: cs.onSurface.withValues(alpha: 0.18),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: 16),
              Text(
                host.alias,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                host.displayAddress,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: cs.onSurface.withValues(alpha: 0.6),
                  fontSize: 13,
                ),
              ),
              const SizedBox(height: 16),
              const Divider(height: 1),
              // A shell first. This sheet used to offer detail / edit / delete,
              // and a shell was four taps away — into the console, which opens a
              // monitoring session of its own, down past the identity card and
              // the resource panel to the function grid, then a second full SSH
              // connect. For a server tool that is the main thing people came to
              // do, sitting behind the least important one.
              HostActionRow(
                icon: Icons.terminal,
                label: t('open_terminal'),
                color: cs.primary,
                onTap: () {
                  Navigator.pop(ctx);
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => SshTerminalPage(host: host),
                    ),
                  );
                },
              ),
              HostActionRow(
                icon: Icons.open_in_new,
                label: t('host_detail'),
                color: cs.secondary,
                onTap: () {
                  Navigator.pop(ctx);
                  _navigateToConsole(context, host);
                },
              ),
              HostActionRow(
                icon: Icons.copy,
                label: '${t('copy')} ${t('ip_address')}',
                color: cs.onSurface.withValues(alpha: 0.72),
                onTap: () {
                  Navigator.pop(ctx);
                  Clipboard.setData(ClipboardData(text: host.ipAddress));
                  ScaffoldMessenger.of(
                    context,
                  ).showSnackBar(SnackBar(content: Text(t('copied'))));
                },
              ),
              HostActionRow(
                icon: Icons.edit_outlined,
                label: t('edit'),
                color: cs.onSurface.withValues(alpha: 0.72),
                onTap: () {
                  Navigator.pop(ctx);
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => AddHostPage(existingHost: host),
                    ),
                  );
                },
              ),
              HostActionRow(
                icon: Icons.delete_outline,
                label: t('delete'),
                color: cs.error,
                onTap: () {
                  Navigator.pop(ctx);
                  _confirmDeleteHost(context, ref, host);
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _confirmDeleteHost(
    BuildContext context,
    WidgetRef ref,
    Host host,
  ) async {
    final confirmed = await showAppConfirmDialog(
      context,
      title: t('confirm_delete'),
      message: t('confirm_delete_host').replaceAll('{0}', host.alias),
      cancelLabel: t('cancel'),
      confirmLabel: t('delete'),
      destructive: true,
    );
    if (!confirmed) return;

    await ref.read(hostListProvider.notifier).deleteItem(host.id);
    if (!context.mounted) return;
    // Undo, because the delete is otherwise final: the confirmation stands
    // between a mistap and the loss, but the sheet rows sit close together and
    // the host config is not reconstructible from anything else on the device.
    // `addItem` inserts with `ConflictAlgorithm.replace`, so re-inserting the
    // same [Host] restores it under its original id — no new capability needed,
    // and anything referencing that id finds it again.
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(t('host_deleted')),
          behavior: SnackBarBehavior.floating,
          action: SnackBarAction(
            label: t('undo'),
            onPressed: () => ref.read(hostListProvider.notifier).addItem(host),
          ),
        ),
      );
  }
}
