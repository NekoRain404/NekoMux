import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/i18n/strings.dart';
import '../models/host.dart';
import '../providers/providers.dart';
import '../services/monitoring_service.dart';
import '../services/ssh_service.dart';
import '../widgets/app_ui.dart';

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
        'systemctl list-units --type=service --all --no-pager --no-legend',
      );
      final svcs = MonitoringService.parseSystemctl(out);
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
          _error = e.toString();
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

  Future<void> _action(String unit, String action) async {
    if (_conn == null) return;
    final cs = Theme.of(context).colorScheme;
    final actionLabel = _actionLabel(action);
    try {
      await MonitoringService.exec(_conn!, 'systemctl $action $unit');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              t(
                'service_action_success',
              ).replaceAll('{0}', unit).replaceAll('{1}', actionLabel),
            ),
            backgroundColor: cs.primary,
            behavior: SnackBarBehavior.floating,
            margin: const EdgeInsets.all(16),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
          ),
        );
      }
      await _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              t(
                'service_action_failed',
              ).replaceAll('{0}', actionLabel).replaceAll('{1}', e.toString()),
            ),
            backgroundColor: cs.error,
            behavior: SnackBarBehavior.floating,
            margin: const EdgeInsets.all(16),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
          ),
        );
      }
    }
  }

  void _showSheet(Map<String, dynamic> svc) {
    final cs = Theme.of(context).colorScheme;
    final unit = svc['unit'] as String;
    final active = svc['active'] as String;
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
                unit,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: cs.onSurface,
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
                maxLines: 2,
              ),
              if ((svc['description'] as String).isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(
                  svc['description'] as String,
                  style: TextStyle(
                    color: cs.onSurface.withValues(alpha: 0.56),
                    fontSize: 12,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _chip(active, _stateColor(context, active)),
                  _chip(
                    svc['sub'] as String,
                    _stateColor(context, svc['sub'] as String),
                  ),
                  _chip(
                    svc['load'] as String,
                    cs.onSurface.withValues(alpha: 0.56),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              GridView.count(
                crossAxisCount: 3,
                mainAxisSpacing: 8,
                crossAxisSpacing: 8,
                childAspectRatio: 2.5,
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                children: [
                  _act(Icons.play_arrow, t('systemd_start'), cs.primary, () {
                    Navigator.pop(ctx);
                    _confirmAction(unit, 'start');
                  }),
                  _act(Icons.stop, t('systemd_stop'), cs.error, () {
                    Navigator.pop(ctx);
                    _confirmAction(unit, 'stop');
                  }),
                  _act(
                    Icons.restart_alt,
                    t('systemd_restart'),
                    const Color(0xFFD29922),
                    () {
                      Navigator.pop(ctx);
                      _confirmAction(unit, 'restart');
                    },
                  ),
                  _act(Icons.refresh, t('systemd_reload'), cs.primary, () {
                    Navigator.pop(ctx);
                    _confirmAction(unit, 'reload');
                  }),
                  _act(
                    Icons.check_circle_outline,
                    t('systemd_enable'),
                    cs.primary,
                    () {
                      Navigator.pop(ctx);
                      _confirmAction(unit, 'enable');
                    },
                  ),
                  _act(
                    Icons.block,
                    t('systemd_disable'),
                    cs.onSurface.withValues(alpha: 0.56),
                    () {
                      Navigator.pop(ctx);
                      _confirmAction(unit, 'disable');
                    },
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
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

  Widget _chip(String label, Color c) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
    decoration: BoxDecoration(
      color: c.withValues(alpha: 0.12),
      borderRadius: BorderRadius.circular(6),
      border: Border.all(color: c.withValues(alpha: 0.3)),
    ),
    child: Text(
      label,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(color: c, fontSize: 11, fontWeight: FontWeight.w600),
    ),
  );

  Widget _act(IconData icon, String label, Color c, VoidCallback fn) => InkWell(
    onTap: fn,
    borderRadius: BorderRadius.circular(8),
    child: Container(
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: c.withValues(alpha: 0.2)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, color: c, size: 18),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: c,
                fontSize: 10,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    ),
  );

  Color _stateColor(BuildContext context, String s) {
    final cs = Theme.of(context).colorScheme;
    switch (s.toLowerCase()) {
      case 'active':
      case 'running':
        return cs.primary;
      case 'failed':
        return cs.error;
      case 'activating':
      case 'reloading':
      case 'deactivating':
        return const Color(0xFFD29922);
      default:
        return cs.onSurface.withValues(alpha: 0.56);
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
                Container(
                  padding: const EdgeInsets.all(12),
                  color: cs.surface,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      Expanded(
                        child: _stat(t('filter_running'), _running, cs.primary),
                      ),
                      Expanded(
                        child: _stat(t('filter_failed'), _failed, cs.error),
                      ),
                      Expanded(
                        child: _stat(
                          t('filter_inactive'),
                          _inactive,
                          cs.onSurface.withValues(alpha: 0.56),
                        ),
                      ),
                      Expanded(
                        child: _stat(t('total'), _services.length, cs.primary),
                      ),
                    ],
                  ),
                ),
                // Search
                Padding(
                  padding: const EdgeInsets.all(10),
                  child: TextField(
                    controller: _searchCtrl,
                    style: TextStyle(color: cs.onSurface, fontSize: 13),
                    decoration: InputDecoration(
                      hintText: t('search_services'),
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
                                _apply();
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
                      _apply();
                    },
                  ),
                ),
                // Filter chips
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Row(
                    children: [
                      _filterChip(
                        'All',
                        t('filter_all'),
                        _services.length,
                        _filter == 'All',
                      ),
                      const SizedBox(width: 6),
                      _filterChip(
                        'Running',
                        t('filter_running'),
                        _running,
                        _filter == 'Running',
                      ),
                      const SizedBox(width: 6),
                      _filterChip(
                        'Failed',
                        t('filter_failed'),
                        _failed,
                        _filter == 'Failed',
                      ),
                      const SizedBox(width: 6),
                      _filterChip(
                        'Inactive',
                        t('filter_inactive'),
                        _inactive,
                        _filter == 'Inactive',
                      ),
                    ],
                  ),
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
                            itemBuilder: (_, i) => _card(_filtered[i]),
                          ),
                  ),
                ),
              ],
            ),
    );
  }

  Widget _stat(String label, int count, Color c) => Column(
    children: [
      Text(
        '$count',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(color: c, fontSize: 18, fontWeight: FontWeight.w700),
      ),
      Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: Theme.of(
            context,
          ).colorScheme.onSurface.withValues(alpha: 0.56),
          fontSize: 10,
        ),
      ),
    ],
  );

  Widget _filterChip(String value, String label, int count, bool active) {
    final cs = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: () {
        _filter = value;
        _apply();
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
        decoration: BoxDecoration(
          color: active
              ? cs.primary.withValues(alpha: 0.12)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
            color: active ? cs.primary : Theme.of(context).dividerColor,
            width: 0.5,
          ),
        ),
        child: Text(
          '$label $count',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: active ? cs.primary : cs.onSurface.withValues(alpha: 0.56),
            fontSize: 11,
            fontWeight: active ? FontWeight.w600 : FontWeight.normal,
          ),
        ),
      ),
    );
  }

  Widget _card(Map<String, dynamic> svc) {
    final cs = Theme.of(context).colorScheme;
    final active = svc['active'] as String;
    final ac = _stateColor(context, active);
    return AppCard(
      onTap: () => _showSheet(svc),
      margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      padding: const EdgeInsets.all(12),
      borderColor: ac.withValues(alpha: 0.7),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  svc['unit'] as String,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: cs.onSurface,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    fontFamily: 'monospace',
                  ),
                ),
                if ((svc['description'] as String).isNotEmpty) ...[
                  const SizedBox(height: 3),
                  Text(
                    svc['description'] as String,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: cs.onSurface.withValues(alpha: 0.56),
                      fontSize: 11,
                    ),
                  ),
                ],
                const SizedBox(height: 6),
                Wrap(
                  spacing: 5,
                  runSpacing: 3,
                  children: [
                    _tag(active, ac),
                    _tag(
                      svc['sub'] as String,
                      _stateColor(context, svc['sub'] as String),
                    ),
                    _tag(
                      svc['load'] as String,
                      cs.onSurface.withValues(alpha: 0.56),
                    ),
                  ],
                ),
              ],
            ),
          ),
          Icon(
            Icons.chevron_right,
            color: cs.onSurface.withValues(alpha: 0.3),
            size: 18,
          ),
        ],
      ),
    );
  }

  Widget _tag(String label, Color c) => AppBadge(label: label, color: c);
}
