import 'dart:typed_data';
import 'package:dartssh2/dartssh2.dart';
import '../models/host.dart';
import '../models/credential.dart';
import '../models/file_item.dart';
import 'host_key_verifier.dart';

/// SFTP file browser backed by dartssh2's SSH/SFTP protocol implementation.
/// 基于 dartssh2 的 SSH/SFTP 协议实现的 SFTP 文件浏览器。
///
/// Provides list, read, write, delete, rename, and mkdir operations
/// over an authenticated SSH transport.
/// 在已认证的 SSH 传输层上提供列表、读取、写入、删除、重命名和创建目录操作。
class SftpService {
  /// Target host configuration.
  /// 目标主机配置。
  final Host host;

  /// Credential used for SSH authentication.
  /// 用于 SSH 认证的凭据。
  final Credential credential;

  /// Underlying dartssh2 client.
  /// 底层 dartssh2 客户端。
  SSHClient? _client;

  /// Active SFTP client session.
  /// 当前活动的 SFTP 客户端会话。
  SftpClient? _sftp;

  /// Epoch of the current connect attempt.
  /// Bumped when an attempt starts, and by [disconnect] to invalidate an
  /// attempt that is still suspended on an `await`. Its continuation re-checks
  /// the epoch and, when it no longer matches, closes whatever it just created
  /// instead of publishing it.
  /// 当前连接尝试的世代号。
  /// 新尝试开始时自增，[disconnect] 也会自增，用于作废仍挂起在 `await` 上的
  /// 尝试；其后续代码会发现世代号不再匹配，从而关闭刚创建的资源，而不是把它
  /// 发布出去。
  int _connectEpoch = 0;

  /// Optional host key verification callback.
  final Future<bool> Function(String fingerprint)? onHostKeyVerify;

  /// Creates a new SFTP service for the given [host] and [credential].
  /// 使用给定的 [host] 和 [credential] 创建新的 SFTP 服务。
  SftpService({
    required this.host,
    required this.credential,
    this.onHostKeyVerify,
  });

  /// Open SSH connection, authenticate, then open SFTP session.
  /// 打开 SSH 连接、认证，然后打开 SFTP 会话。
  ///
  /// Abortable: [disconnect] invalidates a connect that is still in flight, and
  /// every continuation below re-checks that after each `await`, so a teardown
  /// that lands mid-flight can never be outraced into publishing a live client
  /// or SFTP session.
  /// 可中止：[disconnect] 会作废仍在进行中的连接；下面每个 `await` 之后都会
  /// 重新检查，因此中途发生的清理操作不可能被反超而留下存活的客户端或 SFTP 会话。
  Future<void> connect() async {
    final epoch = ++_connectEpoch;

    // The resources this attempt creates are tracked in locals as well:
    // a concurrent [disconnect] clears the fields, and a newer attempt may own
    // them by now, so cleanup here must never go through the fields.
    // 本次尝试创建的资源同时用局部变量跟踪：并发的 [disconnect] 会清空字段，
    // 更新的尝试此刻也可能已占用它们，因此这里的清理绝不能经由字段进行。
    SSHSocket? socket;
    SSHClient? client;
    SftpClient? sftp;

    try {
      socket = await SSHSocket.connect(
        host.ipAddress,
        host.port,
        timeout: const Duration(seconds: 10),
      );

      // Torn down while the TCP handshake was pending. This socket is all the
      // attempt owns and nothing else holds a reference to it, so it must be
      // destroyed here or it stays connected forever.
      // TCP 握手期间被清理。这个套接字是本次尝试唯一的产物，没有其他引用持有它，
      // 不在这里销毁就会一直保持连接。
      if (_isAbandoned(epoch)) {
        _abandonConnecting(socket: socket);
        return;
      }

      client = SSHClient(
        socket,
        username: credential.username,
        onPasswordRequest: credential.authType == 0
            ? () => credential.secretData
            : null,
        identities: credential.authType == 1
            ? SSHKeyPair.fromPem(credential.secretData)
            : null,
        onVerifyHostKey: onHostKeyVerify != null
            ? (type, rawFingerprint) async {
                final fingerprint = HostKeyVerifier.formatMd5(rawFingerprint);
                return onHostKeyVerify!(fingerprint);
              }
            : null,
      );

      // Publish the client before awaiting so that [disconnect] can reach it and
      // abort the handshake, instead of walking past it and leaving a live,
      // authenticated client behind.
      // 在等待前先发布客户端，好让 [disconnect] 能拿到它并中止握手，
      // 而不是错过它、留下一个仍然存活且已完成认证的客户端。
      _client = client;

      await client.authenticated;

      // Torn down during authentication — possibly while a host-key dialog was
      // still on screen. [disconnect] has already closed `client`; closing it
      // again here is a backstop, and the guards below tolerate that.
      // 认证期间被清理——当时可能还开着主机密钥对话框。[disconnect] 已经关闭过
      // `client`；这里再关一次作为兜底，由下面的守护语句容忍重复关闭。
      if (_isAbandoned(epoch)) {
        _abandonConnecting(client: client);
        return;
      }

      sftp = await client.sftp();

      // Torn down while the SFTP subsystem was being opened. The subsystem
      // already exists on the server by now and `sftp` is the only reference to
      // it — the invalidating call could not have closed it, because the field
      // was still null at the time.
      // 打开 SFTP 子系统期间被清理。此时服务器上的子系统已经存在，而 `sftp` 是
      // 它唯一的引用——作废调用当时看到字段仍为 null，无法关闭它。
      if (_isAbandoned(epoch)) {
        _abandonConnecting(sftp: sftp, client: client);
        return;
      }

      // There is no `await` between the check above and this line, so a
      // teardown cannot slip in between: either we reach this point first (and
      // the teardown finds a published session it can close), or the check
      // above already returned.
      // 上面的检查与本行之间没有 `await`，清理操作不可能插进来：
      // 要么我们先到达（清理操作会看到一个已发布、可被关闭的会话），
      // 要么上面的检查已经返回。
      _sftp = sftp;
    } catch (e) {
      // A failure caused by our own teardown is not a connection error: close
      // whatever this attempt created and stay silent, rather than reporting an
      // error to a caller that has already moved on.
      // 由我们自己的清理动作引发的失败不是连接错误：关闭本次尝试创建的资源并保持
      // 安静，而不是向一个已经走开的调用方上报错误。
      if (_isAbandoned(epoch)) {
        _abandonConnecting(socket: socket, client: client, sftp: sftp);
        return;
      }
      await _cleanup();
      throw SftpException(_translateError(e.toString()));
    }
  }

  /// List directory contents at [path].
  /// 列出 [path] 路径下的目录内容。
  ///
  /// Sorted: directories first, then files; each group alphabetically.
  /// 排序规则：目录在前，文件在后；各自按字母排序。
  Future<List<FileItem>> listDirectory(String path) async {
    _ensureConnected();
    try {
      final entries = await _sftp!.listdir(path);
      final items = entries
          .where((e) => e.filename != '.' && e.filename != '..')
          .map((e) => _toFileItem(e, path))
          .toList();
      items.sort((a, b) {
        if (a.isDirectory && !b.isDirectory) return -1;
        if (!a.isDirectory && b.isDirectory) return 1;
        return a.name.compareTo(b.name);
      });
      return items;
    } catch (e) {
      throw SftpException('列表读取失败：${e.toString()}');
    }
  }

  /// Read full contents of a remote file at [path].
  /// 读取 [path] 路径下远程文件的全部内容。
  Future<Uint8List> readFile(String path) async {
    _ensureConnected();
    try {
      final file = await _sftp!.open(path, mode: SftpFileOpenMode.read);
      try {
        final chunks = await file.read().toList();
        final total = chunks.fold<int>(0, (s, c) => s + c.length);
        final buf = Uint8List(total);
        var offset = 0;
        for (final chunk in chunks) {
          buf.setRange(offset, offset + chunk.length, chunk);
          offset += chunk.length;
        }
        return buf;
      } finally {
        await file.close();
      }
    } catch (e) {
      throw SftpException('文件读取失败：${e.toString()}');
    }
  }

  /// Overwrite a remote file at [path] with [data].
  /// 用 [data] 覆盖写入 [path] 路径下的远程文件。
  Future<void> writeFile(String path, Uint8List data) async {
    _ensureConnected();
    try {
      final file = await _sftp!.open(
        path,
        mode:
            SftpFileOpenMode.write |
            SftpFileOpenMode.create |
            SftpFileOpenMode.truncate,
      );
      try {
        await file.writeBytes(data);
      } finally {
        await file.close();
      }
    } catch (e) {
      throw SftpException('文件写入失败：${e.toString()}');
    }
  }

  /// Delete a file or empty directory at [path].
  /// 删除 [path] 路径下的文件或空目录。
  ///
  /// Tries rmdir first (for directories), then falls back to remove (for files).
  /// 先尝试 rmdir（目录），失败则回退到 remove（文件）。
  Future<void> deleteFile(String path) async {
    _ensureConnected();
    try {
      try {
        await _sftp!.rmdir(path);
      } catch (_) {
        await _sftp!.remove(path);
      }
    } catch (e) {
      throw SftpException('删除失败：${e.toString()}');
    }
  }

  /// Rename / move a remote entry from [oldPath] to [newPath].
  /// 将远程条目从 [oldPath] 重命名或移动到 [newPath]。
  Future<void> rename(String oldPath, String newPath) async {
    _ensureConnected();
    try {
      await _sftp!.rename(oldPath, newPath);
    } catch (e) {
      throw SftpException('重命名失败：${e.toString()}');
    }
  }

  /// Create a directory at [path].
  /// 在 [path] 路径下创建目录。
  Future<void> createDirectory(String path) async {
    _ensureConnected();
    try {
      await _sftp!.mkdir(path);
    } catch (e) {
      throw SftpException('目录创建失败：${e.toString()}');
    }
  }

  /// Gracefully close the SFTP session and underlying SSH connection.
  /// 优雅地关闭 SFTP 会话和底层 SSH 连接。
  ///
  /// Also aborts a [connect] that is still in flight: without the epoch bump a
  /// teardown landing mid-connect would walk past fields that are still null,
  /// and the connect continuation would then publish an authenticated client
  /// and an SFTP subsystem that no one is left to close.
  /// 同时中止仍在进行中的 [connect]：若不递增世代号，中途发生的清理只会看到仍为
  /// null 的字段，随后连接流程就会发布一个已认证的客户端和 SFTP 子系统，
  /// 而再没有对象负责关闭它们。
  Future<void> disconnect() async {
    _connectEpoch++;
    await _cleanup();
  }

  // ---- private helpers / 私有辅助方法 ----

  /// Throws if the SFTP session is not connected.
  /// 若 SFTP 会话未连接则抛出异常。
  void _ensureConnected() {
    if (_sftp == null || _client == null) {
      throw const SftpException('未连接到服务器');
    }
  }

  /// Whether the connect attempt identified by [epoch] was invalidated by a
  /// [disconnect] that landed while it was suspended on an `await`.
  /// 由 [epoch] 标识的连接尝试是否在其挂起期间被 [disconnect] 作废。
  bool _isAbandoned(int epoch) => epoch != _connectEpoch;

  /// Tears down the resources created by a connect attempt that was invalidated
  /// while suspended on an `await` (see [_isAbandoned]).
  /// 清理在 `await` 挂起期间被作废的连接尝试所创建的资源（见 [_isAbandoned]）。
  ///
  /// Only the references passed in are touched: `_sftp` / `_client` are
  /// deliberately left alone, because [disconnect] has already cleared them and
  /// a newer attempt may own them by now.
  /// 只关闭传入的引用；刻意不碰 `_sftp` / `_client`，因为 [disconnect] 已经清空了
  /// 它们，此刻也可能已被更新的尝试占用。
  ///
  /// Each step is guarded on its own: once the transport is closed, closing an
  /// SFTP channel or a client throws (SftpClient.close() completes an
  /// already-completed completer, SSHClient.close() can raise
  /// `SSHStateError('Transport is closed')`), and that must not keep the
  /// remaining resources open.
  /// 每一步单独守护：传输层关闭后再关闭 SFTP 通道或客户端会抛出异常
  /// （SftpClient.close() 会去完成一个已经完成的 completer，SSHClient.close()
  /// 可能抛出 `SSHStateError('Transport is closed')`），不能因此让其余资源继续
  /// 泄漏。
  void _abandonConnecting({
    SSHSocket? socket,
    SSHClient? client,
    SftpClient? sftp,
  }) {
    try {
      sftp?.close();
    } catch (_) {
      // Channel already gone / 通道已不存在。
    }
    try {
      client?.close();
    } catch (_) {
      // Transport already gone / 传输层已不存在。
    }
    // Unlike `close()`, `destroy()` is synchronous, idempotent and does not
    // throw, so it leaves no future behind. Destroying a socket whose transport
    // is already gone is a no-op.
    // 与 `close()` 不同，`destroy()` 是同步、幂等且不抛异常的，不会留下 future。
    // 对传输层已经消失的套接字调用它不会有任何副作用。
    socket?.destroy();
  }

  /// Close SFTP and SSH clients, swallowing exceptions.
  /// 关闭 SFTP 和 SSH 客户端，忽略异常。
  ///
  /// The two closes are guarded separately on purpose: a throw from the SFTP
  /// close must not skip the client close. Both are attempted even when one
  /// objects that its channel is already gone.
  /// 两次关闭刻意各自守护：关闭 SFTP 时抛出的异常不能让客户端的关闭被跳过。
  /// 即使其中一方抱怨通道已不存在，另一方仍会被关闭。
  ///
  /// The fields are cleared before this method returns (it contains no `await`,
  /// so the whole body runs synchronously), which makes repeated calls — one
  /// from [disconnect] and one from a failed [connect] — harmless no-ops.
  /// 本方法返回前会清空字段（方法体中没有 `await`，整体同步执行），因此重复调用
  /// （一次来自 [disconnect]，一次来自失败的 [connect]）是无副作用的空操作。
  Future<void> _cleanup() async {
    try {
      _sftp?.close();
    } catch (_) {
      // SFTP channel already gone / SFTP 通道已不存在。
    }
    try {
      _client?.close();
    } catch (_) {
      // Transport already gone / 传输层已不存在。
    }
    _sftp = null;
    _client = null;
  }

  /// Convert an [SftpName] entry to a [FileItem] for the UI.
  /// 将 [SftpName] 条目转换为供 UI 使用的 [FileItem]。
  FileItem _toFileItem(SftpName entry, String parentPath) {
    final a = entry.attr;
    final fullPath = parentPath.endsWith('/')
        ? '$parentPath${entry.filename}'
        : '$parentPath/${entry.filename}';

    return FileItem(
      name: entry.filename,
      path: fullPath,
      isDirectory: a.isDirectory,
      size: a.size ?? 0,
      permissions: _formatMode(a.mode),
      modifiedDate: a.modifyTime != null
          ? DateTime.fromMillisecondsSinceEpoch(a.modifyTime! * 1000)
          : DateTime.now(),
    );
  }

  /// Format an [SftpFileMode] into a Unix-like permission string (e.g. "rwxr-xr--").
  /// 将 [SftpFileMode] 格式化为类 Unix 权限字符串（如 "rwxr-xr--"）。
  String _formatMode(SftpFileMode? mode) {
    if (mode == null) return '---------';
    return '${mode.userRead ? 'r' : '-'}${mode.userWrite ? 'w' : '-'}${mode.userExecute ? 'x' : '-'}'
        '${mode.groupRead ? 'r' : '-'}${mode.groupWrite ? 'w' : '-'}${mode.groupExecute ? 'x' : '-'}'
        '${mode.otherRead ? 'r' : '-'}${mode.otherWrite ? 'w' : '-'}${mode.otherExecute ? 'x' : '-'}';
  }

  /// Translate raw error strings into user-friendly Chinese messages.
  /// 将原始错误字符串翻译为用户友好的中文消息。
  String _translateError(String error) {
    final lower = error.toLowerCase();
    if (lower.contains('timeout')) return '连接超时，请检查 IP 与防火墙设置';
    if (lower.contains('auth') ||
        lower.contains('password') ||
        lower.contains('key')) {
      return '认证失败，请检查凭据';
    }
    if (lower.contains('refused')) return '连接被拒绝，请检查端口与服务状态';
    if (lower.contains('resolve') || lower.contains('unknown host')) {
      return '无法解析主机地址，请检查 IP 或域名';
    }
    return 'SFTP 连接失败：$error';
  }
}

/// Exception thrown by [SftpService] operations.
/// [SftpService] 操作抛出的异常。
class SftpException implements Exception {
  /// Human-readable error message.
  /// 人类可读的错误信息。
  final String message;
  const SftpException(this.message);
  @override
  String toString() => message;
}
