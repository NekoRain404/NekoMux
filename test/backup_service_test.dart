// Unit tests for the backup payload helpers used by Settings → Export / Restore.
// 设置 → 导出 / 恢复所用备份载荷辅助函数的单元测试。
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:neko_mux/models/credential.dart';
import 'package:neko_mux/services/backup_service.dart';

/// A realistic backup payload, shaped exactly like the live database rows.
/// 一份真实形态的备份载荷，结构与数据库行完全一致。
List<Map<String, dynamic>> _hostRows() => [
  {
    'id': 'h1',
    'alias': 'web-01',
    'ip_address': '10.0.0.1',
    'port': 22,
    'credential_id': 'c1',
    'os_type': 0,
  },
  {
    'id': 'h2',
    'alias': 'db-01',
    'ip_address': '10.0.0.2',
    'port': 2222,
    'credential_id': 'c2',
    'os_type': 1,
  },
];

List<Map<String, dynamic>> _snippetRows() => [
  {'id': 's1', 'title': 'Disk usage', 'command': 'df -h'},
  {'id': 's2', 'title': 'Top procs', 'command': 'ps aux --sort=-%cpu | head'},
];

/// Built the way the page builds it: Credential.toBackupMap() per row.
List<Map<String, dynamic>> _credentialRows() => [
  const Credential(
    id: 'c1',
    name: 'root',
    authType: 0,
    username: 'root',
    secretData: 'hunter2',
  ).toBackupMap(),
  const Credential(
    id: 'c2',
    name: 'deploy',
    authType: 1,
    username: 'deploy',
    secretData: '-----BEGIN OPENSSH PRIVATE KEY-----',
  ).toBackupMap(),
];

void main() {
  group('BackupSection', () {
    test('canonical keys are pinned to the on-the-wire format', () {
      expect(BackupSection.hosts.key, 'hosts');
      expect(BackupSection.credentials.key, 'credentials');
      expect(BackupSection.snippets.key, 'snippets');
    });

    test('每节都带有对应的数据库表名', () {
      expect(BackupSection.hosts.table, 'tb_hosts');
      expect(BackupSection.credentials.table, 'tb_credentials');
      expect(BackupSection.snippets.table, 'tb_snippets');
    });
  });

  group('buildExportPayload', () {
    test('writes every section under its canonical key', () {
      final payload = buildExportPayload(
        hosts: _hostRows(),
        credentials: _credentialRows(),
        snippets: _snippetRows(),
        exportedAt: DateTime.utc(2026, 1, 2, 3, 4, 5),
      );

      expect(payload['version'], backupPayloadVersion);
      expect(payload['exported_at'], '2026-01-02T03:04:05.000Z');
      expect(payload['hosts'], _hostRows());
      expect(payload['credentials'], _credentialRows());
      expect(payload['snippets'], _snippetRows());
    });

    test('uses the same key names readBackupRows looks up', () {
      final payload = buildExportPayload(
        hosts: _hostRows(),
        credentials: _credentialRows(),
        snippets: _snippetRows(),
      );

      for (final section in BackupSection.values) {
        expect(
          payload.containsKey(section.key),
          isTrue,
          reason: 'export must write the key restore reads: ${section.key}',
        );
      }
    });

    test(
      'serializes to a JSON object that still carries all three sections',
      () {
        final payload = buildExportPayload(
          hosts: _hostRows(),
          credentials: _credentialRows(),
          snippets: _snippetRows(),
        );

        final decoded = jsonDecode(jsonEncode(payload)) as Map<String, dynamic>;
        expect(decoded.keys, containsAll(['version', 'exported_at']));
        expect(decoded['hosts'], hasLength(2));
        expect(decoded['credentials'], hasLength(2));
        expect(decoded['snippets'], hasLength(2));
      },
    );
  });

  group('round trip (the regression that caused silent data loss)', () {
    test(
      'EXPORT → JSON text → PARSE → readBackupRows returns every section',
      () {
        // Exactly what Settings → Export Backup produces, then what the user
        // pastes back into Settings → Restore Backup.
        final exported = buildExportPayload(
          hosts: _hostRows(),
          credentials: _credentialRows(),
          snippets: _snippetRows(),
        );
        final clipboardText = const JsonEncoder.withIndent(
          '  ',
        ).convert(exported);

        final parsed = parseBackupPayload(clipboardText);

        expect(
          readBackupRows(parsed, BackupSection.hosts),
          _hostRows(),
          reason: 'hosts must survive the export → restore round trip',
        );
        expect(
          readBackupRows(parsed, BackupSection.credentials),
          _credentialRows(),
          reason: 'credentials must survive the export → restore round trip',
        );
        expect(
          readBackupRows(parsed, BackupSection.snippets),
          _snippetRows(),
          reason: 'snippets must survive the export → restore round trip',
        );
      },
    );

    test('an empty section round trips as empty, not as an error', () {
      final exported = buildExportPayload(
        hosts: const [],
        credentials: const [],
        snippets: const [],
      );

      final parsed = parseBackupPayload(jsonEncode(exported));

      for (final section in BackupSection.values) {
        expect(readBackupRows(parsed, section), isEmpty);
      }
    });
  });

  group('readBackupRows', () {
    test('accepts a legacy payload keyed by table name', () {
      final legacy = <String, dynamic>{
        'version': 1,
        'tb_hosts': _hostRows(),
        'tb_credentials': _credentialRows(),
        'tb_snippets': _snippetRows(),
      };

      expect(readBackupRows(legacy, BackupSection.hosts), _hostRows());
      expect(
        readBackupRows(legacy, BackupSection.credentials),
        _credentialRows(),
      );
      expect(readBackupRows(legacy, BackupSection.snippets), _snippetRows());
    });

    test('prefers the canonical key when both are present', () {
      final both = <String, dynamic>{
        'hosts': _hostRows(),
        'tb_hosts': const <Map<String, dynamic>>[],
      };

      expect(readBackupRows(both, BackupSection.hosts), _hostRows());
    });

    test('throws when a section is missing entirely', () {
      expect(
        () => readBackupRows(<String, dynamic>{
          'version': 1,
        }, BackupSection.hosts),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('hosts'),
          ),
        ),
      );
    });

    test('throws when a section is not a list', () {
      expect(
        () => readBackupRows(<String, dynamic>{
          'hosts': 'nope',
        }, BackupSection.hosts),
        throwsA(isA<FormatException>()),
      );
    });

    test('throws when a row is not a map', () {
      expect(
        () => readBackupRows(<String, dynamic>{
          'hosts': [
            {'id': 'h1'},
            'nope',
          ],
        }, BackupSection.hosts),
        throwsA(isA<FormatException>()),
      );
    });

    test('返回可写给数据库的 Map<String, dynamic> 行', () {
      final rows = readBackupRows(<String, dynamic>{
        'hosts': [
          {'id': 'h1', 'port': 22},
        ],
      }, BackupSection.hosts);

      expect(rows.single, isA<Map<String, dynamic>>());
      expect(rows.single['id'], 'h1');
    });
  });

  group('parseBackupPayload', () {
    test('parses a JSON object', () {
      expect(parseBackupPayload('{"hosts": []}'), {'hosts': <dynamic>[]});
    });

    test('throws a meaningful error when the JSON is not an object', () {
      expect(
        () => parseBackupPayload('[1, 2, 3]'),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('object'),
          ),
        ),
      );
    });

    test('throws a meaningful error when the text is not JSON', () {
      expect(
        () => parseBackupPayload('not json at all'),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('JSON'),
          ),
        ),
      );
    });
  });
}
