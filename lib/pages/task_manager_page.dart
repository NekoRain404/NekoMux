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

class TaskManagerPage extends ConsumerStatefulWidget {
  final Host host;
  const TaskManagerPage({super.key, required this.host});
  @override
  ConsumerState<TaskManagerPage> createState() => _TaskManagerPageState();
}

class _TaskManagerPageState extends ConsumerState<TaskManagerPage> {
  List<Map<String, dynamic>> _allProcesses = [];
  List<Map<String, dynamic>> _filtered = [];
  bool _loading = true;
  String? _error;
  SshConnection? _conn;
  String _sortBy = 'cpu';
  bool _sortAsc = false;
  final _searchCtrl = TextEditingController();
  String _searchQuery = '';

  void _showSnack(String message, {bool isError = false}) {
    final cs = Theme.of(context).colorScheme;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isError ? cs.error : cs.primary,
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.all(16),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
    );
  }

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

        // The process-manager connection is a real SSH session, so it has to
        // verify the host key like every other one: `dartssh2` accepts any key
        // when no callback is passed, which is exactly what a machine-in-the-
        // middle needs.
        // 进程管理连接是真实的 SSH 会话，必须和其它连接一样校验主机密钥：
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
      final result = await _conn!.runCommand('ps aux --sort=-%cpu | head -51');
      // A listing that failed must say so instead of rendering an empty list,
      // which used to be indistinguishable from "no processes" — the same
      // defect already fixed for `docker ps`, where a user outside the `docker`
      // group got an empty page instead of `permission denied`.
      // 失败的列表命令必须说明原因，而不是渲染一个空列表——过去它与「没有进程」无法
      // 区分，正是已在 `docker ps` 上修复过的同一类缺陷：不在 `docker` 组里的用户看到
      // 空页面，而不是 `permission denied`。
      //
      // `ok` means an exit status of exactly 0 and nothing else: a status the
      // server never reported is *unknown*, not success (see CommandResult.ok),
      // and for a listing whose whole answer is the row set, an unconfirmed read
      // must not be shown as "no processes". The container listing tolerates a
      // missing status because it has rows to fall back on; this one does not.
      // `ok` 仅指退出状态恰为 0：服务端从未上报的状态是**未知**而非成功
      // （见 CommandResult.ok）；对一个答案就是整份行集的列表来说，未经确认的读取不得
      // 当作「没有进程」展示。容器列表容忍状态缺失，因为它有行可依；这里没有。
      //
      // An exit status of 0 with no rows is *not* a failure: the remote said it
      // succeeded and listed nothing, and inventing a failure out of the shape of
      // the output is the very heuristic this codebase removed. It renders as the
      // existing empty state, like a filter that matched nothing.
      // 退出状态为 0 却没有行**不算**失败：远端说它成功了、什么也没列出；凭输出的形态
      // 编造失败，正是本代码库已经移除的那套启发式。它与筛不出任何结果一样，渲染为现有
      // 的空状态。
      //
      // The pipeline's status is the status of its last command (`head`), so a
      // missing `ps` binary still reports 0 here: that failure is invisible to
      // the exit status, and catching it would mean changing the command itself
      // (a `pipefail` guard is not portable across the shells a remote may run).
      // 这条管道的退出状态取最后一个命令（`head`）的状态，因此 `ps` 不存在时这里仍然是
      // 0：该失败对退出状态不可见，要发现它必须改动命令本身（`pipefail` 在远端可能运行
      // 的各种 shell 上并不通用）。
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
      final procs = MonitoringService.parsePs(result.combined);
      if (mounted) {
        setState(() {
          _allProcesses = procs;
          _loading = false;
        });
        _applyFilter();
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

  void _applyFilter() {
    var list = List<Map<String, dynamic>>.from(_allProcesses);
    if (_searchQuery.isNotEmpty) {
      list = list
          .where(
            (p) =>
                (p['command'] as String).toLowerCase().contains(
                  _searchQuery.toLowerCase(),
                ) ||
                (p['user'] as String).toLowerCase().contains(
                  _searchQuery.toLowerCase(),
                ),
          )
          .toList();
    }
    list.sort((a, b) {
      int cmp = 0;
      switch (_sortBy) {
        case 'cpu':
          cmp = (b['cpu'] as double).compareTo(a['cpu'] as double);
          break;
        case 'mem':
          cmp = (b['mem'] as double).compareTo(a['mem'] as double);
          break;
        case 'name':
          cmp = (a['command'] as String).toLowerCase().compareTo(
            (b['command'] as String).toLowerCase(),
          );
          break;
        default:
          cmp = (b['cpu'] as double).compareTo(a['cpu'] as double);
      }
      return _sortAsc ? -cmp : cmp;
    });
    setState(() => _filtered = list);
  }

  /// Kills one process and reports what the remote actually said.
  /// 终止一个进程，并汇报远端实际给出的结果。
  ///
  /// The row used to be removed and "killed" reported unconditionally: a
  /// non-root user killing a root process got
  /// `kill: (1) - Operation not permitted` from the remote, the row vanished
  /// anyway, and the process was still running.
  /// 过去无条件移除该行并提示「已终止」：非 root 用户终止 root 进程时远端返回
  /// `kill: (1) - Operation not permitted`，那一行照样消失，而进程其实还活着。
  Future<void> _killProcess(int pid) async {
    final conn = _conn;
    if (conn == null) return;
    try {
      final result = await conn.runCommand('kill -9 $pid');
      final failure = remoteActionFailure(result);
      if (failure != null) {
        /// The row stays: the process is still there, and removing it would be
        /// a claim the user only discovers to be false on the next refresh.
        /// 该行保留：进程仍在，移除它等于给出一个用户下次刷新才会发现是假的说法。
        ///
        /// `service_action_failed` is the table's only "«action» failed:
        /// «reason»" shape; a dedicated `kill_failed` key would read better but
        /// adding keys is out of scope here.
        /// `service_action_failed` 是表里唯一「«动作» 失败: «原因»」形态的键；
        /// 专用的 `kill_failed` 会更贴切，但本次不允许新增键。
        if (mounted) {
          _showSnack(
            t(
              'service_action_failed',
            ).replaceAll('{0}', t('kill_process')).replaceAll('{1}', failure),
            isError: true,
          );
        }
        return;
      }
      if (!mounted) return;
      setState(() {
        _allProcesses.removeWhere((p) => p['pid'] == pid);
        _applyFilter();
      });
      _showSnack(
        t('killed_pid').replaceAll('{0}', pid.toString()),
        isError: true,
      );
    } catch (e) {
      if (mounted) {
        // "SSH not connected" is the common one here — the session can go away
        // while this page is open — so it is translated like every other
        // connection failure rather than printed as a code.
        // 这里最常见的是「SSH 未连接」——本页打开期间会话可能消失——因此它像其它连接
        // 失败一样被翻译，而不是打印成编码。
        _showSnack('${t('error')}: ${sshCaughtErrorText(e)}', isError: true);
      }
    }
  }

  Future<void> _confirmKill(Map<String, dynamic> p) async {
    final pid = p['pid'] as int;
    final command = p['command'] as String;
    final confirmed = await showAppConfirmDialog(
      context,
      title: t('kill_process'),
      message: t(
        'confirm_kill_process',
      ).replaceAll('{0}', pid.toString()).replaceAll('{1}', command),
      cancelLabel: t('cancel'),
      confirmLabel: t('confirm'),
      destructive: true,
    );
    if (!confirmed) return;

    _killProcess(pid);
  }

  void _showDetail(Map<String, dynamic> p) {
    final cs = Theme.of(context).colorScheme;
    showModalBottomSheet(
      context: context,
      backgroundColor: cs.surface,
      showDragHandle: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(8)),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                p['command'] as String,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: cs.onSurface,
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  fontFamily: 'monospace',
                ),
                maxLines: 3,
              ),
              const SizedBox(height: 16),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _chip('PID', '${p['pid']}', cs.primary),
                  _chip('USER', p['user'] as String, cs.onSurfaceVariant),
                  _chip(
                    'CPU',
                    '${(p['cpu'] as double).toStringAsFixed(1)}%',
                    _usageColor(context, p['cpu'] as double),
                  ),
                  _chip(
                    'MEM',
                    '${(p['mem'] as double).toStringAsFixed(1)}%',
                    _usageColor(context, p['mem'] as double),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: () {
                    Navigator.pop(ctx);
                    _confirmKill(p);
                  },
                  icon: const Icon(Icons.close, size: 18, color: Colors.white),
                  label: Text(
                    t('kill_process_label'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white),
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: cs.error,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _chip(String label, String val, Color c) =>
      AppBadge(label: '$label: $val', color: c, maxWidth: 180);

  Color _usageColor(BuildContext context, double v) {
    final cs = Theme.of(context).colorScheme;
    if (v >= 50) return cs.error;
    if (v >= 10) return const Color(0xFFD29922);
    return cs.primary;
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
          t('process_manager_title'),
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
                // Search bar
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: TextField(
                    controller: _searchCtrl,
                    style: TextStyle(color: cs.onSurface, fontSize: 13),
                    decoration: InputDecoration(
                      hintText: t('search_processes'),
                      hintStyle: TextStyle(
                        color: cs.onSurface.withValues(alpha: 0.48),
                      ),
                      prefixIcon: Icon(
                        Icons.search,
                        color: cs.onSurface.withValues(alpha: 0.54),
                        size: 18,
                      ),
                      suffixIcon: _searchQuery.isNotEmpty
                          ? IconButton(
                              icon: Icon(
                                Icons.clear,
                                size: 16,
                                color: cs.onSurface.withValues(alpha: 0.54),
                              ),
                              onPressed: () {
                                _searchCtrl.clear();
                                _searchQuery = '';
                                _applyFilter();
                              },
                            )
                          : null,
                      filled: true,
                      fillColor: cs.surface,
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 10,
                      ),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: BorderSide(
                          color: Theme.of(context).dividerColor,
                        ),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: BorderSide(
                          color: Theme.of(context).dividerColor,
                        ),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: BorderSide(color: cs.primary),
                      ),
                    ),
                    onChanged: (v) {
                      _searchQuery = v;
                      _applyFilter();
                    },
                  ),
                ),

                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 8,
                  ),
                  color: cs.surface,
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          t(
                            'processes_count',
                          ).replaceAll('{0}', _filtered.length.toString()),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: cs.onSurface.withValues(alpha: 0.56),
                            fontSize: 11,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      _sortBtn('CPU', 'cpu'),
                      const SizedBox(width: 10),
                      _sortBtn('MEM', 'mem'),
                      const SizedBox(width: 10),
                      _sortBtn('NAME', 'name'),
                    ],
                  ),
                ),

                // Process list
                Expanded(
                  child: RefreshIndicator(
                    onRefresh: _load,
                    color: cs.primary,
                    child: _filtered.isEmpty
                        ? ListView(
                            children: [
                              const SizedBox(height: 120),
                              Center(
                                child: Text(
                                  t('no_matching_processes'),
                                  style: TextStyle(
                                    color: cs.onSurface.withValues(alpha: 0.56),
                                  ),
                                ),
                              ),
                            ],
                          )
                        : ListView.builder(
                            itemCount: _filtered.length,
                            padding: const EdgeInsets.only(top: 4),
                            itemBuilder: (_, i) => _buildRow(_filtered[i]),
                          ),
                  ),
                ),
              ],
            ),
    );
  }

  Widget _sortBtn(String label, String key) {
    final cs = Theme.of(context).colorScheme;
    final active = _sortBy == key;
    return GestureDetector(
      onTap: () {
        if (_sortBy == key) {
          _sortAsc = !_sortAsc;
        } else {
          _sortBy = key;
          _sortAsc = false;
        }
        _applyFilter();
      },
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: TextStyle(
              color: active ? cs.primary : cs.onSurface.withValues(alpha: 0.55),
              fontSize: 10,
              fontWeight: FontWeight.w600,
            ),
          ),
          if (active)
            Icon(
              _sortAsc ? Icons.arrow_upward : Icons.arrow_downward,
              size: 12,
              color: cs.primary,
            ),
        ],
      ),
    );
  }

  Widget _buildRow(Map<String, dynamic> p) {
    final cs = Theme.of(context).colorScheme;
    final cpu = p['cpu'] as double;
    final mem = p['mem'] as double;
    final cpuColor = _usageColor(context, cpu);
    final memColor = _usageColor(context, mem);
    final dividerColor = Theme.of(context).dividerColor;
    return AppCard(
      onTap: () => _showDetail(p),
      margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      borderColor: dividerColor.withValues(alpha: 0.6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 44,
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                decoration: BoxDecoration(
                  color: cs.onSurface.withValues(alpha: 0.06),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  '${p['pid']}',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: cs.onSurface.withValues(alpha: 0.56),
                    fontSize: 10,
                    fontFamily: 'monospace',
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  '${p['user']} · ${p['command']}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: cs.onSurface, fontSize: 13),
                ),
              ),
              const SizedBox(width: 4),
              Icon(
                Icons.chevron_right,
                color: cs.onSurface.withValues(alpha: 0.3),
                size: 16,
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: _usageBar(
                  label: 'CPU',
                  value: cpu,
                  color: cpuColor,
                  dividerColor: dividerColor,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _usageBar(
                  label: 'MEM',
                  value: mem,
                  color: memColor,
                  dividerColor: dividerColor,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _usageBar({
    required String label,
    required double value,
    required Color color,
    required Color dividerColor,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '$label ${value.toStringAsFixed(1)}%',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: color,
            fontSize: 10,
            fontWeight: FontWeight.w600,
            fontFamily: 'monospace',
          ),
        ),
        const SizedBox(height: 3),
        ClipRRect(
          borderRadius: BorderRadius.circular(2),
          child: LinearProgressIndicator(
            value: value / 100,
            minHeight: 3,
            backgroundColor: dividerColor.withValues(alpha: 0.45),
            valueColor: AlwaysStoppedAnimation(color),
          ),
        ),
      ],
    );
  }
}
