import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:xterm/xterm.dart';
import '../core/haptics.dart';
import '../core/i18n/strings.dart';
import '../models/host.dart';
import '../models/snippet.dart';
import '../providers/providers.dart';
import '../providers/settings_provider.dart';
import '../providers/ssh_provider.dart';
import '../services/host_key_trust.dart';
import '../services/ssh_service.dart';
import '../widgets/app_ui.dart';
import '../widgets/host_key_prompt.dart';
import '../widgets/quick_key_bar.dart';
import 'console/ssh_error_text.dart';
import 'snippet_injection_dialog.dart';
import 'snippet_list_page.dart';
import 'terminal/snippets_sheet.dart';

/// Fallback terminal font size, used until the settings row has loaded and if
/// it is ever absent. Matches `AppSettings.terminalFontSize`'s own default so
/// the first frame does not jump.
/// 终端字号的回退值：在设置行加载完成前、以及该值缺失时使用。与
/// `AppSettings.terminalFontSize` 的默认值一致，以免首帧跳变。
const double _kDefaultTerminalFontSize = 13;

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
  bool _hasSelection = false;

  SshConnection? _connection;
  SshConnectionState _connState = SshConnectionState.disconnected;
  String? _connError;
  StreamSubscription<Uint8List>? _outputSub;
  StreamSubscription<SshConnectionState>? _stateSub;
  bool _showReconnectOverlay = false;

  /// Epoch of the newest connect attempt started from this page.
  /// 本页发起的最近一次连接尝试的世代号。
  ///
  /// It moves on when an attempt starts and when the page tears a connection
  /// down, so a continuation that resumes after a teardown can tell that it no
  /// longer owns what it is about to publish.
  /// 尝试开始时自增，页面拆除连接时同样自增；因此在拆除之后才恢复执行的后续代码
  /// 能够判断出自己已不再拥有即将发布的对象。
  int _connectEpoch = 0;

  /// True while a [_connect] attempt started from this page is running.
  /// 本页发起的 [_connect] 尝试仍在执行期间为 true。
  ///
  /// Re-entrancy guard for the reconnect button: everything [_connect] does
  /// suspends on at least two `await`s, and a second attempt started inside
  /// that window used to take over [_connection] and cancel the first
  /// attempt's subscriptions, whereupon the first attempt finished unobserved
  /// — an authenticated session with a login shell that no reference pointed
  /// at any more, so nothing could ever close it.
  /// 重连按钮的重入守卫：[_connect] 至少会挂起两次，而在这段窗口里启动的第二次
  /// 尝试会接管 [_connection] 并取消第一次尝试的订阅，第一次尝试随后在无人观察
  /// 的情况下跑完——留下一个已认证会话与登录 shell，却再没有任何引用能关闭它。
  bool _connectInFlight = false;

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

    _terminal.onOutput = _onTerminalOutput;
    _terminal.onResize = _onTerminalResize;

    WidgetsBinding.instance.addPostFrameCallback((_) => _connect());
  }

  /// Whether the attempt identified by [epoch] is still the newest one and the
  /// page is still alive to own its result.
  /// [epoch] 标识的尝试是否仍是最新的一次，且页面仍然存活、可以接管其结果。
  bool _attemptIsCurrent(int epoch) => mounted && epoch == _connectEpoch;

  Future<void> _connect() async {
    // Re-entrancy guard — see [_connectInFlight]. Done before anything else so
    // a second tap cannot get past it: there is no `await` between here and the
    // two suspends below that a duplicate tap could slip through. The `mounted`
    // half covers the post-frame kick-off firing for a page that has already
    // been popped.
    // 重入守卫——见 [_connectInFlight]。放在最前面，使第二次点击无法越过：从这里
    // 到下面两处挂起之间没有任何 `await` 可供重复点击钻进来。`mounted` 那一半则
    // 覆盖「首帧回调触发时页面已被弹出」的情况。
    if (!mounted || _connectInFlight) return;
    _connectInFlight = true;
    final epoch = ++_connectEpoch;

    setState(() {
      _connState = SshConnectionState.connecting;
      _connError = null;
      _showReconnectOverlay = false;
    });

    try {
      final host = widget.host;
      final creds = await ref.read(credentialListProvider.future);
      if (!_attemptIsCurrent(epoch)) return;
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
      if (!_attemptIsCurrent(epoch)) return;

      final connection = SshConnection(
        host: host,
        credential: cred,
        // Settings → connect timeout. The terminal is the page a user opens and
        // then waits on, so the number they chose applies here in full.
        // 设置 → 连接超时。终端是用户打开后会一直等待的页面，因此用户选定的数字在此
        // 完整生效。
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

      // The connection has just been built and nothing holds it yet. Starting
      // it for an attempt that no longer owns the page is exactly how a login
      // shell is left behind on the server with no reference able to close it,
      // so it is released here instead — `connect()` is never called on it.
      // 这条连接刚构造出来、还没有任何持有者。为一个已不再拥有本页的尝试启动它，
      // 正是「服务器上留下一个无人能关闭的登录 shell」的成因；因此这里直接释放，
      // 绝不调用它的 `connect()`。
      if (!_attemptIsCurrent(epoch)) {
        connection.dispose();
        return;
      }

      _connection = connection;
      _outputSub = connection.outputStream.listen((data) {
        _terminal.write(utf8.decode(data));
      });

      _stateSub = connection.stateStream.listen((state) {
        // A torn-down or superseded connection must not be able to drive the
        // UI any more, or a session the page has already dropped would flip the
        // screen back to `connected`.
        // 已拆除或被顶替的连接不得再驱动界面，否则页面已经丢掉的会话会把屏幕
        // 翻回 `connected`。
        if (!_attemptIsCurrent(epoch)) return;
        setState(() {
          _connState = state;
          if (state == SshConnectionState.error) {
            // `lastError` carries the raw transport text (English, technical).
            // Showing it verbatim would leave every non-English user without a
            // diagnosis, so the classified failure goes through the translator.
            // `lastError` 携带的是原始传输层文本（英文、技术性）。直接展示会让所有
            // 非英语用户读不到诊断信息，因此这里把分类后的失败交给翻译层。
            _connError = sshConnectErrorText(connection);
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
          connection.resizeTerminal(_terminal.viewWidth, _terminal.viewHeight);
        }
      });

      await connection.connect();
    } catch (e) {
      // A failed lookup (credentials / database) used to escape as an
      // unhandled async error and leave the page stuck on `connecting` with no
      // way back to the reconnect button.
      // 凭据 / 数据库查询失败过去会变成未处理的异步错误，让页面卡在 `connecting`
      // 上，连重连按钮都回不去。
      if (!_attemptIsCurrent(epoch)) return;
      setState(() {
        _connState = SshConnectionState.error;
        _connError = e.toString();
        _showReconnectOverlay = true;
      });
    } finally {
      // Only the attempt that still owns the page clears the guard: a superseded
      // one resuming later must not unlock a window that belongs to a newer
      // attempt.
      // 只有仍然拥有本页的那次尝试才能解除守卫：被顶替的尝试稍后恢复时，不得去
      // 解锁一个已经属于更新尝试的窗口。
      if (epoch == _connectEpoch) _connectInFlight = false;
    }
  }

  /// Builds the terminal view at the user's chosen font size.
  /// 按用户选定的字号构建终端视图。
  ///
  /// This is built per frame rather than cached in `initState`, which is what
  /// makes the Settings > font size slider take effect on the terminal already
  /// on screen. A cached view would keep whatever size was current when the
  /// page opened, and the setting would appear to do nothing until the next
  /// visit — which is indistinguishable from a broken setting.
  /// 这里每帧构建而不是在 `initState` 中缓存，正是「设置 → 字号」滑块能作用于当前
  /// 已打开的终端的缘故。缓存的视图会一直保持打开页面当时的字号，设置看起来毫无
  /// 作用直到下次进入——那和一个坏掉的设置无从区分。
  TerminalView _terminalViewFor(double fontSize) {
    return TerminalView(
      _terminal,
      controller: _terminalController,
      textStyle: TerminalStyle(fontSize: fontSize),
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
    // A teardown ends the ownership of any attempt still in flight: the epoch
    // moves on, so its continuation releases what it created instead of
    // publishing it, and the guard is released for a later attempt.
    // 拆除会终止仍在进行中的尝试的所有权：世代号向前推进，其后续代码因此会释放
    // 自己创建的东西而不是把它发布出去，同时守卫被解除，供之后的尝试使用。
    _connectEpoch++;
    _connectInFlight = false;

    _outputSub?.cancel();
    _outputSub = null;
    _stateSub?.cancel();
    _stateSub = null;

    final connection = _connection;
    _connection = null;
    // `disconnect()` closes the shell channel and the transport; `dispose()`
    // additionally releases the connection's own controllers and invalidates a
    // connect that is still suspended inside it, so an attempt nobody holds a
    // reference to any more cannot keep running.
    // `disconnect()` 关闭 shell 通道与传输层；`dispose()` 还会释放连接自身的
    // 控制器，并作废仍在其中挂起的连接，使再无人持有引用的尝试无法继续跑下去。
    connection?.disconnect();
    connection?.dispose();

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
    // Settings → font size. `watch`, not `read`: the terminal is the one screen
    // where a size change should take effect without reopening it.
    // 设置 → 字号。这里用 `watch` 而非 `read`：终端是唯一一个改动字号应当立即生效、
    // 不需要重新打开的界面。
    final fontSize =
        ref.watch(settingsProvider).value?.terminalFontSize.toDouble() ??
        _kDefaultTerminalFontSize;
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
                Expanded(child: _terminalViewFor(fontSize)),
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
    // Re-entrancy guard: a double tap used to run `_connect()` twice out of the
    // same tap handler. The second run took over [_connection] and cancelled
    // the first run's subscriptions while the first run was still suspended on
    // its awaits; that first run then completed unobserved, and the session it
    // opened stayed alive on the server with nobody left holding a reference to
    // close it. A duplicate tap is ignored rather than restarted — the attempt
    // already in flight is doing what the second tap asked for.
    // 重入守卫：双击过去会在同一个处理函数里跑两次 `_connect()`。第二次会接管
    // [_connection] 并取消第一次的订阅，而第一次仍挂起在自己的 await 上；随后
    // 第一次在无人观察的情况下跑完，它打开的会话继续活在服务器上，却没有任何人
    // 还持有可以关闭它的引用。重复点击在此直接忽略而不是重启——已在进行的尝试
    // 做的正是第二次点击想要的事。
    if (_connectInFlight) return;
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
    // Settings → haptic feedback. This is the one place the terminal vibrates,
    // and it used to do so regardless of the switch.
    // 设置 → 触觉反馈。这是终端唯一发出振动的地方，而它此前无视该开关。
    hapticIf(ref.read(settingsProvider).value?.hapticEnabled, HapticKind.light);
    if (!_isConnected) return;
    _connection?.sendText(sequence);
  }

  void _showSnippets() {
    final cs = Theme.of(context).colorScheme;
    final sheetHeight = (MediaQuery.sizeOf(context).height * 0.62).clamp(
      320.0,
      520.0,
    );
    // The sheet watches `snippetListProvider` itself (see [SnippetsSheet]).
    // Reading it here and handing the value to the builder is what used to leave
    // the sheet spinning forever on a cold start: the builder is a plain
    // function, so the `AsyncLoading` snapshot taken in this tap callback could
    // never be replaced once the provider resolved.
    // 面板自己监听 `snippetListProvider`（见 [SnippetsSheet]）。在这里读出来再交给
    // builder，正是冷启动时面板永远转圈的原因：builder 只是普通函数，点击回调里
    // 拿到的 `AsyncLoading` 快照在 provider 解析完成后也无法被替换。
    showModalBottomSheet(
      context: context,
      backgroundColor: cs.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(8)),
      ),
      builder: (_) => SnippetsSheet(
        height: sheetHeight,
        onSnippetTap: _injectSnippet,
        onManageTap: _openSnippetManager,
      ),
    );
  }

  /// Sends a snippet's command to the shell, after letting the user fill in any
  /// `[placeholder]` it contains.
  /// 把片段的命令发送到 shell，在此之前让用户填写其中的 `[placeholder]`。
  ///
  /// Called by [SnippetsSheet] after it has closed itself, so the dialog is
  /// shown from this page's context — the sheet's own context is defunct by
  /// then.
  /// 由 [SnippetsSheet] 在自行关闭后调用，因此对话框使用本页的 context 显示——
  /// 那时面板自己的 context 已经失效。
  Future<void> _injectSnippet(Snippet snippet) async {
    final command = await SnippetInjectionDialog.show(context, snippet.command);
    if (command == null || !_isConnected) return;
    _connection?.sendText('$command\n');
  }

  /// Opens the snippet manager page.
  /// 打开片段管理页。
  void _openSnippetManager() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const SnippetListPage()),
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
