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
import '../widgets/app_ui.dart';
import '../widgets/host_key_prompt.dart';
import 'console/ssh_error_text.dart';
import 'containers/remote_action_outcome.dart';
import 'systemd/systemd_action_sheet.dart';
import 'systemd/systemd_bars.dart';
import 'systemd/systemd_service_card.dart';

class SystemdPage extends ConsumerStatefulWidget {
  final Host host;
  const SystemdPage({super.key, required this.host});
  @override
  ConsumerState<SystemdPage> createState() => _SystemdPageState();
}

class _SystemdPageState extends ConsumerState<SystemdPage> {
  List<Map<String, dynamic>> _services = [];
  List<Map<String, dynamic>> _filtered = [];
  bool _loading = true;
  String? _error;
  SshConnection? _conn;
  String _filter = 'All';
  final _searchCtrl = TextEditingController();
  String _searchQuery = '';

  int get _running => _services.where((s) => _isRunning(s)).length;
  int get _failed => _services.where((s) => _isFailed(s)).length;
  int get _inactive =>
      _services.where((s) => !_isRunning(s) && !_isFailed(s)).length;

  bool _isRunning(Map<String, dynamic> s) =>
      (s['active'] as String).toLowerCase() == 'active';
  bool _isFailed(Map<String, dynamic> s) =>
      (s['active'] as String).toLowerCase() == 'failed';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    _conn?.dispose();
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final host = widget.host;
    try {
      final creds = await ref.read(credentialListProvider.future);
      final cred = creds.where((c) => c.id == host.credentialId).firstOrNull;
      if (cred == null) {
        setState(() {
          _loading = false;
          _error = t('cred_not_found_title');
        });
        return;
      }
      if (_conn == null || _conn!.state != SshConnectionState.connected) {
        _conn?.dispose();

        // The service-manager connection is a real SSH session, so it has to
        // verify the host key like every other one: `dartssh2` accepts any key
        // when no callback is passed, which is exactly what a machine-in-the-
        // middle needs.
        // 服务管理连接是真实的 SSH 会话，必须和其它连接一样校验主机密钥：
        // 不传回调时 `dartssh2` 会接受任意密钥，这正是中间人想要的。
        final db = await ref.read(databaseProvider.future);
        _conn = SshConnection(
          host: host,
          credential: cred,
          // Settings → connect timeout. This page used to inherit the
          // constructor's default silently, so the setting reached nothing here.
          // 设置 → 连接超时。本页此前静默沿用构造函数默认值，该设置在此毫无作用。
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
        await _conn!.connect();
        if (_conn!.state != SshConnectionState.connected) {
          setState(() {
            _loading = false;
            // The reason, in the user's own language: the connection reports a
            // code (`SshConnection.failure`) and the service no longer writes
            // the sentence itself.
            // 用用户自己的语言给出原因：连接上报的是编码（`SshConnection.failure`），
            // 句子不再由服务书写。
            _error = sshConnectErrorText(_conn!);
          });
          return;
        }
      }
      final result = await _conn!.runCommand(
        'systemctl list-units --type=service --all --no-pager --no-legend',
      );
      // A listing that failed must say so instead of rendering an empty list,
      // which used to be indistinguishable from "no services" — the defect
      // already fixed for `docker ps`. A host whose init is not systemd answers
      // this command with an error, and that answer is the one the user needs,
      // not an empty page.
      // 失败的列表命令必须说明原因，而不是渲染一个空列表——过去它与「没有服务」无法
      // 区分，正是已在 `docker ps` 上修复过的缺陷。init 不是 systemd 的主机对该命令
      // 返回的是错误，而那个错误正是用户需要看到的，不是空页面。
      //
      // `ok` means an exit status of exactly 0 and nothing else: a status the
      // server never reported is *unknown*, not success (see CommandResult.ok),
      // and for a listing whose whole answer is the row set, an unconfirmed read
      // must not be shown as "no services". The container listing tolerates a
      // missing status because it has rows to fall back on; this one does not.
      // `ok` 仅指退出状态恰为 0：服务端从未上报的状态是**未知**而非成功
      // （见 CommandResult.ok）；对一个答案就是整份行集的列表来说，未经确认的读取不得
      // 当作「没有服务」展示。容器列表容忍状态缺失，因为它有行可依；这里没有。
      //
      // An exit status of 0 with no rows is *not* a failure: the remote said it
      // succeeded and listed nothing — `--all` can legitimately report no unit
      // on an unusual host — and inventing a failure out of the shape of the
      // output is the very heuristic this codebase removed.
      // 退出状态为 0 却没有行**不算**失败：远端说它成功了、什么也没列出——在少见的主机
      // 上 `--all` 合法地可能报不出任何单元；凭输出的形态编造失败，正是本代码库已经移除
      // 的那套启发式。
      if (!result.ok) {
        if (mounted) {
          setState(() {
            _loading = false;
            _error = '${t('list_failed')}: ${remoteFailureText(result)}';
          });
        }
        return;
      }
      // Parsed from `combined`: the exact bytes the old `executeCommand`-based
      // path handed the parser. This change adds the exit-status check; it does
      // not alter what the parser sees.
      // 解析输入为 `combined`：与旧的基于 `executeCommand` 的路径交给解析器的字节完全
      // 一致。本次改动增加的是退出状态判断，没有改变解析器看到的内容。
      final svcs = MonitoringService.parseSystemctl(result.combined);
      if (mounted) {
        setState(() {
          _services = svcs;
          _loading = false;
        });
        _apply();
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          // A command that failed because the session went away is translated;
          // anything else keeps its own technical text.
          // 因会话消失而失败的命令会被翻译；其它错误保留其技术文本。
          _error = sshCaughtErrorText(e);
        });
      }
    }
  }

  void _apply() {
    var list = List<Map<String, dynamic>>.from(_services);
    if (_searchQuery.isNotEmpty) {
      list = list
          .where(
            (s) =>
                (s['unit'] as String).toLowerCase().contains(
                  _searchQuery.toLowerCase(),
                ) ||
                (s['description'] as String).toLowerCase().contains(
                  _searchQuery.toLowerCase(),
                ),
          )
          .toList();
    }
    switch (_filter) {
      case 'Running':
        list = list.where(_isRunning).toList();
      case 'Failed':
        list = list.where(_isFailed).toList();
      case 'Inactive':
        list = list.where((s) => !_isRunning(s) && !_isFailed(s)).toList();
    }
    setState(() => _filtered = list);
  }

  /// The one snackbar shape this page shows.
  /// 本页唯一的提示条样式。
  void _snack(String message, Color color) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: color,
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.all(16),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
    );
  }

  /// The failure line for [actionLabel], carrying [reason] verbatim.
  /// [actionLabel] 的失败文案，原样带上 [reason]。
  String _failureMessage(String actionLabel, String reason) => t(
    'service_action_failed',
  ).replaceAll('{0}', actionLabel).replaceAll('{1}', reason);

  /// Runs one `systemctl` action and reports what the remote actually said.
  /// 执行一次 `systemctl` 操作，并汇报远端实际给出的结果。
  ///
  /// Success used to be assumed, because the exit status never reached the page:
  /// a non-root user stopping `docker.service` was told it had succeeded, while
  /// the remote had answered `Interactive authentication required.`
  /// 过去一律假设成功，因为退出状态根本没传到这里：非 root 用户停止
  /// `docker.service` 时会被告知成功，而远端回的是 `Interactive authentication
  /// required.`
  Future<void> _action(String unit, String action) async {
    final conn = _conn;
    if (conn == null) return;
    final cs = Theme.of(context).colorScheme;
    final actionLabel = _actionLabel(action);
    try {
      final result = await conn.runCommand('systemctl $action $unit');
      final failure = remoteActionFailure(result);
      if (mounted) {
        if (failure == null) {
          _snack(
            t(
              'service_action_success',
            ).replaceAll('{0}', unit).replaceAll('{1}', actionLabel),
            cs.primary,
          );
        } else {
          _snack(_failureMessage(actionLabel, failure), cs.error);
        }
      }
      // Refreshed after a failure too, unlike the container page: a failed
      // `systemctl restart` may still have stopped the unit.
      // 失败后同样刷新（与容器页不同）：失败的 `systemctl restart` 仍可能已经停掉了
      // 该单元。
      await _load();
    } catch (e) {
      // "SSH not connected" is the common one here — the session can go away
      // while this page is open — so it is translated like every other
      // connection failure rather than printed as a code.
      // 这里最常见的是「SSH 未连接」——本页打开期间会话可能消失——因此它像其它连接
      // 失败一样被翻译，而不是打印成编码。
      if (mounted) {
        _snack(_failureMessage(actionLabel, sshCaughtErrorText(e)), cs.error);
      }
    }
  }

  /// Opens [svc]'s action sheet; every action it reports is confirmed first.
  /// 打开 [svc] 的操作面板；它上报的每个操作都先经确认。
  void _openSheet(Map<String, dynamic> svc) {
    final unit = svc['unit'] as String;
    showSystemdActionSheet(
      context,
      svc: svc,
      onAction: (action) => _confirmAction(unit, action),
    );
  }

  Future<void> _confirmAction(String unit, String action) async {
    final actionLabel = _actionLabel(action);
    final confirmed = await showAppConfirmDialog(
      context,
      title: t('confirm'),
      message: t(
        'confirm_service_action',
      ).replaceAll('{0}', unit).replaceAll('{1}', actionLabel),
      cancelLabel: t('cancel'),
      confirmLabel: t('confirm'),
    );
    if (!confirmed) return;

    _action(unit, action);
  }

  String _actionLabel(String action) {
    switch (action) {
      case 'start':
        return t('systemd_start');
      case 'stop':
        return t('systemd_stop');
      case 'restart':
        return t('systemd_restart');
      case 'reload':
        return t('systemd_reload');
      case 'enable':
        return t('systemd_enable');
      case 'disable':
        return t('systemd_disable');
      default:
        return action;
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(
        leading: IconButton(
          icon: Icon(
            Icons.arrow_back,
            color: cs.onSurface.withValues(alpha: 0.7),
          ),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text(
          t('service_manager_title'),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 16),
        ),
        actions: [
          IconButton(
            icon: Icon(Icons.refresh, color: cs.primary),
            onPressed: _loading ? null : _load,
          ),
        ],
      ),
      body: _loading
          ? Center(child: CircularProgressIndicator(color: cs.primary))
          : _error != null
          ? Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(
                  horizontal: 32,
                  vertical: 24,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.error_outline, color: cs.error, size: 48),
                    const SizedBox(height: 12),
                    Text(
                      _error!,
                      maxLines: 6,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: cs.onSurface.withValues(alpha: 0.62),
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 16),
                    ElevatedButton.icon(
                      onPressed: _load,
                      icon: const Icon(Icons.refresh, size: 18),
                      label: Text(
                        t('retry'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: cs.primary,
                        foregroundColor: Colors.white,
                      ),
                    ),
                  ],
                ),
              ),
            )
          : Column(
              children: [
                // Stats bar
                SystemdStatsBar(
                  running: _running,
                  failed: _failed,
                  inactive: _inactive,
                  total: _services.length,
                ),
                // Search
                SystemdSearchField(
                  controller: _searchCtrl,
                  query: _searchQuery,
                  onChanged: (v) {
                    _searchQuery = v;
                    _apply();
                  },
                  onClear: () {
                    _searchCtrl.clear();
                    _searchQuery = '';
                    _apply();
                  },
                ),
                // Filter chips
                SystemdFilterChips(
                  total: _services.length,
                  running: _running,
                  failed: _failed,
                  inactive: _inactive,
                  selected: _filter,
                  onSelected: (v) {
                    _filter = v;
                    _apply();
                  },
                ),
                const SizedBox(height: 4),
                // Service list
                Expanded(
                  child: RefreshIndicator(
                    onRefresh: _load,
                    color: cs.primary,
                    child: _filtered.isEmpty
                        ? ListView(
                            children: [
                              const SizedBox(height: 100),
                              Center(
                                child: Text(
                                  t('no_matching_services'),
                                  style: TextStyle(
                                    color: cs.onSurface.withValues(alpha: 0.56),
                                  ),
                                ),
                              ),
                            ],
                          )
                        : ListView.builder(
                            itemCount: _filtered.length,
                            padding: const EdgeInsets.only(bottom: 20),
                            itemBuilder: (_, i) {
                              final svc = _filtered[i];
                              return SystemdServiceCard(
                                svc: svc,
                                onTap: () => _openSheet(svc),
                              );
                            },
                          ),
                  ),
                ),
              ],
            ),
    );
  }
}
