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
import '../widgets/host_card.dart';
import '../widgets/app_drawer.dart';
import '../widgets/app_ui.dart';
import 'host_console_page.dart';
import 'add_host_page.dart';

/// Home screen showing the host list, split by the three states a host can be
/// in: online, unverified, offline.
/// 显示主机列表的主页，按主机可能处于的三种状态分组：在线、待验证、离线。
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
  DateTime? _lastProbeAt;
  Set<String> _lastProbedHostIds = const <String>{};
  DateTime? _lastExitAttemptAt;

  @override
  void dispose() {
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
  Future<void> _probeHosts(List<Host> hosts) async {
    if (_isProbing) return;
    _isProbing = true;
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
      _resumePendingProbe();
    }
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
    final unverifiedColor = hostStatusColor(cs, HostStatus.unverified);
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
            IconButton(
              icon: Icon(Icons.add, color: cs.secondary),
              onPressed: () async {
                await Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const AddHostPage()),
                );
              },
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
            // Three groups, because `HostStatus` has three values: folding
            // "unverified" in with either neighbour is exactly the conflation
            // the old boolean forced on this page.
            // 三个分组，因为 `HostStatus` 有三个取值：把「待验证」并入任何一侧，
            // 正是旧布尔字段强加给本页的混淆。
            final online = hosts
                .where((h) => h.status == HostStatus.online)
                .toList();
            final unverified = hosts
                .where((h) => h.status == HostStatus.unverified)
                .toList();
            final offline = hosts
                .where((h) => h.status == HostStatus.offline)
                .toList();

            return RefreshIndicator(
              color: cs.primary,
              onRefresh: () async {
                ref.invalidate(hostListProvider);
                await ref.read(hostListProvider.future);
              },
              child: ListView(
                padding: const EdgeInsets.only(top: 12, bottom: 32),
                children: [
                  _buildOverview(
                    context,
                    hosts,
                    online.length,
                    unverified.length,
                    offline.length,
                  ),
                  if (online.isNotEmpty) ...[
                    AppSectionHeader(
                      title: t('online_hosts'),
                      trailing: '${online.length}',
                      color: cs.primary,
                    ),
                    ...online.map(_buildHostCard),
                  ],
                  // Unverified hosts get their own section between the two.
                  // They are neither usable-as-confirmed nor known to be down:
                  // filing them under "Offline" would state an outage nobody
                  // measured, which is how a user learns that a red section
                  // means nothing — and then misses the one that does.
                  // Their group is also the one the user can act on: opening
                  // the host is what turns it into online or offline.
                  // 待验证的主机在两个分组之间单列。它们既不是「可用且已确认」，
                  // 也不是「确知宕机」：归入「离线」等于宣称一次无人测量过的故障，
                  // 那正是用户学会「红色分组不代表什么」的途径，之后连有意义的那次
                  // 也会被忽略。这个分组也恰恰是用户可以行动的一组：打开主机即可让
                  // 它变成在线或离线。
                  if (unverified.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    AppSectionHeader(
                      title: t('host_status_unverified'),
                      trailing: '${unverified.length}',
                      color: unverifiedColor,
                    ),
                    _UnverifiedNote(color: unverifiedColor),
                    ...unverified.map(_buildHostCard),
                  ],
                  if (offline.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    AppSectionHeader(
                      title: t('offline_hosts'),
                      trailing: '${offline.length}',
                      color: cs.error,
                    ),
                    ...offline.map(_buildHostCard),
                  ],
                  if (hosts.isEmpty) _buildEmptyState(context, cs),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  /// Builds the card for [host], wiring up the interactions the list offers.
  /// 构建 [host] 的卡片，接上列表提供的各项交互。
  Widget _buildHostCard(Host host) => HostCard(
    host: host,
    onTap: () => _navigateToConsole(context, host),
    onLongPress: () => _showHostOptions(context, ref, host),
    onMore: () => _showHostOptions(context, ref, host),
  );

  Widget _buildOverview(
    BuildContext context,
    List<Host> hosts,
    int onlineCount,
    int unverifiedCount,
    int offlineCount,
  ) {
    final cs = Theme.of(context).colorScheme;
    final total = hosts.length;
    // Two rows of two, not one row of four. All three states plus the total have
    // to be readable at once, and at 360dp a four-across row squeezes each
    // label to roughly two thirds of what "Unverified" or "Не подтверждён"
    // needs — they would ellipsise, and a summary that hides its labels is not
    // a summary. The counts must also visibly add up: a total that does not
    // equal its parts reads as a broken screen, which is exactly what the
    // three-item version did whenever a host was unverified, i.e. on every
    // first launch.
    // 两行两列而不是一行四个。三种状态加总数必须同时可读：在 360dp 上排成一行会把每个
    // 标签压到 "Unverified" 或 "Не подтверждён" 所需宽度的约三分之二，它们会被省略号
    // 截断，而藏起标签的摘要就不成其为摘要。数字还必须一眼看得出能对上：总数与各部分不等
    // 的摘要卡看起来就是坏掉的，而这正是三格版本在有主机未验证时的表现——也就是每次首次
    // 启动都会如此。
    //
    // Labels and colours come from the same helpers the host cards use, so the
    // header and the rows below it cannot drift apart.
    // 文案与配色取自主机卡片所用的同一组 helper，因此顶部摘要与下方列表不会各说各话。
    return AppCard(
      margin: const EdgeInsets.fromLTRB(16, 4, 16, 14),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
      child: Column(
        children: [
          Row(
            children: [
              _OverviewItem(
                label: t('total'),
                value: '$total',
                color: cs.secondary,
                icon: Icons.dns_outlined,
              ),
              _OverviewDivider(),
              _OverviewItem(
                label: hostStatusLabel(HostStatus.online),
                value: '$onlineCount',
                color: hostStatusColor(cs, HostStatus.online),
                icon: Icons.check_circle_outline,
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              _OverviewItem(
                label: hostStatusLabel(HostStatus.unverified),
                value: '$unverifiedCount',
                color: hostStatusColor(cs, HostStatus.unverified),
                icon: Icons.help_outline,
              ),
              _OverviewDivider(),
              _OverviewItem(
                label: hostStatusLabel(HostStatus.offline),
                value: '$offlineCount',
                color: hostStatusColor(cs, HostStatus.offline),
                icon: Icons.link_off,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState(BuildContext context, ColorScheme cs) {
    return SizedBox(
      height: 360,
      child: AppEmptyState(
        icon: Icons.dns_outlined,
        title: t('empty_hosts'),
        message: t('empty_hosts_hint'),
        actionLabel: t('add_host'),
        color: cs.primary,
        onAction: () {
          Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const AddHostPage()),
          );
        },
      ),
    );
  }

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
              _HostActionRow(
                icon: Icons.open_in_new,
                label: t('host_detail'),
                color: cs.secondary,
                onTap: () {
                  Navigator.pop(ctx);
                  _navigateToConsole(context, host);
                },
              ),
              _HostActionRow(
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
              _HostActionRow(
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

    ref.read(hostListProvider.notifier).deleteItem(host.id);
    if (!context.mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(t('host_deleted'))));
  }
}

class _HostActionRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;

  const _HostActionRow({
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return AppCard(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      onTap: onTap,
      child: Row(
        children: [
          Icon(icon, color: color, size: 21),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: color, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }
}

/// One-line explanation shown under the "unverified" section header, so the
/// state reads as "we have not checked this host yet" rather than as a failure.
/// 「待验证」分组标题下的一行说明，让该状态读起来是「我们还没核对过这台主机」
/// 而不是一次故障。
class _UnverifiedNote extends StatelessWidget {
  /// Colour matching the section header and the cards below it.
  /// 与该分组标题及其下卡片一致的颜色。
  final Color color;

  const _UnverifiedNote({required this.color});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 6),
      child: Text(
        t('host_status_unverified_hint'),
        style: TextStyle(color: color, fontSize: 11.5, height: 1.35),
      ),
    );
  }
}

class _OverviewItem extends StatelessWidget {
  final String label;
  final String value;
  final Color color;
  final IconData icon;

  const _OverviewItem({
    required this.label,
    required this.value,
    required this.color,
    required this.icon,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Expanded(
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 8),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                value,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: cs.onSurface,
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                ),
              ),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: cs.onSurface.withValues(alpha: 0.46),
                  fontSize: 10,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _OverviewDivider extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      width: 1,
      height: 32,
      color: Theme.of(context).dividerColor,
    );
  }
}
