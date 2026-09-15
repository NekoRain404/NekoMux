import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import '../core/i18n/strings.dart';
import '../models/host.dart';
import '../models/credential.dart';
import '../providers/providers.dart';
import '../services/ssh_service.dart';
import '../widgets/app_ui.dart';

/// Real Docker container management page using SSH-based Docker commands.
/// 基于 SSH 执行真实 Docker 命令的容器管理页面。
class ContainerShellPage extends ConsumerStatefulWidget {
  /// Target host to connect to for Docker management.
  /// 用于 Docker 管理的目标主机。
  final Host host;

  const ContainerShellPage({super.key, required this.host});

  @override
  ConsumerState<ContainerShellPage> createState() => _ContainerShellPageState();
}

/// Private state managing SSH connection, container listing, and lifecycle actions.
/// 私有状态，管理 SSH 连接、容器列表和生命周期操作。
class _ContainerShellPageState extends ConsumerState<ContainerShellPage> {
  bool _isLoading = true;
  bool _isRefreshing = false;
  String? _error;
  List<_DockerContainer> _containers = [];
  SshConnection? _ssh;
  Credential? _credential;

  @override
  void initState() {
    super.initState();
    _connectAndFetch();
  }

  @override
  void dispose() {
    _ssh?.disconnect();
    _ssh?.dispose();
    super.dispose();
  }

  /// Establish SSH connection and fetch the initial container list.
  /// 建立 SSH 连接并获取初始容器列表。
  Future<void> _connectAndFetch() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      /// Resolve the credential associated with this host.
      /// 解析与此主机关联的凭据。
      final credsAsync = ref.read(credentialListProvider);
      final creds = credsAsync.value ?? [];
      _credential = creds
          .where((c) => c.id == widget.host.credentialId)
          .firstOrNull;

      if (_credential == null) {
        if (mounted) {
          setState(() {
            _isLoading = false;
            _error = t('credential_not_found');
          });
        }
        return;
      }

      /// Dispose any existing connection before creating a new one.
      /// 在创建新连接之前释放任何现有连接。
      _ssh?.dispose();
      _ssh = SshConnection(host: widget.host, credential: _credential!);
      await _ssh!.connect();

      if (_ssh!.state != SshConnectionState.connected) {
        if (mounted) {
          setState(() {
            _isLoading = false;
            _error = _ssh!.lastError ?? t('conn_failed');
          });
        }
        return;
      }

      await _fetchContainers();
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _error = e.toString();
        });
      }
    }
  }

  /// Execute `docker ps -a` via SSH and parse the pipe-delimited output.
  /// 通过 SSH 执行 `docker ps -a` 并解析管道分隔的输出。
  Future<void> _fetchContainers() async {
    if (_ssh == null || _ssh!.state != SshConnectionState.connected) {
      setState(() {
        _isLoading = false;
        _isRefreshing = false;
        _error = t('ssh_not_connected');
      });
      return;
    }

    try {
      final output = await _ssh!.executeCommand(
        "docker ps -a --format '{{.ID}}|{{.Image}}|{{.Names}}|{{.Status}}|{{.Ports}}|{{.RunningFor}}' 2>&1",
      );

      /// If the output suggests Docker isn't installed, show a helpful message.
      /// 如果输出表明未安装 Docker，显示帮助信息。
      if (output.contains('not found') ||
          output.contains('command not found') ||
          output.contains('docker: command')) {
        if (mounted) {
          setState(() {
            _isLoading = false;
            _isRefreshing = false;
            _error = t('docker_not_installed');
          });
        }
        return;
      }

      _containers = _parseDockerOutput(output);
      if (mounted) {
        setState(() {
          _isLoading = false;
          _isRefreshing = false;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _isRefreshing = false;
          _error = '${t('fetch_containers_failed')}: $e';
        });
      }
    }
  }

  /// Parse the pipe-delimited Docker CLI output into container objects.
  /// 将管道分隔的 Docker CLI 输出解析为容器对象。
  List<_DockerContainer> _parseDockerOutput(String output) {
    final containers = <_DockerContainer>[];
    final lines = output.trim().split('\n');

    for (final line in lines) {
      if (line.trim().isEmpty) continue;
      final parts = line.split('|');
      if (parts.length < 6) continue;

      final id = parts[0].trim();
      final image = parts[1].trim();
      final name = parts[2].trim();
      final statusRaw = parts[3].trim();
      final ports = parts[4].trim();
      final runningFor = parts[5].trim();

      /// Parse status: "Up X hours" / "Up 3 days" = running, "Exited (0)..." = stopped.
      /// 解析状态："Up X hours" / "Up 3 days" = 运行中，"Exited (0)..." = 已停止。
      final isRunning = statusRaw.startsWith('Up ');
      final statusText = isRunning
          ? t('container_running')
          : t('container_stopped');
      final uptime = isRunning ? runningFor : '-';

      containers.add(
        _DockerContainer(
          id: id,
          name: name,
          image: image,
          isRunning: isRunning,
          statusText: statusText,
          statusRaw: statusRaw,
          uptime: uptime,
          ports: ports,
        ),
      );
    }

    return containers;
  }

  /// Execute a Docker lifecycle command (start/stop/restart/remove) via SSH.
  /// 通过 SSH 执行 Docker 生命周期命令（启动/停止/重启/删除）。
  Future<bool> _executeDockerCommand(String command, String successMsg) async {
    if (_ssh == null || _ssh!.state != SshConnectionState.connected) {
      _showToast(t('ssh_not_connected'), isError: true);
      return false;
    }

    try {
      final result = await _ssh!.executeCommand('$command 2>&1');
      if (result.contains('Error') || result.contains('error')) {
        if (mounted) {
          _showToast('${t('container_action_failed')}: $result', isError: true);
        }
        return false;
      }
      if (mounted) _showToast(successMsg);
      return true;
    } catch (e) {
      if (mounted) {
        _showToast('${t('container_action_failed')}: $e', isError: true);
      }
      return false;
    }
  }

  /// Pull-to-refresh handler — re-fetches the container list.
  /// 下拉刷新处理 — 重新获取容器列表。
  Future<void> _onRefresh() async {
    setState(() => _isRefreshing = true);
    HapticFeedback.mediumImpact();

    /// If disconnected, try to reconnect first.
    /// 如果连接断开，先尝试重连。
    if (_ssh == null || _ssh!.state != SshConnectionState.connected) {
      if (mounted) _showToast(t('reconnecting'));
      await _connectAndFetch();
    } else {
      await _fetchContainers();
    }

    if (mounted) setState(() => _isRefreshing = false);
  }

  /// Shows a bottom sheet with container actions: start/stop/restart, logs, shell, remove.
  /// 显示底部操作弹窗，包含启动/停止/重启、日志、Shell、删除操作。
  void _showContainerActions(_DockerContainer container) {
    final cs = Theme.of(context).colorScheme;
    HapticFeedback.lightImpact();
    final isRunning = container.isRunning;

    showModalBottomSheet(
      context: context,
      backgroundColor: cs.surface,
      showDragHandle: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(8)),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                container.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: GoogleFonts.jetBrainsMono(
                  color: cs.onSurface,
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                container.image,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: cs.onSurface.withValues(alpha: 0.6),
                  fontSize: 12,
                ),
              ),
              const SizedBox(height: 16),

              /// Action buttons row. /// 操作按钮行。
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Wrap(
                  alignment: WrapAlignment.center,
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    if (!isRunning)
                      _ActionButton(
                        icon: Icons.play_arrow,
                        label: t('start'),
                        color: cs.primary,
                        onTap: () async {
                          Navigator.pop(ctx);
                          final ok = await _executeDockerCommand(
                            'docker start ${container.name}',
                            t('container_start_success'),
                          );
                          if (ok) await _fetchContainers();
                        },
                      ),
                    if (isRunning)
                      _ActionButton(
                        icon: Icons.stop,
                        label: t('stop'),
                        color: cs.error,
                        onTap: () async {
                          Navigator.pop(ctx);
                          final ok = await _executeDockerCommand(
                            'docker stop ${container.name}',
                            t('container_stop_success'),
                          );
                          if (ok) await _fetchContainers();
                        },
                      ),
                    _ActionButton(
                      icon: Icons.restart_alt,
                      label: t('restart'),
                      color: cs.secondary,
                      onTap: () async {
                        Navigator.pop(ctx);
                        final ok = await _executeDockerCommand(
                          'docker restart ${container.name}',
                          t('container_restart_success'),
                        );
                        if (ok) await _fetchContainers();
                      },
                    ),
                    _ActionButton(
                      icon: Icons.delete_outline,
                      label: t('remove_container'),
                      color: cs.error,
                      onTap: () {
                        Navigator.pop(ctx);
                        _confirmRemoveContainer(container);
                      },
                    ),
                  ],
                ),
              ),

              Divider(height: 32, color: Theme.of(context).dividerColor),

              AppCard(
                margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
                onTap: () {
                  Navigator.pop(ctx);
                  _showLogDialog(container);
                },
                child: Row(
                  children: [
                    Icon(
                      Icons.article_outlined,
                      color: cs.onSurface.withValues(alpha: 0.6),
                      size: 22,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        t('logs'),
                        style: TextStyle(color: cs.onSurface, fontSize: 14),
                      ),
                    ),
                    Icon(
                      Icons.chevron_right,
                      color: cs.onSurface.withValues(alpha: 0.6),
                      size: 20,
                    ),
                  ],
                ),
              ),

              AppCard(
                margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
                color: cs.onSurface.withValues(alpha: 0.04),
                borderColor: Theme.of(
                  context,
                ).dividerColor.withValues(alpha: 0.5),
                child: Row(
                  children: [
                    Icon(
                      Icons.terminal,
                      color: cs.onSurface.withValues(alpha: 0.34),
                      size: 22,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        t('container_shell'),
                        style: TextStyle(
                          color: cs.onSurface.withValues(alpha: 0.46),
                          fontSize: 14,
                        ),
                      ),
                    ),
                    AppBadge(
                      label: t('soon_badge'),
                      color: cs.onSurface.withValues(alpha: 0.42),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }

  /// Shows a confirmation dialog before removing a container.
  /// 删除容器前显示确认对话框。
  Future<void> _confirmRemoveContainer(_DockerContainer container) async {
    final confirmed = await showAppConfirmDialog(
      context,
      title: t('remove_container'),
      message: t('confirm_remove_container').replaceAll('{0}', container.name),
      cancelLabel: t('cancel'),
      confirmLabel: t('delete'),
      destructive: true,
    );
    if (!confirmed) return;

    final ok = await _executeDockerCommand(
      'docker rm -f ${container.name}',
      t('container_remove_success'),
    );
    if (ok) await _fetchContainers();
  }

  /// Shows a dialog with real container logs fetched via SSH.
  /// 显示通过 SSH 获取的真实容器日志的对话框。
  void _showLogDialog(_DockerContainer container) async {
    final cs = Theme.of(context).colorScheme;

    final terminalBg = cs.onSurface.withValues(alpha: 0.06);

    /// Show a loading dialog first while fetching logs.
    /// 首先显示加载对话框，同时获取日志。
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: cs.surface,
        title: Text(
          '${container.name} - ${t('logs')}',
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: GoogleFonts.jetBrainsMono(color: cs.onSurface, fontSize: 15),
        ),
        content: SizedBox(
          width: double.maxFinite,
          height: 300,
          child: Center(child: CircularProgressIndicator(color: cs.primary)),
        ),
      ),
    );

    String logText;
    try {
      if (_ssh != null && _ssh!.state == SshConnectionState.connected) {
        logText = await _ssh!.executeCommand(
          'docker logs --tail 50 ${container.name} 2>&1',
        );
        if (logText.isEmpty) logText = '(no output)';
      } else {
        logText = t('ssh_not_connected');
      }
    } catch (e) {
      logText = '${t('error')}: $e';
    }

    /// Dismiss loading dialog and show logs.
    /// 关闭加载对话框并显示日志。
    if (mounted) Navigator.pop(context);

    if (mounted) {
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: cs.surface,
          title: Row(
            children: [
              Expanded(
                child: Text(
                  '${container.name} - ${t('logs')}',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.jetBrainsMono(
                    color: cs.onSurface,
                    fontSize: 15,
                  ),
                ),
              ),
              IconButton(
                icon: Icon(
                  Icons.copy,
                  color: cs.onSurface.withValues(alpha: 0.6),
                  size: 18,
                ),
                tooltip: t('copy'),
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: logText));
                  _showToast(t('copied'));
                },
              ),
            ],
          ),
          content: SizedBox(
            width: double.maxFinite,
            height: 300,
            child: Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: terminalBg,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: Theme.of(context).dividerColor.withValues(alpha: 0.7),
                ),
              ),
              child: SingleChildScrollView(
                child: SelectableText(
                  logText,
                  style: GoogleFonts.jetBrainsMono(
                    color: cs.onSurface,
                    fontSize: 11,
                    height: 1.6,
                  ),
                ),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(t('close'), style: TextStyle(color: cs.secondary)),
            ),
          ],
        ),
      );
    }
  }

  /// Displays a brief toast message at the bottom of the screen.
  /// 在屏幕底部显示简短提示消息。
  void _showToast(String message, {bool isError = false}) {
    if (!mounted) return;
    final cs = Theme.of(context).colorScheme;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isError ? cs.error : cs.primary,
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 2),
        margin: const EdgeInsets.fromLTRB(16, 0, 16, 80),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
    );
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
          t('containers'),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          /// Refresh action button. /// 刷新操作按钮。
          IconButton(
            icon: Icon(
              _isRefreshing ? Icons.sync : Icons.refresh,
              color: cs.onSurface.withValues(alpha: 0.6),
              size: 22,
            ),
            tooltip: t('refresh'),
            onPressed: _isRefreshing ? null : _onRefresh,
          ),
        ],
      ),
      body: _buildBody(),
    );
  }

  /// Builds the main body content based on current state.
  /// 根据当前状态构建主体内容。
  Widget _buildBody() {
    final cs = Theme.of(context).colorScheme;

    /// Loading state. /// 加载状态。
    if (_isLoading) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(color: cs.primary),
            const SizedBox(height: 16),
            Text(
              t('loading_containers'),
              style: TextStyle(
                color: cs.onSurface.withValues(alpha: 0.6),
                fontSize: 14,
              ),
            ),
          ],
        ),
      );
    }

    /// Error state with retry and reconnect buttons. /// 错误状态，带重试和重连按钮。
    if (_error != null) {
      return Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.error_outline, color: cs.error, size: 48),
              const SizedBox(height: 16),
              Text(
                _error!,
                textAlign: TextAlign.center,
                maxLines: 6,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: cs.onSurface.withValues(alpha: 0.6),
                  fontSize: 14,
                ),
              ),
              const SizedBox(height: 24),
              Wrap(
                alignment: WrapAlignment.center,
                spacing: 12,
                runSpacing: 10,
                children: [
                  OutlinedButton.icon(
                    onPressed: _connectAndFetch,
                    icon: const Icon(Icons.link, size: 18),
                    label: Text(
                      t('reconnect'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: cs.secondary,
                      side: BorderSide(color: cs.secondary),
                    ),
                  ),
                  OutlinedButton.icon(
                    onPressed: _fetchContainers,
                    icon: const Icon(Icons.refresh, size: 18),
                    label: Text(
                      t('retry'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: cs.primary,
                      side: BorderSide(color: cs.primary),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      );
    }

    /// Empty state — no containers found. /// 空状态 — 未找到容器。
    if (_containers.isEmpty) {
      return RefreshIndicator(
        color: cs.primary,
        backgroundColor: cs.surface,
        onRefresh: _onRefresh,
        child: ListView(
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 120),
              child: Center(
                child: Column(
                  children: [
                    AppIconBox(
                      icon: Icons.inventory_2_outlined,
                      color: cs.primary,
                      size: 64,
                    ),
                    const SizedBox(height: 16),
                    Text(
                      t('no_containers'),
                      textAlign: TextAlign.center,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: cs.onSurface.withValues(alpha: 0.6),
                        fontSize: 16,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      t('no_containers_hint'),
                      textAlign: TextAlign.center,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: cs.onSurface.withValues(alpha: 0.56),
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 24),
            _buildAddContainerNotice(),
          ],
        ),
      );
    }

    /// Container list with pull-to-refresh. /// 容器列表，带下拉刷新。
    return RefreshIndicator(
      color: cs.primary,
      backgroundColor: cs.surface,
      onRefresh: _onRefresh,
      child: ListView.builder(
        padding: const EdgeInsets.symmetric(vertical: 8),
        itemCount: _containers.length + 1,
        itemBuilder: (context, index) {
          if (index == _containers.length) {
            return _buildAddContainerNotice();
          }
          final container = _containers[index];
          return _buildContainerCard(container);
        },
      ),
    );
  }

  Widget _buildAddContainerNotice() {
    final cs = Theme.of(context).colorScheme;
    return AppCard(
      margin: const EdgeInsets.fromLTRB(14, 8, 14, 20),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      color: cs.onSurface.withValues(alpha: 0.035),
      borderColor: Theme.of(context).dividerColor.withValues(alpha: 0.5),
      child: Row(
        children: [
          AppIconBox(
            icon: Icons.add_box_outlined,
            color: cs.onSurface.withValues(alpha: 0.34),
            size: 36,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              t('container_add_coming_soon'),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: cs.onSurface.withValues(alpha: 0.52),
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          AppBadge(
            label: t('soon_badge'),
            color: cs.onSurface.withValues(alpha: 0.42),
          ),
        ],
      ),
    );
  }

  /// Builds a container status card with name, image, status dot, uptime, and ports.
  /// 构建容器状态卡片，显示名称、镜像、状态圆点、运行时间和端口映射。
  Widget _buildContainerCard(_DockerContainer container) {
    final cs = Theme.of(context).colorScheme;
    final isRunning = container.isRunning;
    final statusColor = isRunning ? cs.primary : cs.error;

    return AppCard(
      margin: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
      padding: const EdgeInsets.all(14),
      onTap: () => _showContainerActions(container),
      borderColor: Theme.of(context).dividerColor.withValues(alpha: 0.5),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          /// Row 1: container name + status dot. /// 第一行：容器名称 + 状态圆点。
          Row(
            children: [
              Expanded(
                child: Text(
                  container.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.jetBrainsMono(
                    color: cs.onSurface,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: statusColor,
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: statusColor.withValues(alpha: 0.5),
                      blurRadius: 4,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 6),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 120),
                child: Text(
                  container.statusText,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: statusColor,
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ],
          ),

          const SizedBox(height: 8),

          /// Row 2: image name. /// 第二行：镜像名称。
          Row(
            children: [
              Icon(
                Icons.layers_outlined,
                color: cs.onSurface.withValues(alpha: 0.6),
                size: 14,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  container.image,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: cs.onSurface.withValues(alpha: 0.6),
                    fontSize: 12,
                  ),
                ),
              ),
            ],
          ),

          const SizedBox(height: 6),

          /// Row 3: uptime. /// 第三行：运行时间。
          Row(
            children: [
              Icon(
                Icons.timer_outlined,
                color: cs.onSurface.withValues(alpha: 0.6),
                size: 14,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  '${t('container_uptime')}: ${container.uptime}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: cs.onSurface.withValues(alpha: 0.6),
                    fontSize: 12,
                  ),
                ),
              ),
            ],
          ),

          const SizedBox(height: 6),

          /// Row 4: port mapping (if any). /// 第四行：端口映射（如有）。
          if (container.ports.isNotEmpty)
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  Icons.settings_ethernet,
                  color: cs.onSurface.withValues(alpha: 0.6),
                  size: 14,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    container.ports,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: cs.secondary.withValues(alpha: 0.8),
                      fontSize: 11,
                      fontFamily: 'monospace',
                    ),
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }
}

/// Data class for a real Docker container parsed from CLI output.
/// 从 CLI 输出解析的真实 Docker 容器数据类。
class _DockerContainer {
  final String id;
  final String name;
  final String image;
  final bool isRunning;
  final String statusText;
  final String statusRaw;
  final String uptime;
  final String ports;

  const _DockerContainer({
    required this.id,
    required this.name,
    required this.image,
    required this.isRunning,
    required this.statusText,
    required this.statusRaw,
    required this.uptime,
    required this.ports,
  });
}

/// A compact action button used in the bottom sheet.
/// 底部弹窗中使用的紧凑操作按钮。
class _ActionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;

  const _ActionButton({
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () {
        HapticFeedback.lightImpact();
        onTap();
      },
      borderRadius: BorderRadius.circular(8),
      child: Container(
        width: 72,
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: color.withValues(alpha: 0.3), width: 0.5),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: color, size: 24),
            const SizedBox(height: 4),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: color,
                fontSize: 11,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
