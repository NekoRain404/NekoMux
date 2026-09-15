import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:xterm/xterm.dart';
import '../core/i18n/strings.dart';
import '../models/host.dart';
import '../providers/providers.dart';
import '../services/host_key_trust.dart';
import '../services/ssh_service.dart';
import '../widgets/app_ui.dart';
import '../widgets/host_key_prompt.dart';
import '../widgets/quick_key_bar.dart';
import 'snippet_injection_dialog.dart';
import 'snippet_list_page.dart';

/// SSH terminal page with interactive terminal emulator.
class SshTerminalPage extends ConsumerStatefulWidget {
  final Host host;
  const SshTerminalPage({super.key, required this.host});

  @override
  ConsumerState<SshTerminalPage> createState() => _SshTerminalPageState();
}

class _SshTerminalPageState extends ConsumerState<SshTerminalPage> {
  final _terminal = Terminal();
  late final TerminalController _terminalController;
  late final TerminalView _terminalView;
  bool _hasSelection = false;

  SshConnection? _connection;
  SshConnectionState _connState = SshConnectionState.disconnected;
  String? _connError;
  StreamSubscription<Uint8List>? _outputSub;
  StreamSubscription<SshConnectionState>? _stateSub;
  bool _showReconnectOverlay = false;

  @override
  void initState() {
    super.initState();

    _terminalController = TerminalController();
    _terminalController.addListener(() {
      final hasSel = _terminalController.selection != null;
      if (hasSel != _hasSelection) {
        setState(() => _hasSelection = hasSel);
      }
    });

    _terminalView = TerminalView(
      _terminal,
      controller: _terminalController,
      theme: TerminalTheme(
        cursor: const Color(0xFFFFFFFF),
        foreground: const Color(0xFFC9D1D9),
        background: Colors.black,
        black: const Color(0xFF484D56),
        red: const Color(0xFFF85149),
        green: const Color(0xFF3FB950),
        yellow: const Color(0xFFD29922),
        blue: const Color(0xFF58A6FF),
        magenta: const Color(0xFFBC8CFF),
        cyan: const Color(0xFF39C5CF),
        white: const Color(0xFFB1BAC4),
        brightBlack: const Color(0xFF6E7681),
        brightRed: const Color(0xFFFFA198),
        brightGreen: const Color(0xFF56D364),
        brightYellow: const Color(0xFFE3B341),
        brightBlue: const Color(0xFF79C0FF),
        brightMagenta: const Color(0xFFD2A8FF),
        brightCyan: const Color(0xFF56D4DD),
        brightWhite: const Color(0xFFF0F6FC),
        searchHitBackground: const Color(0xFF264F78),
        searchHitBackgroundCurrent: const Color(0xFF58A6FF),
        searchHitForeground: const Color(0xFFFFFFFF),
        selection: const Color(0xFF264F78),
      ),
      padding: const EdgeInsets.all(8),
      onSecondaryTapDown: (details, offset) => _copySelection(),
    );

    _terminal.onOutput = _onTerminalOutput;
    _terminal.onResize = _onTerminalResize;

    WidgetsBinding.instance.addPostFrameCallback((_) => _connect());
  }

  Future<void> _connect() async {
    setState(() {
      _connState = SshConnectionState.connecting;
      _connError = null;
      _showReconnectOverlay = false;
    });

    final host = widget.host;
    final creds = await ref.read(credentialListProvider.future);
    final cred = creds.where((c) => c.id == host.credentialId).firstOrNull;

    if (cred == null) {
      setState(() {
        _connState = SshConnectionState.error;
        _connError = t('credential_not_found');
        _showReconnectOverlay = true;
      });
      return;
    }

    // Verify the host key against the persisted known-hosts list. The previous
    // in-memory cache was keyed by fingerprint alone and forgot everything on
    // restart, so it could never notice that a *known* host's key had changed —
    // the one signal that actually indicates an interception.
    // 主机密钥对照持久化的 known_hosts 记录校验。此前的内存缓存只以指纹为键、
    // 重启即忘，因此永远无法发现**已知主机**的密钥变了——而那正是唯一能说明
    // 连接可能被劫持的信号。
    final db = await ref.read(databaseProvider.future);
    _connection = SshConnection(
      host: host,
      credential: cred,
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
    _outputSub?.cancel();
    _stateSub?.cancel();

    _outputSub = _connection!.outputStream.listen((data) {
      _terminal.write(utf8.decode(data));
    });

    _stateSub = _connection!.stateStream.listen((state) {
      if (!mounted) return;
      setState(() {
        _connState = state;
        if (state == SshConnectionState.error) {
          _connError = _connection!.lastError;
          _showReconnectOverlay = true;
        } else if (state == SshConnectionState.disconnected &&
            _showReconnectOverlay == false) {
          _showReconnectOverlay = true;
        }
      });
      // The PTY is created at a fixed 120x40, so it has to be told the real
      // on-screen size once the session exists. [onResize] will not fire for
      // this: the terminal has not changed size since it was laid out, so no
      // layout change is coming to carry the size across.
      // PTY 以固定的 120x40 创建，因此会话建立后必须把屏幕上的真实尺寸告诉它。
      // 这件事不会由 [onResize] 触发：终端自布局以来尺寸未变，不会有布局变化
      // 把尺寸带过去。
      if (state == SshConnectionState.connected) {
        _connection?.resizeTerminal(_terminal.viewWidth, _terminal.viewHeight);
      }
    });

    await _connection!.connect();
  }

  /// Keeps the remote PTY in step with the on-screen terminal.
  /// 让远端 PTY 与屏幕上的终端保持一致。
  ///
  /// The PTY is created once at a fixed 120x40. On a phone the terminal is
  /// roughly 40-60 columns, so without this the remote shell believes it has
  /// 120 columns: output wraps at the wrong place and full-screen programs
  /// (htop, vim, less) render corrupted.
  /// PTY 以固定的 120x40 创建一次。手机上的终端大约 40–60 列，因此没有这一步时，
  /// 远端 shell 会以为自己有 120 列：输出在错误的位置换行，htop、vim、less 等
  /// 全屏程序渲染错乱。
  void _onTerminalResize(
    int width,
    int height,
    int pixelWidth,
    int pixelHeight,
  ) {
    _connection?.resizeTerminal(width, height);
  }

  void _onTerminalOutput(String data) {
    if (_connection != null && _connState == SshConnectionState.connected) {
      _connection!.sendText(data);
    }
  }

  void _disconnect({bool updateUi = true}) {
    _outputSub?.cancel();
    _stateSub?.cancel();
    _connection?.disconnect();
    _connection = null;
    if (updateUi && mounted) {
      setState(() => _connState = SshConnectionState.disconnected);
    } else {
      _connState = SshConnectionState.disconnected;
    }
  }

  @override
  void dispose() {
    _disconnect(updateUi: false);
    _terminal.buffer.clear();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final host = widget.host;
    final cs = Theme.of(context).colorScheme;
    return PopScope(
      canPop: _connState != SshConnectionState.connected,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _showExitConfirm();
      },
      child: Scaffold(
        backgroundColor: Color.lerp(cs.surface, cs.onSurface, 0.06),
        appBar: _buildAppBar(host),
        body: Stack(
          children: [
            Column(
              children: [
                Expanded(child: _terminalView),
                _ConnectingBanner(connState: _connState),
                QuickKeyBar(
                  onKeyTap: _onQuickKey,
                  onSnippetsTap: _isConnected ? _showSnippets : null,
                ),
              ],
            ),
            if (_showReconnectOverlay) _buildReconnectOverlay(),
          ],
        ),
      ),
    );
  }

  PreferredSizeWidget _buildAppBar(Host host) {
    final cs = Theme.of(context).colorScheme;
    Widget titleWidget;
    switch (_connState) {
      case SshConnectionState.connecting:
        titleWidget = Row(
          children: [
            SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: cs.secondary,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '${host.alias} - ${t('connecting')}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: GoogleFonts.jetBrainsMono(
                  color: cs.onSurface.withValues(alpha: 0.6),
                  fontSize: 13,
                ),
              ),
            ),
          ],
        );
      case SshConnectionState.connected:
        titleWidget = Row(
          children: [
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                color: cs.primary,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '${host.alias} (SSH)',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: GoogleFonts.jetBrainsMono(
                  color: cs.onSurface,
                  fontSize: 14,
                ),
              ),
            ),
          ],
        );
      default:
        titleWidget = Text(
          '${host.alias} (SSH)',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: GoogleFonts.jetBrainsMono(color: cs.onSurface, fontSize: 14),
        );
    }
    return AppBar(
      backgroundColor: cs.surface,
      leading: IconButton(
        icon: Icon(
          Icons.arrow_back,
          color: cs.onSurface.withValues(alpha: 0.7),
        ),
        onPressed: _connState == SshConnectionState.connected
            ? _showExitConfirm
            : () => Navigator.pop(context),
      ),
      title: titleWidget,
      actions: [
        if (_hasSelection)
          IconButton(
            icon: Icon(Icons.copy, color: cs.secondary, size: 20),
            tooltip: t('copy'),
            onPressed: _copySelection,
          ),
        if (_isConnected)
          IconButton(
            icon: Icon(
              Icons.restart_alt,
              color: cs.onSurface.withValues(alpha: 0.6),
              size: 20,
            ),
            tooltip: t('reconnect'),
            onPressed: _reconnect,
          ),
      ],
    );
  }

  Widget _buildReconnectOverlay() {
    final cs = Theme.of(context).colorScheme;
    return Positioned.fill(
      child: Container(
        color: Theme.of(
          context,
        ).scaffoldBackgroundColor.withValues(alpha: 0.92),
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 360),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    _connState == SshConnectionState.connecting
                        ? Icons.sync
                        : Icons.link_off,
                    size: 48,
                    color: _connState == SshConnectionState.connecting
                        ? cs.secondary
                        : cs.error,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    _connState == SshConnectionState.connecting
                        ? t('connecting')
                        : _connState == SshConnectionState.error
                        ? t('connection_failed')
                        : t('disconnected'),
                    textAlign: TextAlign.center,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: cs.onSurface,
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (_connError != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      _connError!,
                      textAlign: TextAlign.center,
                      maxLines: 4,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: cs.onSurface.withValues(alpha: 0.6),
                        fontSize: 13,
                      ),
                    ),
                  ],
                  const SizedBox(height: 32),
                  SizedBox(
                    width: 160,
                    height: 48,
                    child: ElevatedButton.icon(
                      onPressed: _reconnect,
                      icon: const Icon(Icons.refresh),
                      label: Text(
                        t('reconnect'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: cs.primary,
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
        ),
      ),
    );
  }

  bool get _isConnected => _connState == SshConnectionState.connected;

  void _copySelection() {
    final selection = _terminalController.selection;
    if (selection == null) return;
    final text = _terminal.buffer.getText(selection);
    if (text.isEmpty) return;
    Clipboard.setData(ClipboardData(text: text));
    _terminalController.clearSelection();
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(t('copied'))));
    }
  }

  void _reconnect() {
    _disconnect();
    _terminal.buffer.clear();
    _connect();
  }

  Future<void> _showExitConfirm() async {
    final confirmed = await showAppConfirmDialog(
      context,
      title: t('disconnect_title'),
      message: t('confirm_disconnect_ssh'),
      cancelLabel: t('cancel'),
      confirmLabel: t('disconnect'),
      destructive: true,
    );
    if (!confirmed || !mounted) return;

    _disconnect();
    Navigator.pop(context);
  }

  void _onQuickKey(String label, String sequence) {
    HapticFeedback.lightImpact();
    if (!_isConnected) return;
    _connection?.sendText(sequence);
  }

  void _showSnippets() {
    final cs = Theme.of(context).colorScheme;
    final dividerColor = Theme.of(context).dividerColor;
    final snippetsAsync = ref.watch(snippetListProvider);
    final sheetHeight = (MediaQuery.sizeOf(context).height * 0.62).clamp(
      320.0,
      520.0,
    );
    showModalBottomSheet(
      context: context,
      backgroundColor: cs.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(8)),
      ),
      builder: (ctx) => SafeArea(
        child: SizedBox(
          height: sheetHeight,
          child: snippetsAsync.when(
            loading: () =>
                Center(child: CircularProgressIndicator(color: cs.primary)),
            error: (e, _) => Center(
              child: Text(
                t('error'),
                style: TextStyle(color: cs.onSurface.withValues(alpha: 0.6)),
              ),
            ),
            data: (snippets) => Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          t('snippets'),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: cs.onSurface,
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      TextButton(
                        onPressed: () {
                          Navigator.pop(ctx);
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => const SnippetListPage(),
                            ),
                          );
                        },
                        child: Text(
                          '${t('manage_snippets')} →',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: cs.secondary, fontSize: 13),
                        ),
                      ),
                    ],
                  ),
                ),
                if (snippets.isEmpty)
                  Expanded(
                    child: AppEmptyState(
                      icon: Icons.description_outlined,
                      title: t('empty_snippets'),
                      message: t('empty_snippets_hint'),
                      color: cs.primary,
                    ),
                  )
                else
                  Expanded(
                    child: ListView.builder(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                      itemCount: snippets.length,
                      itemBuilder: (_, i) {
                        final s = snippets[i];
                        return AppCard(
                          margin: const EdgeInsets.symmetric(vertical: 4),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 10,
                          ),
                          borderColor: dividerColor,
                          onTap: () async {
                            Navigator.pop(ctx);
                            final command = await SnippetInjectionDialog.show(
                              context,
                              s.command,
                            );
                            if (command == null || !_isConnected) return;
                            _connection?.sendText('$command\n');
                          },
                          child: Row(
                            children: [
                              AppIconBox(
                                icon: Icons.code,
                                color: cs.primary,
                                size: 36,
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      s.title,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        color: cs.onSurface,
                                        fontSize: 14,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      s.command,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        color: cs.onSurface.withValues(
                                          alpha: 0.6,
                                        ),
                                        fontSize: 11,
                                        fontFamily: 'monospace',
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              Icon(
                                Icons.send_outlined,
                                color: cs.secondary,
                                size: 18,
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Thin banner at the terminal bottom during connecting/disconnected states.
class _ConnectingBanner extends StatelessWidget {
  final SshConnectionState connState;
  const _ConnectingBanner({required this.connState});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    if (connState == SshConnectionState.connected) {
      return const SizedBox.shrink();
    }
    return Container(
      width: double.infinity,
      height: 20,
      color: connState == SshConnectionState.connecting
          ? cs.secondary.withValues(alpha: 0.15)
          : cs.error.withValues(alpha: 0.15),
      alignment: Alignment.center,
      child: Text(
        connState == SshConnectionState.connecting
            ? t('connecting')
            : t('disconnected'),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: connState == SshConnectionState.connecting
              ? cs.secondary
              : cs.error,
          fontSize: 10,
        ),
      ),
    );
  }
}
