import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:dartssh2/dartssh2.dart';
import '../models/host.dart';
import '../models/credential.dart';
import 'host_key_verifier.dart';

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
class SshConnection {
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

  /// Broadcast controller for connection state changes.
  /// 连接状态变化的广播控制器。
  final _stateController = StreamController<SshConnectionState>.broadcast();

  /// Broadcast controller for terminal output bytes.
  /// 终端输出字节的广播控制器。
  final _outputController = StreamController<Uint8List>.broadcast();

  bool _disposed = false;

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

  /// Last error message, if any.
  /// 最近一次的错误信息（如有）。
  String? _lastError;
  String? get lastError => _lastError;

  /// Execute a single command on the remote host via a separate exec channel,
  /// collect all stdout, and return it as a string.
  /// Does NOT interfere with the persistent shell session.
  /// 通过独立的 exec 通道在远程主机上执行单个命令，
  /// 收集所有 stdout 并以字符串形式返回。
  /// 不会干扰持久化的 shell 会话。
  Future<String> executeCommand(String command) async {
    if (_client == null || _state != SshConnectionState.connected) {
      throw Exception('SSH 未连接');
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
    if (err.isEmpty) return out;
    if (out.isEmpty) return err;
    return '$out\n$err';
  }

  /// Optional host key verification callback.
  /// Receives a formatted fingerprint string (e.g. "SHA256:xxxx" or "MD5:xx:xx:...").
  /// Return true to accept the host key and continue; false to abort.
  /// 可选的主机密钥验证回调。
  /// 接收格式化的指纹字符串（如 "SHA256:xxxx" 或 "MD5:xx:xx:..."）。
  /// 返回 true 表示接受主机密钥并继续；false 则中止连接。
  final Future<bool> Function(String fingerprint)? onHostKeyVerify;

  final Duration connectTimeout;

  /// Creates a new SSH connection for the given [host] and [credential].
  /// 使用给定的 [host] 和 [credential] 创建新的 SSH 连接。
  SshConnection({
    required this.host,
    required this.credential,
    this.onHostKeyVerify,
    this.connectTimeout = const Duration(seconds: 10),
  });

  /// Updates and broadcasts the connection state.
  /// 更新并广播连接状态。
  void _setState(SshConnectionState newState) {
    _state = newState;
    if (!_disposed && !_stateController.isClosed) {
      _stateController.add(newState);
    }
  }

  /// Open a TCP socket, authenticate, and start a shell session.
  /// 打开 TCP 套接字、认证并启动 shell 会话。
  ///
  /// Idempotent: does nothing if already connecting or connected.
  /// 幂等操作：如果正在连接或已连接，则不做任何事。
  Future<void> connect() async {
    if (_state == SshConnectionState.connecting ||
        _state == SshConnectionState.connected) {
      return;
    }

    _setState(SshConnectionState.connecting);
    _lastError = null;

    try {
      final socket = await SSHSocket.connect(
        host.ipAddress,
        host.port,
        timeout: connectTimeout,
      );

      _client = SSHClient(
        socket,
        username: credential.username,
        onPasswordRequest: credential.authType == 0
            ? () => credential.secretData
            : null,
        identities: credential.authType == 1
            ? SSHKeyPair.fromPem(credential.secretData)
            : null,

        /// Pass through host key verification if a callback is provided.
        /// Formats the raw MD5 fingerprint into a readable string like "MD5:ab:cd:...".
        /// 如果提供了主机密钥验证回调，则透传。将原始 MD5 指纹格式化为类似 "MD5:ab:cd:..." 的可读字符串。
        onVerifyHostKey: onHostKeyVerify != null
            ? (type, rawFingerprint) async {
                final fingerprint = HostKeyVerifier.formatMd5(rawFingerprint);
                return onHostKeyVerify!(fingerprint);
              }
            : null,
      );

      await _client!.authenticated;

      _session = await _client!.execute(
        'exec \${SHELL:-/bin/sh} -l',
        pty: SSHPtyConfig(width: 120, height: 40),
      );

      _outputSub = _session!.stdout.listen(
        (data) {
          if (!_disposed && !_outputController.isClosed) {
            _outputController.add(data);
          }
        },
        onError: (e) {
          _lastError = e.toString();
          _setState(SshConnectionState.error);
        },
        onDone: () {
          if (_state == SshConnectionState.connected) {
            _setState(SshConnectionState.disconnected);
          }
        },
      );

      _session!.stderr.listen((data) {
        if (!_disposed && !_outputController.isClosed) {
          _outputController.add(data);
        }
      });

      _setState(SshConnectionState.connected);
    } catch (e) {
      _lastError = _translateError(e.toString());
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
    await _outputSub?.cancel();
    _outputSub = null;
    _session?.close();
    _session = null;
    _client?.close();
    _client = null;
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
    _outputSub?.cancel();
    _outputSub = null;
    _session?.close();
    _session = null;
    _client?.close();
    _client = null;
    _stateController.close();
    _outputController.close();
  }

  /// Translate raw error strings into user-friendly Chinese messages.
  /// 将原始错误字符串翻译为用户友好的中文消息。
  String _translateError(String error) {
    final lower = error.toLowerCase();
    if (lower.contains('timeout') || lower.contains('timed out')) {
      return '连接超时，请检查 IP 与防火墙设置';
    }
    if (lower.contains('host key') || lower.contains('hostkey')) {
      return 'Host Key 验证未通过，连接已拒绝';
    }
    if (lower.contains('auth') ||
        lower.contains('password') ||
        lower.contains('key')) {
      return '认证失败，请检查凭据';
    }
    if (lower.contains('refused') || lower.contains('connection refused')) {
      return '连接被拒绝，请检查端口与服务状态';
    }
    if (lower.contains('resolve') ||
        lower.contains('unknown host') ||
        lower.contains('no address')) {
      return '无法解析主机地址，请检查 IP 或域名';
    }
    return error;
  }
}
