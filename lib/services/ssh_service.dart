import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:dartssh2/dartssh2.dart';
import '../models/host.dart';
import '../models/credential.dart';
import 'command_result.dart';
import 'host_key_verifier.dart';
import 'port_forward_service.dart';
import 'ssh_failure.dart';

// The failure vocabulary lives in its own file and is re-exported
// here: every caller already imports this one for [SshConnection], and
// making them import a second file for the error type would be churn
// without a reader.
export 'ssh_failure.dart';

/// SSH connection lifecycle states.
/// SSH 连接生命周期状态。
enum SshConnectionState { disconnected, connecting, connected, error }

/// SSH connection wrapper built on top of [dartssh2].
/// 基于 [dartssh2] 的 SSH 连接封装。
///
/// Manages a single SSH session: connect, authenticate, execute a shell,
/// send input, resize the terminal, and report state / output via streams.
/// 管理单个 SSH 会话：连接、认证、执行 shell、发送输入、调整终端大小，
/// 并通过流上报状态和输出。
class SshConnection implements ForwardOpener {
  /// Target host configuration.
  /// 目标主机配置。
  final Host host;

  /// Credential used for authentication.
  /// 用于认证的凭据。
  final Credential credential;

  /// Underlying dartssh2 client.
  /// 底层 dartssh2 客户端。
  SSHClient? _client;

  /// Active SSH session (shell).
  /// 当前活动的 SSH 会话（shell）。
  SSHSession? _session;

  /// Subscription to the session stdout stream.
  /// 对会话标准输出流的订阅。
  StreamSubscription? _outputSub;

  /// Subscription to the session stderr stream.
  /// Must be cancelled together with [_outputSub], otherwise every reconnect
  /// leaves a live subscription (and its closure) behind.
  /// 对会话标准错误流的订阅。
  /// 必须与 [_outputSub] 一起取消，否则每次重连都会残留一个存活的订阅及其闭包。
  StreamSubscription? _stderrSub;

  /// Broadcast controller for connection state changes.
  /// 连接状态变化的广播控制器。
  final _stateController = StreamController<SshConnectionState>.broadcast();

  /// Broadcast controller for terminal output bytes.
  /// 终端输出字节的广播控制器。
  final _outputController = StreamController<Uint8List>.broadcast();

  bool _disposed = false;

  /// Epoch of the current connect attempt.
  /// Bumped when an attempt starts, and by [disconnect] / [dispose] to
  /// invalidate an attempt that is still suspended on an `await`. Its
  /// continuation re-checks the epoch and, when it no longer matches, closes
  /// whatever it just created instead of publishing it.
  /// 当前连接尝试的世代号。
  /// 新尝试开始时自增，[disconnect] / [dispose] 也会自增，用于作废仍挂起在
  /// `await` 上的尝试；其后续代码会发现世代号不再匹配，从而关闭刚创建的资源，
  /// 而不是把它发布出去。
  int _connectEpoch = 0;

  /// Current connection state.
  /// 当前连接状态。
  SshConnectionState _state = SshConnectionState.disconnected;
  SshConnectionState get state => _state;

  /// Stream of connection state transitions.
  /// 连接状态变化的流。
  Stream<SshConnectionState> get stateStream => _stateController.stream;

  /// Stream of raw terminal output (usually UTF-8 encoded text).
  /// 原始终端输出流（通常为 UTF-8 编码的文本）。
  Stream<Uint8List> get outputStream => _outputController.stream;

  /// Technical rendering of the most recent failure, if any.
  /// 最近一次失败的技术呈现（如有）。
  ///
  /// Never a sentence this app wrote: it is the underlying error's own text
  /// (`SocketException: Connection refused …, port = 22`,
  /// `SSHHostkeyError(Hostkey verification failed)`), so it stays printable in
  /// a log and reads the same in every language. It is what a page with no
  /// access to the i18n table can still show; the sentence a user is meant to
  /// read is chosen from [failure] by the presentation layer
  /// (`pages/console/ssh_error_text.dart`).
  /// 绝不是本应用写下的句子：它是底层错误自身的文本（……），因此既能原样写进日志，
  /// 又在任何语言下都相同。它是无法访问 i18n 表的页面仍可展示的东西；真正给用户读的
  /// 句子由展示层根据 [failure] 选择（`pages/console/ssh_error_text.dart`）。
  ///
  /// This used to hold Chinese sentences ("连接超时，请检查 IP 与防火墙设置"), which is
  /// how an English user came to be diagnosed in Chinese; a service that writes
  /// prose can only ever write it in one language.
  /// 它过去存放中文句子（“连接超时，请检查 IP 与防火墙设置”），英文用户因此收到中文
  /// 诊断；自行撰写文案的服务只能写出一种语言。
  String? _lastError;
  String? get lastError => _lastError;

  /// Machine-readable reason for the most recent failure, or `null` when
  /// nothing has failed.
  /// 最近一次失败的机器可读原因；未发生失败时为 `null`。
  ///
  /// The code, not the words: pair it with `sshFailureText` (or
  /// `sshConnectErrorText`) to get something a user can read in their own
  /// language. Set together with [lastError] on every failure path, so
  /// `state == error` and a non-null [failure] always agree.
  /// 这是编码而非文字：配合 `sshFailureText`（或 `sshConnectErrorText`）即可得到用户
  /// 所用语言的可读文案。它在每条失败路径上都与 [lastError] 一同写入，因此
  /// `state == error` 与非空 [failure] 始终一致。
  SshFailure? _failure;
  SshFailure? get failure => _failure;

  /// Execute a single command on the remote host via a separate exec channel
  /// and report its output *and* its exit status.
  /// Does NOT interfere with the persistent shell session.
  /// 通过独立的 exec 通道在远程主机上执行单个命令，并同时返回输出与退出状态。
  /// 不会干扰持久化的 shell 会话。
  ///
  /// Prefer this over [executeCommand]: the exit status is the only reliable
  /// signal of whether the remote command actually did what it was asked, and
  /// [executeCommand] throws it away. See [CommandResult.ok] — in particular,
  /// a server that reports no status yields `ok == false` rather than a
  /// success that was never confirmed.
  /// 优先使用本方法而非 [executeCommand]：退出状态是判断远端命令是否真正完成的
  /// 唯一可靠依据，而 [executeCommand] 把它丢弃了。见 [CommandResult.ok]——
  /// 尤其是服务端不上报状态时返回 `ok == false`，而不是一个未经确认的成功。
  ///
  /// Draining order matters and is deliberate: `SSHSession.done` completes when
  /// the *channel* closes, and its documentation warns that "more data may
  /// still be available on the stdout and stderr streams at this time"
  /// (`ssh_session.dart`). The two `join()`s are therefore started *before*
  /// `done` is awaited — they consume as data arrives instead of after the
  /// channel is gone — and only awaited afterwards, so nothing that lands in
  /// the same turn as the channel close can be dropped. Starting the drains
  /// also keeps the remote window from filling up, so a command that produces
  /// megabytes of output cannot deadlock against us; and because `join()`
  /// completes when the stream *closes*, a command with no stdout at all still
  /// finishes instead of waiting for output that will never come.
  /// 排空顺序是有意为之：`SSHSession.done` 在**通道**关闭时完成，其文档明确提醒
  /// “此时 stdout / stderr 上可能仍有数据可读”。因此两次 `join()` 在 `await
  /// session.done` **之前**就已启动——它们随数据到达即时消费，而不是等通道消失后
  /// 才开始——之后才被 await，与通道关闭同批次抵达的数据因此不会丢失。提前启动
  /// 消费同时避免远端发送窗口被填满，使产生大量输出的命令不会与我们互相死锁；
  /// 又因为 `join()` 在流**关闭**时完成，完全没有 stdout 的命令也照样结束，
  /// 不会去等待永远不会到来的输出。
  ///
  /// A connection that is not up throws [SshException] with
  /// [SshFailure.notConnected] rather than a bare `Exception`: callers have to
  /// be able to tell "there is no session" from everything else the transport
  /// can throw, and the message they show comes from the i18n table
  /// (`ssh_not_connected`), not from here.
  /// 未连接的连接抛出携带 [SshFailure.notConnected] 的 [SshException]，而不是裸的
  /// `Exception`：调用方必须能把「没有会话」与传输层可能抛出的其它错误区分开，而展示
  /// 的文案来自 i18n 表（`ssh_not_connected`），不是来自这里。
  Future<CommandResult> runCommand(String command) async {
    if (_client == null || _state != SshConnectionState.connected) {
      throw const SshException(SshFailure.notConnected);
    }
    final session = await _client!.execute(command);
    final outputFuture = session.stdout
        .cast<List<int>>()
        .transform(utf8.decoder)
        .join();
    final errorFuture = session.stderr
        .cast<List<int>>()
        .transform(utf8.decoder)
        .join();
    await session.done;
    final out = await outputFuture;
    final err = await errorFuture;
    // Read after `done`: the exit-status request is dispatched before the
    // channel-close message that completes `done`, so the status is in place
    // here whenever the server sends one at all. `exitCode` stays null when it
    // does not — see CommandResult.exitCode.
    // 在 `done` 之后读取：退出状态请求先于使 `done` 完成的通道关闭消息被分发，
    // 因此只要服务端上报过状态，这里就已经拿到了。未上报时 `exitCode` 保持
    // null——见 CommandResult.exitCode。
    return CommandResult(stdout: out, stderr: err, exitCode: session.exitCode);
  }

  /// Execute a single command on the remote host via a separate exec channel,
  /// collect its output, and return it as a single string.
  /// Does NOT interfere with the persistent shell session.
  /// 通过独立的 exec 通道在远程主机上执行单个命令，
  /// 收集其输出并以单个字符串形式返回。
  /// 不会干扰持久化的 shell 会话。
  ///
  /// Kept for its existing callers, and defined as [CommandResult.combined] of
  /// [runCommand] so both paths can never drift apart. It reports no exit
  /// status — use [runCommand] when success has to be judged rather than
  /// printed.
  /// 为既有调用方保留，并定义为 [runCommand] 的 [CommandResult.combined]，
  /// 使两条路径不可能各自漂移。它不上报退出状态；需要判断成败（而非仅展示输出）
  /// 时请用 [runCommand]。
  Future<String> executeCommand(String command) async =>
      (await runCommand(command)).combined;

  /// Optional host key verification callback.
  /// Receives a formatted fingerprint string (e.g. "SHA256:xxxx" or "MD5:xx:xx:...").
  /// Return true to accept the host key and continue; false to abort.
  /// 可选的主机密钥验证回调。
  /// 接收格式化的指纹字符串（如 "SHA256:xxxx" 或 "MD5:xx:xx:..."）。
  /// 返回 true 表示接受主机密钥并继续；false 则中止连接。
  ///
  /// The key *type* ("ssh-ed25519", "ssh-rsa", ...) is not passed here; use
  /// [onHostKeyVerifyTyped] when it has to be recorded. Both are honoured, and
  /// [onHostKeyVerifyTyped] wins when both are given.
  /// 这里不传密钥*类型*（"ssh-ed25519"、"ssh-rsa" 等）；需要记录类型时请用
  /// [onHostKeyVerifyTyped]。两者都会生效，同时提供时以 [onHostKeyVerifyTyped]
  /// 为准。
  final Future<bool> Function(String fingerprint)? onHostKeyVerify;

  /// Host key verification callback that also receives the key type.
  /// 同时接收密钥类型的主机密钥验证回调。
  ///
  /// [type] is the algorithm the server presented (e.g. `ssh-ed25519`,
  /// `ssh-rsa`), as dartssh2 reports it; [fingerprint] is formatted exactly as
  /// [onHostKeyVerify] would receive it, so both callbacks can share one trust
  /// store. [onHostKeyVerify] is implemented on top of this shape, which is why
  /// the two can never disagree about a fingerprint.
  /// [type] 是服务端出示的算法（如 `ssh-ed25519`、`ssh-rsa`），由 dartssh2 上报；
  /// [fingerprint] 的格式与 [onHostKeyVerify] 收到的完全一致，因此两个回调可以
  /// 共用同一个信任存储。[onHostKeyVerify] 就建立在这一形态之上，所以两者对指纹
  /// 的判断不可能出现分歧。
  final Future<bool> Function(String type, String fingerprint)?
  onHostKeyVerifyTyped;

  /// Connect timeout applied when a caller does not pass one.
  /// 调用方未传入时采用的连接超时。
  ///
  /// This is a *fallback*, not the user's setting. Settings → connect timeout
  /// is read where the connection is built (see `connectTimeoutProvider`) and
  /// passed in explicitly, so a wired page honours the number the user chose
  /// while anything not wired behaves exactly as it did before that provider
  /// existed. It is named so the fallback has a single definition: a caller
  /// that has to pass it explicitly references this constant rather than
  /// re-typing `10`, which is how the two could otherwise drift apart.
  /// 这是**兜底值**，不是用户的设置。「设置 → 连接超时」在构造连接处读取
  /// （见 `connectTimeoutProvider`）并显式传入，因此已接线的页面遵循用户选定的数字，
  /// 而未接线的路径与该 provider 出现之前完全一致。具名是为了让兜底值只有一处定义：
  /// 需要显式传入的调用方引用本常量，而不是重新写一遍 `10`——那正是两者可能漂移的
  /// 原因。
  static const Duration defaultConnectTimeout = Duration(seconds: 10);

  /// How long a session may stay silent before the client pings the server.
  ///
  /// A phone is not a server: the screen sleeps, the radio hands the connection
  /// to another cell, and a carrier NAT drops a mapping nothing has crossed for a
  /// while. None of that closes the socket — the connection is simply gone — and
  /// an idle terminal or a transfer the server has stopped acknowledging then
  /// waits on that dead flow forever, because nothing is being sent that could
  /// come back as an error. A ping every [defaultKeepAliveInterval] keeps the
  /// mapping alive and turns a dead flow into a failure the user can see.
  ///
  /// 30s sits below the idle timeouts carrier NATs are built with and far above
  /// the cost of one small packet, so on an otherwise silent link this is the only
  /// traffic there is; dartssh2's own default (10s) is not relied on, so the
  /// number has one definition this app can point at.
  static const Duration defaultKeepAliveInterval = Duration(seconds: 30);

  /// Timeout for establishing the TCP/SSH session.
  /// 建立 TCP/SSH 会话的超时时间。
  final Duration connectTimeout;

  /// How long the session may stay silent before the client pings the server.
  ///
  /// A parameter rather than a bare constant for the same reason as
  /// [connectTimeout]: a caller that has to state it explicitly references
  /// [defaultKeepAliveInterval] rather than re-typing `30`, which is how the two
  /// could otherwise drift apart.
  final Duration keepAliveInterval;

  /// The bastion this connection is dialled THROUGH, or null for a direct one.
  ///
  /// A [Host] rather than an address because a bastion is a host the user has
  /// already configured: it has its own credential and its own entry in the
  /// known-hosts table, and its key is a separate decision from the target's.
  final Host? jumpHost;

  /// The bastion's credential. Required when [jumpHost] is set.
  final Credential? jumpCredential;

  /// Verifies the BASTION's key, which is a different key from the target's.
  ///
  /// Two hops, two identities: a connection through a bastion that checked only
  /// one of them would be verifying the wrong machine half the time.
  final Future<bool> Function(String type, String fingerprint)?
  onJumpHostKeyVerify;

  /// The bastion's client, held so its transport outlives the tunnel — and so it
  /// can be closed after it, never before (see [_closeTargetThenBastion]).
  SSHClient? _jumpClient;

  /// What to run in place of the interactive login shell, or null for one.
  ///
  /// A command session is how the app gets a shell *inside* something — a
  /// container, most of all: `docker exec -it <name> sh` is an ordinary
  /// command, and running it over a PTY is what a terminal on a laptop does.
  /// Everything above this line is unchanged: same connection, same host-key
  /// verification, same keepalive, same stream of output bytes. Only the last
  /// step — what the channel asks the server to run — differs.
  final String? initialCommand;

  /// Creates a new SSH connection for the given [host] and [credential].
  /// 使用给定的 [host] 和 [credential] 创建新的 SSH 连接。
  SshConnection({
    required this.host,
    required this.credential,
    this.initialCommand,
    this.onHostKeyVerify,
    this.onHostKeyVerifyTyped,
    this.connectTimeout = defaultConnectTimeout,
    this.keepAliveInterval = defaultKeepAliveInterval,
    this.jumpHost,
    this.jumpCredential,
    this.onJumpHostKeyVerify,
  });

  /// Produces the transport [connect]'s client is built on: a direct TCP socket,
  /// or a `direct-tcpip` channel opened through the bastion.
  ///
  /// Returns null when the attempt was abandoned while this was running, having
  /// released everything it created — the caller must not continue in that case.
  ///
  /// The bastion is dialled first and then asked to open a channel to the target
  /// `host:port` FROM ITS OWN SIDE, which is what makes a machine that this phone
  /// cannot route to reachable at all. The channel is an `SSHSocket` as far as
  /// the next client is concerned — dartssh2's own "connect through a jump
  /// server" recipe — so nothing after this method knows the difference.
  Future<SSHSocket?> _resolveTransport(int epoch) async {
    final bastionHost = jumpHost;
    final bastionCredential = jumpCredential;
    if (bastionHost == null || bastionCredential == null) {
      final socket = await SSHSocket.connect(
        host.ipAddress,
        host.port,
        timeout: connectTimeout,
      );
      if (_isAbandoned(epoch)) {
        _abandonConnecting(socket: socket);
        return null;
      }
      return socket;
    }

    final bastionSocket = await SSHSocket.connect(
      bastionHost.ipAddress,
      bastionHost.port,
      timeout: connectTimeout,
    );
    if (_isAbandoned(epoch)) {
      _abandonConnecting(socket: bastionSocket);
      return null;
    }

    final verifier = onJumpHostKeyVerify;
    final bastion = SSHClient(
      bastionSocket,
      username: bastionCredential.username,
      keepAliveInterval: keepAliveInterval,
      onPasswordRequest: bastionCredential.authType == 0
          ? () => bastionCredential.secretData
          : null,
      identities: bastionCredential.authType == 1
          ? SSHKeyPair.fromPem(bastionCredential.secretData)
          : null,
      onVerifyHostKey: verifier == null
          ? null
          : (type, rawFingerprint) async =>
                verifier(type, HostKeyVerifier.formatMd5(rawFingerprint)),
    );
    _jumpClient = bastion;
    await bastion.authenticated;

    if (_isAbandoned(epoch)) {
      _closeBastion();
      return null;
    }

    // The target's address is resolved and dialled by the BASTION, so it may be
    // loopback, an RFC1918 address, or a name that only exists inside that
    // network — none of which this device could reach on its own.
    return bastion.forwardLocal(host.ipAddress, host.port);
  }

  /// Closes the bastion, if there is one.
  ///
  /// Never called before the target's client is closed: the tunnel is a channel
  /// on the bastion's transport, and tearing that transport down first leaves the
  /// channel's own close unable to send anything — dartssh2 throws from the
  /// channel teardown, which then aborts the rest of the client's cleanup.
  void _closeBastion() {
    try {
      _jumpClient?.close();
    } catch (_) {
      // Transport already gone / 传输层已不存在。
    }
    _jumpClient = null;
  }

  /// The verification callback to hand to dartssh2, derived from whichever of
  /// the two public callbacks was supplied, or `null` when neither was.
  /// 实际交给 dartssh2 的验证回调：由两个公开回调中提供的那个派生而来，
  /// 两者都没有时为 `null`。
  ///
  /// [onHostKeyVerifyTyped] is preferred, and the fingerprint-only
  /// [onHostKeyVerify] is adapted to the same `(type, fingerprint)` shape —
  /// one code path, so a call site can migrate to the typed callback (to record
  /// the key type) without its verification behaviour changing at all.
  /// 优先使用 [onHostKeyVerifyTyped]；只有指纹的 [onHostKeyVerify] 会被适配成
  /// 同样的 `(type, fingerprint)` 形态——只有一条代码路径，因此调用点迁移到带类型
  /// 的回调（以便记录密钥类型）时，其验证行为不会有任何改变。
  Future<bool> Function(String type, String fingerprint)? get _hostKeyVerifier {
    final typed = onHostKeyVerifyTyped;
    if (typed != null) return typed;
    final legacy = onHostKeyVerify;
    if (legacy == null) return null;
    return (type, fingerprint) => legacy(fingerprint);
  }

  /// Updates and broadcasts the connection state.
  /// 更新并广播连接状态。
  void _setState(SshConnectionState newState) {
    _state = newState;
    if (!_disposed && !_stateController.isClosed) {
      _stateController.add(newState);
    }
  }

  /// Whether the connect attempt identified by [epoch] has been superseded by
  /// a [disconnect] or [dispose] that landed while it was suspended.
  /// 由 [epoch] 标识的连接尝试是否在其挂起期间被 [disconnect] 或 [dispose] 作废。
  bool _isAbandoned(int epoch) => _disposed || epoch != _connectEpoch;

  /// Tears down resources created by a connect attempt that was invalidated
  /// while suspended on an `await` (see [_isAbandoned]).
  /// 清理在 `await` 挂起期间被作废的连接尝试所创建的资源（见 [_isAbandoned]）。
  ///
  /// Opens a channel to [remoteHost]:[remotePort] as the *server* sees it.
  ///
  /// Delegated rather than handed out: the client itself stays private, so a
  /// caller cannot reach past this method to the transport that the connection's
  /// own teardown is responsible for closing.
  @override
  Future<ForwardChannel> openForward({
    required String remoteHost,
    required int remotePort,
  }) async {
    final client = _client;
    if (client == null || _state != SshConnectionState.connected) {
      throw const PortForwardException(
        PortForwardFailure.sessionClosed,
        'not connected',
      );
    }
    final channel = await client.forwardLocal(remoteHost, remotePort);
    return _ChannelAdapter(channel);
  }

  /// Only the references owned by that attempt are touched: `_client` and
  /// `_session` are deliberately left alone, because [disconnect] / [dispose]
  /// already cleared them and a newer attempt may own them by now.
  /// 只关闭该次尝试自己持有的引用；刻意不碰 `_client` 与 `_session`，
  /// 因为 [disconnect] / [dispose] 已经清空了它们，此刻也可能已被更新的尝试占用。
  ///
  /// This method never reports [SshConnectionState.connected].
  /// 本方法绝不会上报 [SshConnectionState.connected]。
  void _abandonConnecting({
    SSHSocket? socket,
    SSHClient? client,
    SSHSession? session,
  }) {
    // Each step is guarded on its own: once the transport is closed,
    // closing a session or a client that owns a channel throws
    // SSHStateError, and that must not keep the remaining resources open.
    // 每一步单独守护：传输层关闭后，再关闭持有通道的 session / client 会抛出
    // SSHStateError，不能因此让其余资源继续泄漏。
    try {
      session?.close();
    } catch (_) {
      // Channel already gone / 通道已不存在。
    }
    try {
      client?.close();
    } catch (_) {
      // Transport already gone / 传输层已不存在。
    }
    // The bastion goes last, and only once the client built on its tunnel is
    // gone: see [_closeBastion].
    _closeBastion();
    // Unlike `close()`, `destroy()` is synchronous, idempotent and does not
    // throw, so it leaves no future behind. The socket was never spoken to at
    // the SSH level, so there is nothing to flush gracefully.
    // 与 `close()` 不同，`destroy()` 是同步、幂等且不抛异常的，不会留下 future。
    // 该套接字从未进行过任何 SSH 层面的通信，因此无需优雅收尾。
    socket?.destroy();
  }

  /// Open a TCP socket, authenticate, and start a shell session.
  /// 打开 TCP 套接字、认证并启动 shell 会话。
  ///
  /// Idempotent: does nothing if already connecting or connected.
  /// 幂等操作：如果正在连接或已连接，则不做任何事。
  ///
  /// Abortable: [disconnect] / [dispose] invalidate a connect that is still
  /// in flight, and every continuation below re-checks that after each
  /// `await`, so a teardown that lands mid-flight can never be outraced into
  /// publishing a live client or login shell.
  /// 可中止：[disconnect] / [dispose] 会作废仍在进行中的连接；下面每个 `await`
  /// 之后都会重新检查，因此中途发生的清理操作不可能被反超而留下存活的客户端或
  /// 登录 shell。
  Future<void> connect() async {
    // A disposed connection is dead for good: reconnecting it would create a
    // client and a login shell that no owner is left to close.
    // 已释放的连接不可复活：重新连接只会造出无人负责关闭的客户端和登录 shell。
    if (_disposed) return;

    if (_state == SshConnectionState.connecting ||
        _state == SshConnectionState.connected) {
      return;
    }

    final epoch = ++_connectEpoch;
    _setState(SshConnectionState.connecting);
    _lastError = null;
    _failure = null;

    try {
      final socket = await _resolveTransport(epoch);
      // Null means the attempt was abandoned while it was being built, and the
      // helper has already released whatever it had made.
      if (socket == null) return;

      // Torn down while the TCP handshake was pending. This socket is all the
      // attempt owns and nothing else holds a reference to it, so if it is not
      // destroyed here it stays connected forever.
      // TCP 握手期间被释放。这个套接字是本次尝试唯一的产物，没有其他引用持有它，
      // 不在这里销毁就会一直保持连接。
      if (_isAbandoned(epoch)) {
        _abandonConnecting(socket: socket);
        return;
      }

      // Resolved once per attempt, so the callback used for a given connection
      // cannot be swapped halfway through the handshake.
      // 每次尝试只解析一次，握手中途不可能被换成另一个回调。
      final hostKeyVerifier = _hostKeyVerifier;

      final client = SSHClient(
        socket,
        username: credential.username,

        /// Passed explicitly rather than left to dartssh2's own 10s default, so
        /// the console and the file manager keep their sessions alive on the same
        /// number — see [defaultKeepAliveInterval].
        keepAliveInterval: keepAliveInterval,
        onPasswordRequest: credential.authType == 0
            ? () => credential.secretData
            : null,
        identities: credential.authType == 1
            ? SSHKeyPair.fromPem(credential.secretData)
            : null,

        /// Pass through host key verification if a callback is provided.
        /// Formats the raw MD5 fingerprint into a readable string like
        /// "MD5:ab:cd:...", and hands the key type through to the callback
        /// unchanged instead of dropping it.
        /// 如果提供了主机密钥验证回调，则透传。将原始 MD5 指纹格式化为类似
        /// "MD5:ab:cd:..." 的可读字符串，并把密钥类型原样交给回调而不是丢弃。
        onVerifyHostKey: hostKeyVerifier == null
            ? null
            : (type, rawFingerprint) async => hostKeyVerifier(
                type,
                HostKeyVerifier.formatMd5(rawFingerprint),
              ),
      );

      // Publish the client before awaiting so that disconnect()/dispose() can
      // reach it and abort the handshake instead of leaving a live,
      // authenticated client behind.
      // 在等待前先发布客户端，好让 disconnect()/dispose() 能拿到它并中止握手，
      // 而不是留下一个仍然存活且已完成认证的客户端。
      _client = client;

      await client.authenticated;

      // Torn down during authentication — possibly while a host-key dialog or
      // a password prompt was still on screen. dispose()/disconnect() already
      // closed `client`; closing again is a safe backstop because
      // SSHClient.close() is idempotent.
      // 认证期间被释放——当时可能还开着主机密钥对话框或密码提示。
      // dispose()/disconnect() 已经关闭过 client；SSHClient.close() 是幂等的，
      // 这里再关一次作为兜底。
      if (_isAbandoned(epoch)) {
        _abandonConnecting(client: client);
        return;
      }

      // A PTY either way: without one there is no job control, no prompt line
      // and no full-screen program — and `docker exec -it`, whose whole point is
      // the `-t`, would fail outright.
      final session = await client.execute(
        initialCommand ?? 'exec \${SHELL:-/bin/sh} -l',
        pty: SSHPtyConfig(width: 120, height: 40),
      );

      // Torn down while the shell channel was being opened. The interactive
      // login shell already exists on the server by now and `session` is the
      // only reference to it — the invalidating call could not have closed it
      // because the field was still null at the time.
      // 打开 shell 通道期间被释放。此时服务器上的交互式登录 shell 已经存在，
      // 而 `session` 是它唯一的引用——作废调用当时看到字段仍为 null，无法关闭它。
      if (_isAbandoned(epoch)) {
        _abandonConnecting(session: session, client: client);
        return;
      }

      _session = session;

      _outputSub = session.stdout.listen(
        (data) {
          if (!_disposed && !_outputController.isClosed) {
            _outputController.add(data);
          }
        },
        onError: (e) {
          // Same pairing as a failed connect: the raw text is printable, the
          // code is what the page turns into a sentence. A session that dies
          // mid-flight is classified like any other transport failure; the
          // catch-all is the honest answer when nothing matches.
          // 与连接失败相同的成对写入：原始文本供打印，编码供页面转成句子。会话中途
          // 断开与其它传输层失败同样归类；没有命中任何条件时，兜底编码才是诚实的答案。
          final detail = e.toString();
          _lastError = detail;
          _failure = classifySshFailure(detail);
          _setState(SshConnectionState.error);
        },
        onDone: () {
          if (_state == SshConnectionState.connected) {
            _setState(SshConnectionState.disconnected);
          }
        },
      );

      _stderrSub = session.stderr.listen((data) {
        if (!_disposed && !_outputController.isClosed) {
          _outputController.add(data);
        }
      });

      // There is no `await` between the check above and this line, so a
      // teardown cannot slip in between: either we reach this point first (and
      // the teardown finds a published session it can close), or the check
      // above already returned.
      // 上面的检查与本行之间没有 `await`，清理操作不可能插进来：
      // 要么我们先到达（清理操作会看到一个已发布、可被关闭的会话），
      // 要么上面的检查已经返回。
      _setState(SshConnectionState.connected);
    } catch (e) {
      // A failure caused by our own teardown is not a connection error: stay
      // silent rather than flipping a dead object to `error`.
      // 由我们自己的清理动作引发的失败不是连接错误：对象已作废，不要置为 error。
      if (_isAbandoned(epoch)) return;
      // The detail and its code, never a sentence: the page that shows this has
      // the i18n table, and this service does not.
      // 写入细节与其编码，绝不写句子：展示它的页面才有 i18n 表，本服务没有。
      final detail = e.toString();
      _lastError = detail;
      _failure = classifySshFailure(detail);
      _setState(SshConnectionState.error);
    }
  }

  /// Send [text] to the remote shell's stdin.
  /// 将 [text] 发送到远程 shell 的标准输入。
  void sendText(String text) {
    if (_session != null && _state == SshConnectionState.connected) {
      _session!.stdin.add(utf8.encode(text));
    }
  }

  /// Resize the remote PTY to [width] columns × [height] rows.
  /// 将远程 PTY 调整为 [width] 列 × [height] 行。
  void resizeTerminal(int width, int height) {
    _session?.resizeTerminal(width, height);
  }

  /// Close the session and underlying client gracefully.
  /// 优雅地关闭会话和底层客户端。
  Future<void> disconnect() async {
    // Invalidate a connect that is still in flight *before* the first `await`:
    // its continuations will clean up after themselves instead of publishing a
    // live client/session that this call has already walked past. Without this
    // the connection object is dropped by its owner while connect() keeps
    // running to completion, leaving an authenticated shell open on the server.
    // 在第一个 `await` 之前作废仍在进行中的连接：它的后续代码会自行清理，而不是
    // 发布一个本次调用已经错过的存活客户端/会话。否则上层会丢掉该连接对象，而
    // connect() 仍会跑完，在服务器上留下一个已认证的 shell。
    _connectEpoch++;

    await _outputSub?.cancel();
    _outputSub = null;
    await _stderrSub?.cancel();
    _stderrSub = null;
    _session?.close();
    _session = null;
    _client?.close();
    _client = null;
    // After, never before: the tunnel is a channel on the bastion's transport.
    _closeBastion();
    if (!_disposed) {
      _setState(SshConnectionState.disconnected);
    } else {
      _state = SshConnectionState.disconnected;
    }
  }

  /// Release all resources (stream controllers and the connection itself).
  /// 释放所有资源（流控制器和连接本身）。
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    // Invalidate any in-flight connect attempt before the fields are cleared,
    // so its continuations cannot repopulate a disposed object.
    // 在清空字段前先作废仍在进行中的连接尝试，避免其后续代码把资源重新写回这个
    // 已释放的对象。
    _connectEpoch++;
    _outputSub?.cancel();
    _outputSub = null;
    _stderrSub?.cancel();
    _stderrSub = null;
    _session?.close();
    _session = null;
    _client?.close();
    _client = null;
    _closeBastion();
    _stateController.close();
    _outputController.close();
  }
}

class _ChannelAdapter implements ForwardChannel {
  _ChannelAdapter(this._channel);

  final SSHForwardChannel _channel;

  @override
  Stream<Uint8List> get stream => _channel.stream;

  @override
  void write(List<int> data) => _channel.sink.add(data);

  @override
  Future<void> close() => _channel.close();
}
