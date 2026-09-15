// Tests for the secret policy behind Settings → Export Backup.
// 设置 → 导出备份所用密钥策略的测试。
//
// The defect these guard (audit sec-2): the export wrote every decrypted password
// and full PEM private key into the system clipboard, through the same
// Clipboard.setData path as any harmless text, while the success message said
// only "exported". Three rules have to hold now:
//   1. the default export carries no usable credential;
//   2. only an explicit opt-in changes that;
//   3. a secret-free export still restores — the placeholder it carries is
//      exactly the value the restore path treats as "no secret".
// 这些测试守护的缺陷（审计 sec-2）：导出曾把每个解密后的密码与完整 PEM 私钥经由与
// 普通文本相同的 Clipboard.setData 写进系统剪贴板，而成功提示只说「已导出」。如今
// 必须成立三条规则：
//   1. 默认导出不含任何可用凭据；
//   2. 只有显式选择才会改变这一点；
//   3. 不含密钥的导出仍能恢复——它携带的占位值正是恢复流程视为「没有密钥」的值。
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:neko_mux/models/credential.dart';
import 'package:neko_mux/pages/settings/backup_credentials.dart';
import 'package:neko_mux/services/backup_service.dart';

/// A secret that must never show up in a default export.
/// 绝不应出现在默认导出中的密钥。
const String _password = 'hunter2-correct-horse-battery-staple';

/// A private key that must never show up in a default export.
/// 绝不应出现在默认导出中的私钥。
const String _privateKey =
    '-----BEGIN OPENSSH PRIVATE KEY-----\n'
    'b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAAB\n'
    '-----END OPENSSH PRIVATE KEY-----';

List<Credential> _credentials() => const [
  Credential(
    id: 'c1',
    name: 'root',
    authType: 0,
    username: 'root',
    secretData: _password,
  ),
  Credential(
    id: 'c2',
    name: 'deploy',
    authType: 1,
    username: 'deploy',
    secretData: _privateKey,
  ),
];

List<Map<String, dynamic>> _hostRows() => [
  {
    'id': 'h1',
    'alias': 'web-01',
    'ip_address': '10.0.0.1',
    'port': 22,
    'credential_id': 'c1',
    'os_type': 0,
  },
];

List<Map<String, dynamic>> _snippetRows() => [
  {'id': 's1', 'title': 'Disk usage', 'command': 'df -h'},
];

/// The payload the page builds for one of the two export kinds.
/// 页面对两种导出之一所构建的载荷。
Map<String, dynamic> _export({required bool includeSecrets}) =>
    buildExportPayload(
      hosts: _hostRows(),
      credentials: backupCredentialRows(
        _credentials(),
        includeSecrets: includeSecrets,
      ),
      snippets: _snippetRows(),
      exportedAt: DateTime.utc(2026, 9, 15, 12),
    );

/// Exactly what the page hands to Clipboard.setData.
/// 页面交给 Clipboard.setData 的文本。
String _clipboardText(Map<String, dynamic> payload) =>
    const JsonEncoder.withIndent('  ').convert(payload);

void main() {
  group('default export (opt-in box left unticked)', () {
    test('每行携带占位值而不是密钥', () {
      final rows = backupCredentialRows(_credentials(), includeSecrets: false);

      expect(rows, hasLength(2));
      for (final row in rows) {
        expect(
          row['secret_data'],
          secretStoragePlaceholder,
          reason: 'row ${row['id']} must carry the placeholder the db holds',
        );
      }
    });

    test('the clipboard text contains no password and no private key', () {
      final text = _clipboardText(_export(includeSecrets: false));

      expect(text, isNot(contains(_password)));
      expect(text, isNot(contains('BEGIN OPENSSH PRIVATE KEY')));
      expect(text, isNot(contains('b3BlbnNzaC1rZXktdjE')));
    });

    test('it still carries the credential metadata a user needs', () {
      final text = _clipboardText(_export(includeSecrets: false));

      expect(text, contains('root'));
      expect(text, contains('deploy'));
      expect(text, contains('web-01'));
      expect(text, contains('df -h'));
    });

    test('rows have the same columns as the rows restore inserts', () {
      final restoredShape = _credentials().first.toBackupMap().keys.toSet();
      final exported = backupCredentialRows(
        _credentials(),
        includeSecrets: false,
      );

      for (final row in exported) {
        expect(row.keys.toSet(), restoredShape);
      }
    });
  });

  group('opt-in export', () {
    test('carries the decrypted secret only when asked for', () {
      final rows = backupCredentialRows(_credentials(), includeSecrets: true);

      expect(rows[0]['secret_data'], _password);
      expect(rows[1]['secret_data'], _privateKey);
    });

    test('the two kinds differ in the credentials section alone', () {
      final plain = _export(includeSecrets: false);
      final full = _export(includeSecrets: true);

      expect(plain['hosts'], full['hosts']);
      expect(plain['snippets'], full['snippets']);
      expect(plain['version'], full['version']);
      expect(plain['credentials'], isNot(full['credentials']));
    });
  });

  group('a secret-free export restores correctly', () {
    test(
      'every credential row reads back as "nothing to write to secure storage"',
      () {
        // Export → clipboard text → paste → parse → read rows: the exact path
        // Settings → Restore takes.
        // 导出 → 剪贴板文本 → 粘贴 → 解析 → 读行：即「设置 → 恢复」所走的路径。
        final parsed = parseBackupPayload(
          _clipboardText(_export(includeSecrets: false)),
        );
        final rows = readBackupRows(parsed, BackupSection.credentials);

        expect(rows, hasLength(2));
        for (final row in rows) {
          expect(
            backupSecretToStore(row),
            isNull,
            reason: 'row ${row['id']} must not write over secure storage',
          );
        }
      },
    );

    test('hosts and snippets round trip unchanged', () {
      final parsed = parseBackupPayload(
        _clipboardText(_export(includeSecrets: false)),
      );

      expect(readBackupRows(parsed, BackupSection.hosts), _hostRows());
      expect(readBackupRows(parsed, BackupSection.snippets), _snippetRows());
    });

    test('a restored row is the original row with the secret held back', () {
      final parsed = parseBackupPayload(
        _clipboardText(_export(includeSecrets: false)),
      );
      final row = readBackupRows(parsed, BackupSection.credentials).first;

      expect(row['id'], 'c1');
      expect(row['name'], 'root');
      expect(row['auth_type'], 0);
      expect(row['username'], 'root');
      expect(row['secret_data'], secretStoragePlaceholder);
    });

    test('the opt-in export does ask for the secrets to be written', () {
      final parsed = parseBackupPayload(
        _clipboardText(_export(includeSecrets: true)),
      );
      final rows = readBackupRows(parsed, BackupSection.credentials);

      expect(rows.map(backupSecretToStore), [_password, _privateKey]);
    });
  });

  group('backupSecretToStore', () {
    test('treats missing, empty and placeholder secrets as none', () {
      expect(backupSecretToStore({'id': 'c1'}), isNull);
      expect(backupSecretToStore({'id': 'c1', 'secret_data': ''}), isNull);
      expect(
        backupSecretToStore({
          'id': 'c1',
          'secret_data': secretStoragePlaceholder,
        }),
        isNull,
      );
    });

    test('passes a real secret through untouched', () {
      expect(
        backupSecretToStore({'id': 'c1', 'secret_data': _password}),
        _password,
      );
    });
  });
}
