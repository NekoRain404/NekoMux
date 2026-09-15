import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/haptics.dart';
import '../core/i18n/strings.dart';
import '../models/host.dart';
import '../models/credential.dart';
import '../providers/providers.dart';
import '../providers/settings_provider.dart';
import '../providers/ssh_provider.dart';
import '../services/host_key_trust.dart';
import '../services/ssh_service.dart';
import '../widgets/app_ui.dart';
import '../widgets/host_key_prompt.dart';
import 'containers/container_action_sheet.dart';
import 'containers/container_cards.dart';
import 'containers/container_log_dialog.dart';
import 'containers/docker_commands.dart';
import 'containers/docker_container.dart';
import 'containers/remote_action_outcome.dart';

/// Real Docker container management page using SSH-based Docker commands.
/// 基于 SSH 执行真实 Docker 命令的容器管理页面。
///
/// The page owns the connection and the container list, and nothing else: the
/// command layer, the card, the action sheet and the log viewer live under
/// `pages/containers/`.
/// 本页只负责连接与容器列表：命令层、卡片、操作面板与日志查看器都在
/// `pages/containers/` 下。
class ContainerShellPage extends ConsumerStatefulWidget {
  /// Target host to connect to for Docker management.
  /// 用于 Docker 管理的目标主机。
  final Host host;

  const ContainerShellPage({super.key, required this.host});

  @override
  ConsumerState<ContainerShellPage> createState() => _ContainerShellPageState();
}

/// Private state managing the SSH connection, the container list, and the
/// lifecycle actions issued against it.
/// 私有状态，管理 SSH 连接、容器列表，以及针对它发出的生命周期操作。
class _ContainerShellPageState extends ConsumerState<ContainerShellPage> {
  bool _isLoading = true;
  bool _isRefreshing = false;
  String? _error;
  List<DockerContainer> _containers = [];
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

      /// The container connection is a real SSH session, so it has to verify the
      /// host key like every other one: `dartssh2` accepts any key when no
      /// callback is passed, which is exactly what a machine-in-the-middle
      /// needs.
      /// 容器管理连接是真实的 SSH 会话，必须和其它连接一样校验主机密钥：
      /// 不传回调时 `dartssh2` 会接受任意密钥，这正是中间人想要的。
      final db = await ref.read(databaseProvider.future);
      _ssh = SshConnection(
        host: widget.host,
        credential: _credential!,
        // Settings → connect timeout. This page used to inherit the
        // constructor's default silently, so the setting reached nothing here.
        // 设置 → 连接超时。本页此前静默沿用构造函数默认值，该设置在此毫无作用。
        connectTimeout: ref.read(connectTimeoutProvider),
        onHostKeyVerify: buildHostKeyVerifier(
          db: db,
          address: widget.host.ipAddress,
          port: widget.host.port,
          onPrompt: (fingerprint, verdict) async {
            /// Runs after several awaits, so the page may already be gone; with
            /// nobody left to ask, refusing is the only safe answer.
            /// 该回调在多次 await 之后执行，页面可能已经销毁；此时无人可问，拒绝是唯一安全答案。
            if (!mounted) return false;
            return showHostKeyPrompt(
              context,
              fingerprint: fingerprint,
              verdict: verdict,
            );
          },
        ),
      );
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
    final ssh = _ssh;
    if (ssh == null || ssh.state != SshConnectionState.connected) {
      setState(() {
        _isLoading = false;
        _isRefreshing = false;
        _error = t('ssh_not_connected');
      });
      return;
    }

    try {
      final result = await ssh.runCommand(dockerPsCommand);
      final output = result.combined;

      /// If the output suggests Docker isn't installed, show a helpful message.
      /// 如果输出表明未安装 Docker，显示帮助信息。
      ///
      /// This check only picks which *message* to show; it is not a success
      /// test. The exit status is used below for the one thing it can decide
      /// here — whether the listing itself failed.
      /// 该判断只用于挑选要展示的**文案**，不是成败判据；退出状态在下面用于它在此
      /// 唯一能决定的事——列表命令本身是否失败。
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

      /// A listing that failed outright says so instead of rendering an empty
      /// list, which used to be indistinguishable from "no containers" — a user
      /// outside the `docker` group saw an empty page rather than
      /// `permission denied`.
      /// 失败的列表命令直接说明原因，而不是渲染一个空列表——过去它与「没有容器」
      /// 无法区分：不在 `docker` 组里的用户看到的是空页面，而不是
      /// `permission denied`。
      ///
      /// Only an *explicitly* non-zero status counts here. A missing status is
      /// not a failure for a read: the rows on stdout are still usable, and
      /// refusing to show them would break the page on servers that report no
      /// status at all. (An action is different — there the state change itself
      /// cannot be confirmed, so unknown is not success.)
      /// 这里只认**明确的**非零状态。读取操作中缺失的状态不算失败：stdout 上的行
      /// 依然可用，拒绝展示会让「不上报退出状态」的服务器上的页面直接不可用。
      /// （操作则不同——状态变更本身无法确认，因此未知不等于成功。）
      final exitCode = result.exitCode;
      if (exitCode != null && exitCode != 0) {
        if (mounted) {
          setState(() {
            _isLoading = false;
            _isRefreshing = false;
            _error =
                '${t('fetch_containers_failed')}: ${remoteFailureText(result)}';
          });
        }
        return;
      }

      _containers = parseDockerOutput(output);
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

  /// Runs one lifecycle action and reports what the remote actually said.
  /// 执行一个生命周期操作，并汇报远端实际给出的结果。
  ///
  /// Success is the exit status and nothing else. The old check —
  /// `result.contains('Error') || result.contains('error')` over stdout and
  /// stderr — reported a *successful* `docker stop` as failed whenever the
  /// output merely mentioned the word, which a container named `error-logger`
  /// guarantees: the user got an error toast and, because the failure path
  /// skipped the refresh, a card still claiming "running".
  /// 成败只看退出状态。旧判断是在 stdout+stderr 上做
  /// `result.contains('Error') || result.contains('error')`：只要输出里出现这个
  /// 词，**成功的** `docker stop` 也会被报成失败——名为 `error-logger` 的容器必然
  /// 触发——用户看到错误提示，而且失败分支会跳过刷新，卡片就一直显示运行中。
  Future<void> _runDockerAction(
    DockerAction action,
    DockerContainer container,
  ) async {
    final ssh = _ssh;
    if (ssh == null || ssh.state != SshConnectionState.connected) {
      _showToast(t('ssh_not_connected'), isError: true);
      return;
    }

    try {
      final result = await ssh.runCommand(
        dockerActionCommand(action, container.name),
      );

      final failure = remoteActionFailure(result);
      if (failure != null) {
        /// The remote's own words (`permission denied while trying to connect
        /// to the Docker daemon socket`, `No such container`) replace the
        /// generic tail the user cannot act on.
        /// 远端自己的话（`permission denied while trying to connect to the
        /// Docker daemon socket`、`No such container`）取代了用户无从下手的
        /// 笼统描述。
        if (mounted) {
          _showToast(
            '${t('container_action_failed')}: $failure',
            isError: true,
          );
        }
        return;
      }

      if (mounted) _showToast(dockerActionSuccessMessage(action));

      /// Refresh only after a confirmed change: the list is now showing a state
      /// the daemon has actually reached.
      /// 只在确认发生变更后刷新：此时列表展示的状态是守护进程真正达到的状态。
      await _fetchContainers();
    } catch (e) {
      if (mounted) {
        _showToast('${t('container_action_failed')}: $e', isError: true);
      }
    }
  }

  /// Pull-to-refresh handler — re-fetches the container list.
  /// 下拉刷新处理 — 重新获取容器列表。
  Future<void> _onRefresh() async {
    setState(() => _isRefreshing = true);
    hapticIf(
      ref.read(settingsProvider).value?.hapticEnabled,
      HapticKind.medium,
    );

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
  void _showContainerActions(DockerContainer container) {
    showContainerActionSheet(
      context,
      container: container,
      // The sheet is a free function with no `Ref` of its own — it is this page
      // that holds the settings, so the flag is passed in. Read here, at the
      // moment the sheet opens, rather than cached: flipping the switch in
      // Settings must take effect on the very next tap.
      // 该面板是不持有 `Ref` 的自由函数——设置掌握在本页手中，因此把标志传入。在此
      // 刻（面板打开时）读取而不是缓存：在设置里拨动开关后，下一次点击就必须生效。
      hapticsEnabled: ref.read(settingsProvider).value?.hapticEnabled,
      onAction: (action) => _runDockerAction(action, container),
      onRemove: () => _confirmRemoveContainer(container),
      onShowLogs: () => _showLogs(container),
    );
  }

  /// Shows a confirmation dialog before removing a container.
  /// 删除容器前显示确认对话框。
  Future<void> _confirmRemoveContainer(DockerContainer container) async {
    final confirmed = await showAppConfirmDialog(
      context,
      title: t('remove_container'),
      message: t('confirm_remove_container').replaceAll('{0}', container.name),
      cancelLabel: t('cancel'),
      confirmLabel: t('delete'),
      destructive: true,
    );
    if (!confirmed) return;

    await _runDockerAction(DockerAction.remove, container);
  }

  /// The log text for [container], including the page's own failure lines.
  /// [container] 的日志文本，包含页面自己给出的失败文案。
  Future<String> _loadLogs(DockerContainer container) async {
    final ssh = _ssh;
    if (ssh == null || ssh.state != SshConnectionState.connected) {
      return t('ssh_not_connected');
    }
    try {
      final result = await ssh.runCommand(dockerLogsCommand(container.name));
      final text = result.combined;
      return text.isEmpty ? '(no output)' : text;
    } catch (e) {
      return '${t('error')}: $e';
    }
  }

  /// Shows a dialog with real container logs fetched via SSH.
  /// 显示通过 SSH 获取的真实容器日志的对话框。
  Future<void> _showLogs(DockerContainer container) => showContainerLogsDialog(
    context,
    containerName: container.name,
    loadLogs: () => _loadLogs(container),
    onCopied: () => _showToast(t('copied')),
  );

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
            const AddContainerNotice(),
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
            return const AddContainerNotice();
          }
          final container = _containers[index];
          return ContainerCard(
            container: container,
            onTap: () => _showContainerActions(container),
          );
        },
      ),
    );
  }
}
