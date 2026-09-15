import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/i18n/strings.dart';
import '../models/host.dart';
import '../providers/providers.dart';
import '../services/monitoring_service.dart';
import '../services/ssh_service.dart';
import '../widgets/app_ui.dart';

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
        _conn = SshConnection(host: host, credential: cred);
        await _conn!.connect();
        if (_conn!.state != SshConnectionState.connected) {
          setState(() {
            _loading = false;
            _error = _conn!.lastError ?? t('connection_failed');
          });
          return;
        }
      }
      final out = await MonitoringService.exec(
        _conn!,
        'ps aux --sort=-%cpu | head -51',
      );
      final procs = MonitoringService.parsePs(out);
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
          _error = e.toString();
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

  Future<void> _killProcess(int pid) async {
    if (_conn == null) return;
    try {
      await MonitoringService.exec(_conn!, 'kill -9 $pid');
      setState(() {
        _allProcesses.removeWhere((p) => p['pid'] == pid);
        _applyFilter();
      });
      if (mounted) {
        _showSnack(
          t('killed_pid').replaceAll('{0}', pid.toString()),
          isError: true,
        );
      }
    } catch (e) {
      if (mounted) {
        _showSnack('${t('error')}: $e', isError: true);
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
