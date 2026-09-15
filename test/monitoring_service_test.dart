import 'package:flutter_test/flutter_test.dart';
import 'package:neko_mux/services/monitoring_service.dart';

// ---------------------------------------------------------------------------
// Fixtures
//
// All fixtures below are byte-exact captures of real command output, taken with
// `cat -A` so trailing whitespace / padding is preserved exactly.
// 以下 fixture 均为真实命令输出的逐字节抓取，保留原始空格填充。
// ---------------------------------------------------------------------------

/// `LC_ALL=C free -m`
const String freeOutputC = '''
               total        used        free      shared  buff/cache   available
Mem:          126435       66204       51765        1484       11238       60231
Swap:         163839       33033      130806
''';

/// `LC_ALL=zh_CN.UTF-8 free -m` — gettext-localized labels.
/// Note the full-width colon (U+FF1A) in `内存：` / `交换：`.
const String freeOutputZh = '''
                总计        已用        空闲        共享   缓冲/缓存        可用
内存：        126435       66172       51797        1484       11238       60263
交换：        163839       33033      130806
''';

/// `systemctl list-units --type=service --all --no-pager --no-legend`
/// (two real rows, copied byte-exact — systemd space-pads the columns, so the
/// exact padding is part of the fixture).
const String systemctlOutput = '''
  1panel-agent.service                                                                      loaded    active   running 1Panel, a modern open source linux panel
  alsa-restore.service                                                                      loaded    active   exited  Save/Restore Sound Card State
''';

/// Real `●`-prefixed rows (`--no-legend` does NOT suppress the bullet).
/// NOT-FOUND and FAILED rows are marked by systemd, so these are exactly the
/// rows the user needs to see.
const String systemctlOutputMarked = '''
● drkonqi-coredump-processor@1-8194-5964_25003-0.service                                    loaded    failed   failed  Pass systemd-coredump journal entries to relevant user for potential DrKonqi handling
● apparmor.service                                                                          not-found inactive dead    apparmor.service
''';

/// The same two rows as emitted when the locale has no UTF-8 bullet: systemd
/// falls back to the ASCII `*` marker (`LC_ALL=C systemctl ...`).
const String systemctlOutputMarkedAscii = '''
* drkonqi-coredump-processor@1-8194-5964_25003-0.service                                    loaded    failed   failed  Pass systemd-coredump journal entries to relevant user for potential DrKonqi handling
* apparmor.service                                                                          not-found inactive dead    apparmor.service
''';

/// Returns the parsed service with the given unit name, or null if the parser
/// dropped it.
Map<String, dynamic>? _unitNamed(
  List<Map<String, dynamic>> services,
  String unit,
) {
  for (final service in services) {
    if (service['unit'] == unit) return service;
  }
  return null;
}

void main() {
  group('parseFree', () {
    test('parses the C-locale `free -m` table', () {
      expect(MonitoringService.parseFree(freeOutputC), [126435, 66204, 51765]);
    });

    test('parses the zh_CN-localized `free -m` table', () {
      expect(MonitoringService.parseFree(freeOutputZh), [126435, 66172, 51797]);
    });

    test(
      'does not confuse the header row or the Swap row with the memory row',
      () {
        // Header row: first token non-numeric, following tokens are not numbers.
        // Swap row: also all-numeric, but comes *after* the Mem row.
        final parsed = MonitoringService.parseFree(freeOutputC);
        expect(parsed[0], isNot(0));
        expect(parsed, isNot([163839, 33033, 130806]));
      },
    );
  });

  group('memoryUsagePercentFromFree', () {
    test('reports a non-zero usage for the C-locale fixture', () {
      expect(
        MonitoringService.memoryUsagePercentFromFree(freeOutputC),
        closeTo(52.4, 0.1),
      );
    });

    test('reports ~52.3% for the zh_CN fixture', () {
      expect(
        MonitoringService.memoryUsagePercentFromFree(freeOutputZh),
        closeTo(52.3, 0.1),
      );
    });
  });

  group('parseSystemctl — SUB / DESCRIPTION column boundary', () {
    test(
      'keeps a one-space-padded SUB out of the description (running service)',
      () {
        // systemd pads SUB so that the 7-character state "running" is followed
        // by a single space before the description.
        final service = _unitNamed(
          MonitoringService.parseSystemctl(systemctlOutput),
          '1panel-agent.service',
        );
        expect(
          service,
          isNotNull,
          reason: 'running service row was dropped by the parser',
        );
        expect(service!['load'], 'loaded');
        expect(service['active'], 'active');
        expect(service['sub'], 'running');
        expect(
          service['description'],
          '1Panel, a modern open source linux panel',
        );
      },
    );

    test('still parses rows whose description is separated by two spaces', () {
      final service = _unitNamed(
        MonitoringService.parseSystemctl(systemctlOutput),
        'alsa-restore.service',
      );
      expect(service, isNotNull);
      expect(service!['active'], 'active');
      expect(service['sub'], 'exited');
      expect(service['description'], 'Save/Restore Sound Card State');
    });
  });

  group('parseSystemctl — ●-prefixed (failed / not-found) rows', () {
    test('returns marked rows instead of discarding them', () {
      final services = MonitoringService.parseSystemctl(systemctlOutputMarked);
      expect(services.map((s) => s['unit']).toList(), [
        'drkonqi-coredump-processor@1-8194-5964_25003-0.service',
        'apparmor.service',
      ]);
    });

    test('parses a marked failed unit (active == failed)', () {
      final service = _unitNamed(
        MonitoringService.parseSystemctl(systemctlOutputMarked),
        'drkonqi-coredump-processor@1-8194-5964_25003-0.service',
      );
      expect(service, isNotNull, reason: '● failed row was dropped');
      expect(service!['load'], 'loaded');
      expect(service['active'], 'failed');
      expect(service['sub'], 'failed');
      expect(
        service['description'],
        'Pass systemd-coredump journal entries to relevant user for potential DrKonqi handling',
      );
    });

    test('parses a marked not-found unit whose LOAD/ACTIVE/SUB overflow into '
        'single spaces', () {
      final service = _unitNamed(
        MonitoringService.parseSystemctl(systemctlOutputMarked),
        'apparmor.service',
      );
      expect(service, isNotNull, reason: '● not-found row was dropped');
      expect(service!['load'], 'not-found');
      expect(service['active'], 'inactive');
      expect(service['sub'], 'dead');
      expect(service['description'], 'apparmor.service');
    });

    test('handles the ASCII * marker systemd emits under LC_ALL=C', () {
      final services = MonitoringService.parseSystemctl(
        systemctlOutputMarkedAscii,
      );
      expect(services.length, 2);
      expect(
        services.first['unit'],
        'drkonqi-coredump-processor@1-8194-5964_25003-0.service',
      );
      expect(services.first['active'], 'failed');
      expect(services.last['unit'], 'apparmor.service');
      expect(services.last['load'], 'not-found');
    });
  });
}
