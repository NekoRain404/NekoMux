// Secret-handling policy for the Settings → Export / Restore backup payload.
// 设置 → 导出 / 恢复备份载荷的密钥处置策略。
//
// `services/backup_service.dart` owns the *shape* of a payload — which key each
// section is written under. This file owns the other half: what a credential row
// may carry on its way out, and what counts as a real secret on its way back in.
// It lives outside the page so that "a default export carries no password and no
// private key" is a rule with a single definition that a test can call directly,
// with no widget tree and no clipboard involved.
// `services/backup_service.dart` 负责载荷的*结构*——每一节写在哪个键下。本文件
// 负责另一半：凭据行导出时允许携带什么，恢复时什么才算真正的密钥。它放在页面之外，
// 使「默认导出不含密码与私钥」这条规则只有一处定义，测试可以直接调用，无需控件树
// 与剪贴板。
import '../../models/credential.dart';

/// The literal stored in `tb_credentials.secret_data` in place of the secret
/// itself, which lives in secure storage (Android Keystore-backed).
/// 数据库中代替真正密钥存储的字面值；真正的密钥保存在安全存储（Android Keystore
/// 支撑）中。
const String secretStoragePlaceholder = 'secure_storage';

/// The credential rows to write into an exported backup.
/// 写入导出备份的凭据行。
///
/// [includeSecrets] is the user's explicit opt-in, taken from a checkbox in the
/// export dialog. Only when it is true does a row carry the decrypted password
/// or the full PEM private key (`Credential.toBackupMap`).
/// [includeSecrets] 是用户在导出对话框中勾选的显式选择。只有为真时，行才携带解密后
/// 的密码或完整的 PEM 私钥（`Credential.toBackupMap`）。
///
/// By default each row is `Credential.toMap` — byte for byte what the database
/// holds, with [secretStoragePlaceholder] where the secret would be. So the
/// default export puts no usable credential anywhere, and the rows it does carry
/// are exactly the rows the restore path already knows how to insert.
/// 默认情况下每行取 `Credential.toMap`——与数据库中的内容完全一致，密钥位置是
/// [secretStoragePlaceholder]。因此默认导出不会产生任何可用凭据，而它携带的行
/// 恰好就是恢复流程已经知道如何写回的行。
List<Map<String, dynamic>> backupCredentialRows(
  Iterable<Credential> credentials, {
  required bool includeSecrets,
}) => [
  for (final c in credentials)
    if (includeSecrets) c.toBackupMap() else c.toMap(),
];

/// The secret a credential row coming back from a backup asks to be written to
/// secure storage, or null when the row carries none.
/// 备份中回来的凭据行要求写入安全存储的密钥；该行不含密钥时返回 null。
///
/// This is the single definition the restore path applies before it touches
/// secure storage: a missing, empty or placeholder `secret_data` is not a
/// secret, so it is skipped rather than written. It is the exact complement of
/// what [backupCredentialRows] writes, so a secret-free backup restores its
/// credential metadata without writing to — or wiping — the credentials already
/// on the device.
/// 这是恢复流程写入安全存储之前所用的唯一定义：`secret_data` 缺失、为空或等于占位
/// 值时都不算密钥，会被跳过而不是写入。它与 [backupCredentialRows] 写入的内容严格
/// 互补，因此不含密钥的备份只恢复凭据元数据，既不写入、也不会抹掉设备上已有的凭据。
String? backupSecretToStore(Map<String, dynamic> row) {
  final secret = row['secret_data'] as String?;
  if (secret == null || secret.isEmpty || secret == secretStoragePlaceholder) {
    return null;
  }
  return secret;
}
