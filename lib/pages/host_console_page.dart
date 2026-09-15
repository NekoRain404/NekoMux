import 'dart:async';
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/i18n/strings.dart';
import '../models/host.dart';
import '../providers/providers.dart';
import '../services/monitoring_service.dart';
import '../services/ssh_service.dart';
import '../widgets/resource_chart.dart';
import '../widgets/function_grid_tile.dart';
import '../widgets/app_ui.dart';
import 'ssh_terminal_page.dart';
import 'sftp_page.dart';
import 'task_manager_page.dart';
import 'systemd_page.dart';
import 'container_shell_page.dart';

/// Host detail console with real-time resource monitoring.
class HostConsolePage extends ConsumerStatefulWidget {
  final Host host;
  const HostConsolePage({super.key, required this.host});

  @override
  ConsumerState<HostConsolePage> createState() => _HostConsolePageState();
}

class _HostConsolePageState extends ConsumerState<HostConsolePage>
    with SingleTickerProviderStateMixin {
  late final List<FlSpot> _cpuData;
  late final List<FlSpot> _ramData;
  late final AnimationController _glowController;
  double _latestCpu = 0;
  double _latestRam = 0;

  SshConnection? _monitorConn;
  Timer? _pollTimer;
  bool _isLive = false;
  bool _connecting = false;
  String? _monitorError;
  bool _hasResourceSample = false;

  String _osInfo = '';
  String _hostname = '';
  CpuTimes? _lastCpuTimes;

  @override
  void initState() {
    super.initState();
    _glowController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat(reverse: true);

    _cpuData = List.generate(20, (i) => FlSpot(i.toDouble(), 0));
    _ramData = List.generate(20, (i) => FlSpot(i.toDouble(), 0));

    WidgetsBinding.instance.addPostFrameCallback((_) => _initMonitoring());
  }

  Future<void> _initMonitoring() async {
    if (_connecting) return;
    _connecting = true;

    final host = widget.host;
    try {
      final creds = await ref.read(credentialListProvider.future);
      final cred = creds.where((c) => c.id == host.credentialId).firstOrNull;

      if (cred == null) {
        _fallbackToMock(t('cred_not_found_fallback'));
        return;
      }

      _monitorConn = SshConnection(host: host, credential: cred);
      await _monitorConn!.connect();

      if (_monitorConn!.state != SshConnectionState.connected) {
        await ref.read(hostListProvider.notifier).setOnline(host.id, false);
        _fallbackToMock(
          _monitorConn!.lastError ?? t('cannot_connect_fallback'),
        );
        return;
      }

      await _fetchOsInfo();

      setState(() {
        _isLive = true;
        _connecting = false;
        _monitorError = null;
      });
      await ref.read(hostListProvider.notifier).setOnline(host.id, true);

      _pollOnce();
      _pollTimer = Timer.periodic(
        const Duration(seconds: 3),
        (_) => _pollOnce(),
      );
    } catch (e) {
      _fallbackToMock('${t('cannot_connect')}: $e');
    }
  }

  Future<void> _fetchOsInfo() async {
    if (_monitorConn == null) return;
    try {
      final uname = await MonitoringService.exec(_monitorConn!, 'uname -a');
      final osRelease = await MonitoringService.exec(
        _monitorConn!,
        'cat /etc/os-release 2>/dev/null | head -4',
      );
      final hostnameCmd = await MonitoringService.exec(
        _monitorConn!,
        'hostname',
      );

      String prettyName = '';
      for (final line in osRelease.split('\n')) {
        if (line.startsWith('PRETTY_NAME=')) {
          prettyName = line
              .replaceFirst('PRETTY_NAME=', '')
              .replaceAll('"', '')
              .trim();
        }
      }

      final kernel = uname.split(' ').sublist(0, 3).join(' ');

      if (mounted) {
        setState(() {
          _hostname = hostnameCmd.trim();
          _osInfo = prettyName.isNotEmpty ? '$prettyName\n$kernel' : kernel;
        });
      }
    } catch (_) {}
  }

  Future<void> _pollOnce() async {
    if (_monitorConn == null || !_isLive) return;
    try {
      // Use kernel counters instead of `top` text so CPU values are based on
      // sample deltas and stay stable across common Linux distributions.
      final statOut = await MonitoringService.exec(
        _monitorConn!,
        'cat /proc/stat | head -1',
      );
      final freeOut = await MonitoringService.exec(_monitorConn!, 'free -m');
      final currentCpuTimes = MonitoringService.parseProcStat(statOut);
      if (currentCpuTimes == null) return;

      final cpu = _lastCpuTimes == null
          ? _latestCpu
          : MonitoringService.cpuUsageBetween(_lastCpuTimes!, currentCpuTimes);
      final mem = MonitoringService.memoryUsagePercentFromFree(freeOut);
      _lastCpuTimes = currentCpuTimes;

      if (mounted) {
        setState(() {
          _latestCpu = cpu;
          _latestRam = mem;

          // Fill the chart with the first real sample. This avoids a misleading
          // flat zero line before the second polling tick arrives.
          if (!_hasResourceSample) {
            for (int i = 0; i < _cpuData.length; i++) {
              _cpuData[i] = FlSpot(i.toDouble(), _latestCpu);
              _ramData[i] = FlSpot(i.toDouble(), _latestRam);
            }
            _hasResourceSample = true;
            return;
          }

          // Shift values left while preserving fixed x coordinates. Rebuilding
          // with variable x values makes the chart jump and can hide the RAM line.
          for (int i = 0; i < _cpuData.length - 1; i++) {
            _cpuData[i] = FlSpot(i.toDouble(), _cpuData[i + 1].y);
            _ramData[i] = FlSpot(i.toDouble(), _ramData[i + 1].y);
          }
          final lastIndex = (_cpuData.length - 1).toDouble();
          _cpuData[_cpuData.length - 1] = FlSpot(lastIndex, _latestCpu);
          _ramData[_ramData.length - 1] = FlSpot(lastIndex, _latestRam);
        });
      }
    } catch (_) {}
  }

  void _fallbackToMock(String message) {
    if (!mounted) return;
    ref.read(hostListProvider.notifier).setOnline(widget.host.id, false);
    setState(() {
      _isLive = false;
      _connecting = false;
      _monitorError = message;
      _latestCpu = 0;
      _latestRam = 0;
      _lastCpuTimes = null;
      _hasResourceSample = false;
      _cpuData
        ..clear()
        ..addAll(List.generate(20, (i) => FlSpot(i.toDouble(), 0)));
      _ramData
        ..clear()
        ..addAll(List.generate(20, (i) => FlSpot(i.toDouble(), 0)));
    });
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _pollTimer = null;
    _monitorConn?.dispose();
    _monitorConn = null;
    _glowController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final host = widget.host;
    final messenger = ScaffoldMessenger.of(context);

    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      body: RefreshIndicator(
        onRefresh: () async {
          if (_isLive) {
            await _pollOnce();
          } else {
            await _retryMonitoring();
          }
          if (mounted) {
            messenger.showSnackBar(
              SnackBar(content: Text(t('resource_refreshed'))),
            );
          }
        },
        child: CustomScrollView(
          slivers: [
            _buildSliverAppBar(),
            SliverToBoxAdapter(child: _buildOsInfoHeader(host)),
            SliverToBoxAdapter(child: _buildResourceChart()),
            SliverToBoxAdapter(child: _buildFunctionGrid(host)),
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

  Widget _buildSliverAppBar() {
    final cs = Theme.of(context).colorScheme;
    return SliverAppBar(
      pinned: true,
      backgroundColor: cs.surface,
      leading: IconButton(
        icon: Icon(
          Icons.arrow_back,
          color: cs.onSurface.withValues(alpha: 0.7),
        ),
        onPressed: () => Navigator.pop(context),
      ),
      title: Row(
        children: [
          Flexible(
            child: Text(
              t('host_detail'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 10),
          if (_connecting)
            SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: cs.secondary,
              ),
            )
          else if (_isLive)
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 118),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: cs.primary.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: cs.primary.withValues(alpha: 0.3)),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.circle, size: 6, color: cs.primary),
                    const SizedBox(width: 4),
                    Flexible(
                      child: Text(
                        t('real_time_interval'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: cs.primary,
                          fontSize: 10,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            )
          else
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 118),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: cs.onSurface.withValues(alpha: 0.07),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  t('simulated_data'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: cs.onSurface.withValues(alpha: 0.6),
                    fontSize: 10,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ),
        ],
      ),
      actions: [
        IconButton(
          tooltip: t('refresh'),
          icon: Icon(
            Icons.refresh,
            color: cs.onSurface.withValues(alpha: 0.62),
          ),
          onPressed: () async {
            if (_isLive) {
              await _pollOnce();
            } else {
              await _retryMonitoring();
            }
          },
        ),
      ],
    );
  }

  Widget _buildOsInfoHeader(Host host) {
    final cs = Theme.of(context).colorScheme;
    return AppCard(
      margin: const EdgeInsets.all(16),
      padding: const EdgeInsets.all(16),
      child: Row(
        children: [
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              color: cs.primary.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Center(
              child: Text(
                Host.getOsLogoChar(host.osType),
                style: const TextStyle(fontSize: 28),
              ),
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  host.alias,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: cs.onSurface,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  _hostname.isNotEmpty ? _hostname : host.displayAddress,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: cs.onSurface.withValues(alpha: 0.48),
                    fontSize: 12,
                  ),
                ),
                if (_osInfo.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    _osInfo,
                    style: TextStyle(
                      color: cs.onSurface.withValues(alpha: 0.36),
                      fontSize: 10,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
                const SizedBox(height: 4),
                Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  children: [
                    _statusChip(
                      _isLive ? t('running') : t('offline_status'),
                      _isLive ? cs.primary : cs.error,
                    ),
                    _statusChip('SSH :${host.port}', cs.secondary),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _statusChip(String label, Color color) {
    return AppBadge(label: label, color: color);
  }

  Widget _buildResourceChart() {
    final cs = Theme.of(context).colorScheme;
    final dividerColor = Theme.of(context).dividerColor;
    final cpuColor = cs.secondary;
    final ramColor = cs.primary;
    final showUnavailable = !_isLive && !_connecting && _monitorError != null;
    final showGlow = !showUnavailable && (_latestCpu >= 85 || _latestRam >= 85);

    return AnimatedBuilder(
      animation: _glowController,
      builder: (context, child) {
        final glowOpacity = showGlow
            ? 0.15 + (_glowController.value * 0.30)
            : 0.0;

        return Container(
          margin: const EdgeInsets.symmetric(horizontal: 16),
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: cs.surface,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: dividerColor, width: 0.5),
            boxShadow: showGlow
                ? [
                    BoxShadow(
                      color: cs.error.withValues(alpha: glowOpacity),
                      blurRadius: 16,
                      spreadRadius: 2,
                    ),
                  ]
                : [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.12),
                      blurRadius: 10,
                      offset: const Offset(0, 3),
                    ),
                  ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.show_chart, color: cs.secondary, size: 18),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      t('resource_monitor'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: cs.onSurface,
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  if (_isLive)
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 128),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: cs.primary.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          t('real_time_interval'),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: cs.primary,
                            fontSize: 10,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                    )
                  else if (showUnavailable)
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 128),
                      child: Text(
                        t('simulated_data'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: cs.error,
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    )
                  else
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 128),
                      child: Text(
                        t('recent_samples'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: cs.onSurface.withValues(alpha: 0.36),
                          fontSize: 11,
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  _legend('CPU', cpuColor),
                  const SizedBox(width: 16),
                  _legend('RAM', ramColor),
                ],
              ),
              const SizedBox(height: 8),
              Stack(
                children: [
                  ResourceChart(
                    cpuData: _cpuData,
                    ramData: _ramData,
                    cpuColor: cpuColor,
                    ramColor: ramColor,
                  ),
                  if (showUnavailable)
                    Positioned.fill(
                      child: _MonitorUnavailableOverlay(
                        message: _monitorError!,
                        onRetry: _retryMonitoring,
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  _usageText('CPU', _latestCpu, cpuColor),
                  _usageText('RAM', _latestRam, ramColor),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _retryMonitoring() async {
    _pollTimer?.cancel();
    _pollTimer = null;
    _monitorConn?.dispose();
    _monitorConn = null;
    if (mounted) {
      setState(() {
        _monitorError = null;
        _connecting = false;
        _isLive = false;
        _lastCpuTimes = null;
        _hasResourceSample = false;
      });
    }
    await _initMonitoring();
  }

  Widget _usageText(String label, double value, Color color) {
    final cs = Theme.of(context).colorScheme;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 6),
        Text(
          '$label ',
          style: TextStyle(
            color: cs.onSurface.withValues(alpha: 0.6),
            fontSize: 12,
          ),
        ),
        Text(
          '${value.toStringAsFixed(1)}%',
          style: TextStyle(
            color: color,
            fontSize: 13,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }

  Widget _legend(String label, Color color) {
    final cs = Theme.of(context).colorScheme;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        const SizedBox(width: 4),
        Text(
          label,
          style: TextStyle(
            color: cs.onSurface.withValues(alpha: 0.6),
            fontSize: 11,
          ),
        ),
      ],
    );
  }

  Widget _buildFunctionGrid(Host host) {
    final cs = Theme.of(context).colorScheme;
    final mutedPurple = Color.lerp(cs.primary, cs.secondary, 0.55)!;
    final warmAccent = Color.lerp(cs.error, cs.secondary, 0.35)!;
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 12),
            child: Text(
              t('function_modules'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: cs.onSurface,
                fontSize: 15,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          GridView.count(
            crossAxisCount: 2,
            mainAxisSpacing: 12,
            crossAxisSpacing: 12,
            childAspectRatio: 1.35,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            children: [
              FunctionGridTile(
                icon: Icons.terminal,
                iconColor: cs.primary,
                title: t('terminal'),
                subtitle: 'SSH ${host.port}',
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => SshTerminalPage(host: host),
                  ),
                ),
              ),
              FunctionGridTile(
                icon: Icons.folder_outlined,
                iconColor: cs.secondary,
                title: t('file_manager'),
                subtitle: t('sftp_protocol'),
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => SftpPage(host: host)),
                ),
              ),
              FunctionGridTile(
                icon: Icons.memory,
                iconColor: mutedPurple,
                title: t('process_manager'),
                subtitle: t('task_manager'),
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => TaskManagerPage(host: host),
                  ),
                ),
              ),
              FunctionGridTile(
                icon: Icons.miscellaneous_services,
                iconColor: warmAccent,
                title: t('service_manager'),
                subtitle: 'systemd',
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => SystemdPage(host: host)),
                ),
              ),
              FunctionGridTile(
                icon: Icons.dashboard_outlined,
                iconColor: cs.secondary,
                title: t('containers'),
                subtitle: t('docker'),
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => ContainerShellPage(host: host),
                  ),
                ),
              ),
              FunctionGridTile(
                icon: Icons.desktop_windows_outlined,
                iconColor: cs.onSurface.withValues(alpha: 0.42),
                title: t('remote_desktop'),
                subtitle: t('vnc'),
                enabled: false,
                badge: t('soon_badge'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _MonitorUnavailableOverlay extends StatelessWidget {
  final String message;
  final Future<void> Function() onRetry;

  const _MonitorUnavailableOverlay({
    required this.message,
    required this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: cs.surface.withValues(alpha: 0.94),
        borderRadius: BorderRadius.circular(8),
      ),
      padding: const EdgeInsets.all(18),
      child: Center(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.cloud_off_outlined, color: cs.error, size: 32),
              const SizedBox(height: 10),
              Text(
                t('simulated_data'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: cs.onSurface,
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                message,
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: cs.onSurface.withValues(alpha: 0.66),
                  fontSize: 12,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                t('monitor_unavailable_hint'),
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: cs.onSurface.withValues(alpha: 0.52),
                  fontSize: 11,
                ),
              ),
              const SizedBox(height: 14),
              FilledButton.icon(
                onPressed: () => onRetry(),
                icon: const Icon(Icons.refresh, size: 18),
                label: Text(
                  t('retry'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
