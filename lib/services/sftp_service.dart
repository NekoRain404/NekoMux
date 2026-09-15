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
  Future<void> connect() async {
    try {
      final socket = await SSHSocket.connect(
        host.ipAddress,
        host.port,
        timeout: const Duration(seconds: 10),
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
        onVerifyHostKey: onHostKeyVerify != null
            ? (type, rawFingerprint) async {
                final fingerprint = HostKeyVerifier.formatMd5(rawFingerprint);
                return onHostKeyVerify!(fingerprint);
              }
            : null,
      );
      await _client!.authenticated;
      _sftp = await _client!.sftp();
    } catch (e) {
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
  Future<void> disconnect() async => _cleanup();

  // ---- private helpers / 私有辅助方法 ----

  /// Throws if the SFTP session is not connected.
  /// 若 SFTP 会话未连接则抛出异常。
  void _ensureConnected() {
    if (_sftp == null || _client == null) {
      throw const SftpException('未连接到服务器');
    }
  }

  /// Close SFTP and SSH clients, swallowing exceptions.
  /// 关闭 SFTP 和 SSH 客户端，忽略异常。
  Future<void> _cleanup() async {
    try {
      _sftp?.close();
    } catch (_) {}
    try {
      _client?.close();
    } catch (_) {}
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
