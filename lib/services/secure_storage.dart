import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Hardware-backed secure storage wrapper for credential secrets.
/// 基于硬件安全模块的凭证密钥存储封装。
///
/// Keys are namespaced as `cred_$id` so they can be individually managed
/// without collisions.
/// 键以 `cred_$id` 作为命名空间，可独立管理而不会冲突。
class SecureStorage {
  /// Shared [FlutterSecureStorage] instance.
  /// 共享的 [FlutterSecureStorage] 实例。
  static const _storage = FlutterSecureStorage();

  /// Persist [secretData] under the key `cred_$id`.
  /// 将 [secretData] 以键 `cred_$id` 持久化存储。
  static Future<void> saveCredential(String id, String secretData) async {
    try {
      await _storage.write(key: 'cred_$id', value: secretData);
    } catch (e) {
      throw SecureStorageException('保存凭证失败：${e.toString()}');
    }
  }

  /// Read the secret for [id], or null if none exists.
  /// 读取 [id] 对应的密钥，若不存在则返回 null。
  static Future<String?> getCredential(String id) async {
    try {
      return await _storage.read(key: 'cred_$id');
    } catch (e) {
      throw SecureStorageException('读取凭证失败：${e.toString()}');
    }
  }

  /// Remove the secret for [id]. No-op if it doesn't exist.
  /// 删除 [id] 对应的密钥。若不存在则不做任何事。
  static Future<void> deleteCredential(String id) async {
    try {
      await _storage.delete(key: 'cred_$id');
    } catch (e) {
      throw SecureStorageException('删除凭证失败：${e.toString()}');
    }
  }
}

/// Exception thrown by [SecureStorage] operations.
/// [SecureStorage] 操作抛出的异常。
class SecureStorageException implements Exception {
  /// Human-readable error message.
  /// 人类可读的错误信息。
  final String message;
  const SecureStorageException(this.message);
  @override
  String toString() => message;
}
