import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Hardware-backed secure storage wrapper for credential secrets.
/// 基于硬件安全模块的凭证密钥存储封装。
///
/// Keys are namespaced as `cred_$id` so they can be individually managed
/// without collisions.
/// 键以 `cred_$id` 作为命名空间，可独立管理而不会冲突。
///
/// Nothing here writes a message a user reads: each failure carries a
/// [SecureStorageFailure] code, so whoever shows it can word it in the language
/// the user picked. These methods used to throw Chinese sentences
/// ("保存凭证失败：…"), which every user got in Chinese whatever language the app
/// was set to.
/// 本类不书写给用户读的消息：每次失败都携带 [SecureStorageFailure] 编码，展示方因此
/// 可以按用户选定的语言措辞。这些方法过去抛出的是中文句子（“保存凭证失败：…”），无论
/// 应用设成哪种语言，所有用户看到的都是中文。
///
/// The codes have no entry in the i18n table yet and nothing catches these
/// exceptions, so there is no presentation-layer mapper to pair them with — the
/// other half of the split (see `pages/console/ssh_error_text.dart`) needs keys
/// that only the translation table can provide.
/// 这三个编码目前还没有 i18n 表中的条目，也没有任何地方捕获这些异常，因此还没有可与之
/// 配对的展示层映射——这次分工的另一半（见 `pages/console/ssh_error_text.dart`）需要
/// 只有翻译表才能提供的键。
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
      throw SecureStorageException(SecureStorageFailure.save, e.toString());
    }
  }

  /// Read the secret for [id], or null if none exists.
  /// 读取 [id] 对应的密钥，若不存在则返回 null。
  static Future<String?> getCredential(String id) async {
    try {
      return await _storage.read(key: 'cred_$id');
    } catch (e) {
      throw SecureStorageException(SecureStorageFailure.read, e.toString());
    }
  }

  /// Remove the secret for [id]. No-op if it doesn't exist.
  /// 删除 [id] 对应的密钥。若不存在则不做任何事。
  static Future<void> deleteCredential(String id) async {
    try {
      await _storage.delete(key: 'cred_$id');
    } catch (e) {
      throw SecureStorageException(SecureStorageFailure.delete, e.toString());
    }
  }
}

/// What went wrong in a [SecureStorage] operation.
/// [SecureStorage] 的某次操作出了什么问题。
///
/// A machine-readable code, not a sentence.
/// 机器可读的编码，而非句子。
enum SecureStorageFailure {
  /// Writing a credential's secret failed.
  /// 写入凭据密钥失败。
  save,

  /// Reading a credential's secret failed.
  /// 读取凭据密钥失败。
  read,

  /// Removing a credential's secret failed.
  /// 删除凭据密钥失败。
  delete,
}

/// Exception thrown by [SecureStorage] operations.
/// [SecureStorage] 操作抛出的异常。
///
/// Carries a code and the raw detail instead of a message: prose belongs to the
/// language the user chose, and a service that composes it can only compose it
/// in one language.
/// 携带编码与原始细节，而不是消息：文案属于用户选定的语言，而自行组装文案的服务只能
/// 组装出一种语言。
class SecureStorageException implements Exception {
  /// What went wrong.
  /// 出了什么问题。
  final SecureStorageFailure kind;

  /// The underlying error's own rendering (the platform's exception text), never
  /// a sentence this app wrote.
  /// 底层错误自身的呈现（平台的异常文本），绝不是本应用写下的句子。
  final String? detail;

  const SecureStorageException(this.kind, [this.detail]);

  /// Technical rendering of the failure: printable, never displayable.
  /// 失败的技术呈现：可以打印，不能直接展示。
  String get message => detail ?? kind.name;

  @override
  String toString() => detail == null ? kind.name : '${kind.name}: $detail';
}
