import 'package:flutter/foundation.dart' show setEquals;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/i18n/strings.dart';
import '../models/host.dart';
import '../providers/providers.dart';
import '../services/ssh_service.dart';
import '../widgets/host_card.dart';
import '../widgets/app_drawer.dart';
import '../widgets/app_ui.dart';
import 'host_console_page.dart';
import 'add_host_page.dart';

/// Home screen showing the host list with online/offline sections.
/// 显示主机列表的主页，按在线/离线分组。
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

  /// Connect timeout for a single reachability probe.
  /// 单次可达性探测的连接超时。
  static const Duration _probeConnectTimeout = Duration(seconds: 4);

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
              await ref
                  .read(hostListProvider.notifier)
                  .setOnline(host.id, false);
              continue;
            }

            _probingHosts.add(host.id);
            final conn = SshConnection(
              host: host,
              credential: credential,
              connectTimeout: _probeConnectTimeout,
            );
            try {
              await conn.connect();
              await ref
                  .read(hostListProvider.notifier)
                  .setOnline(host.id, conn.state == SshConnectionState.connected);
            } catch (_) {
              await ref
                  .read(hostListProvider.notifier)
                  .setOnline(host.id, false);
            } finally {
              conn.dispose();
              _probingHosts.remove(host.id);
            }
          } catch (_) {
            _probingHosts.remove(host.id);
          }
        }
      }

      await Future.wait([
        for (var i = 0; i < _probeConcurrency; i++) worker(),
      ]);
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
            final online = hosts.where((h) => h.isOnline).toList();
            final offline = hosts.where((h) => !h.isOnline).toList();

            return RefreshIndicator(
              color: cs.primary,
              onRefresh: () async {
                ref.invalidate(hostListProvider);
                await ref.read(hostListProvider.future);
              },
              child: ListView(
                padding: const EdgeInsets.only(top: 12, bottom: 32),
                children: [
                  _buildOverview(context, hosts, online.length, offline.length),
                  if (online.isNotEmpty) ...[
                    AppSectionHeader(
                      title: t('online_hosts'),
                      trailing: '${online.length}',
                      color: cs.primary,
                    ),
                    ...online.map(
                      (host) => HostCard(
                        host: host,
                        onTap: () => _navigateToConsole(context, host),
                        onLongPress: () => _showHostOptions(context, ref, host),
                        onMore: () => _showHostOptions(context, ref, host),
                      ),
                    ),
                  ],
                  if (offline.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    AppSectionHeader(
                      title: t('offline_hosts'),
                      trailing: '${offline.length}',
                      color: cs.error,
                    ),
                    ...offline.map(
                      (host) => HostCard(
                        host: host,
                        onTap: () => _navigateToConsole(context, host),
                        onLongPress: () => _showHostOptions(context, ref, host),
                        onMore: () => _showHostOptions(context, ref, host),
                      ),
                    ),
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

  Widget _buildOverview(
    BuildContext context,
    List<Host> hosts,
    int onlineCount,
    int offlineCount,
  ) {
    final cs = Theme.of(context).colorScheme;
    final total = hosts.length;
    return AppCard(
      margin: const EdgeInsets.fromLTRB(16, 4, 16, 14),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      child: Row(
        children: [
          _OverviewItem(
            label: t('total'),
            value: '$total',
            color: cs.secondary,
            icon: Icons.dns_outlined,
          ),
          _OverviewDivider(),
          _OverviewItem(
            label: t('running'),
            value: '$onlineCount',
            color: cs.primary,
            icon: Icons.check_circle_outline,
          ),
          _OverviewDivider(),
          _OverviewItem(
            label: t('offline_status'),
            value: '$offlineCount',
            color: cs.error,
            icon: Icons.link_off,
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
