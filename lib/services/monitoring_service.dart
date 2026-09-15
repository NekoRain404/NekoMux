import 'dart:async';
import 'ssh_service.dart';

/// SSH-based remote system monitoring helper.
///
/// Provides static methods to execute commands via an existing [SshConnection]
/// and parse common Linux monitoring command outputs.
class MonitoringService {
  MonitoringService._(); // prevent instantiation / 防止实例化

  // ===========================================================================
  // Exec
  // ===========================================================================

  /// Execute a command via an existing SSH connection and return stdout as a string.
  /// Uses a separate exec channel so it doesn't interfere with the persistent shell.
  /// 通过已有 SSH 连接执行命令并返回 stdout 字符串。
  /// 使用独立的 exec 通道，不会干扰持久化 shell。
  static Future<String> exec(SshConnection conn, String cmd) async {
    return await conn.executeCommand(cmd);
  }

  // ===========================================================================
  // top
  // ===========================================================================

  /// Parse `top -b -n 1` output and return [cpuPercent, memPercent].
  /// 解析 top 输出并返回 [CPU使用率%, 内存使用率%]。
  ///
  /// Sample input line (3rd non-empty line, e.g.):
  ///   %Cpu(s): 12.3 us,  5.1 sy,  0.0 ni, 82.0 id,  0.1 wa, ...
  ///   MiB Mem :  7821.2 total,  3456.7 free,  1890.1 used, ...
  ///
  /// CPU % = 100 – idle%.  MEM % = used / total × 100.
  /// CPU% = 100 – idle值。 内存% = 已用 / 总量 × 100。
  static List<double> parseTop(String output) {
    double cpu = 0.0;
    double mem = 0.0;
    final lines = output.split('\n');

    for (final line in lines) {
      // Parse CPU line: "%Cpu(s):  ... id,"
      // 解析 CPU 行："%Cpu(s):  ... id,"
      if (line.startsWith('%Cpu')) {
        final idMatch = RegExp(r'(\d+\.?\d*)\s*id').firstMatch(line);
        if (idMatch != null) {
          final idle = double.tryParse(idMatch.group(1)!) ?? 0;
          cpu = (100.0 - idle).clamp(0.0, 100.0);
        }
      }

      // Parse memory line: "MiB Mem :  total,  free,  used,  buff/cache"
      // 解析内存行："MiB Mem :  total,  free,  used,  buff/cache"
      if (line.contains('Mem') && line.contains('total')) {
        final totalMatch = RegExp(r'(\d+\.?\d*)\s+total').firstMatch(line);
        final usedMatch = RegExp(r'(\d+\.?\d*)\s+used').firstMatch(line);
        if (totalMatch != null && usedMatch != null) {
          final total = double.tryParse(totalMatch.group(1)!) ?? 1;
          final used = double.tryParse(usedMatch.group(1)!) ?? 0;
          mem = (used / total * 100.0).clamp(0.0, 100.0);
        }
      }
    }

    return [cpu, mem];
  }

  static CpuTimes? parseProcStat(String output) {
    final line = output
        .split('\n')
        .map((l) => l.trim())
        .firstWhere((l) => l.startsWith('cpu '), orElse: () => '');
    if (line.isEmpty) return null;

    final parts = line.split(RegExp(r'\s+'));
    if (parts.length < 8) return null;

    final values = parts
        .skip(1)
        .map((p) => int.tryParse(p) ?? 0)
        .toList(growable: false);
    if (values.length < 7) return null;

    final idle = values[3] + values[4];
    final total = values.fold<int>(0, (sum, value) => sum + value);
    return CpuTimes(idle: idle, total: total);
  }

  static double cpuUsageBetween(CpuTimes previous, CpuTimes current) {
    final totalDelta = current.total - previous.total;
    final idleDelta = current.idle - previous.idle;
    if (totalDelta <= 0) return 0;
    return ((totalDelta - idleDelta) / totalDelta * 100).clamp(0.0, 100.0);
  }

  static double memoryUsagePercentFromFree(String output) {
    final memory = parseFree(output);
    final total = memory[0];
    final used = memory[1];
    if (total <= 0) return 0;
    return (used / total * 100).clamp(0.0, 100.0);
  }

  // ===========================================================================
  // free
  // ===========================================================================

  /// Parse `free -m` output and return [totalMB, usedMB, freeMB].
  /// 解析 free 输出并返回 [总量MB, 已用MB, 空闲MB]。
  ///
  /// Sample line (2nd row = Mem):
  ///   Mem:      7821        1890        3456         ...
  static List<int> parseFree(String output) {
    int total = 0, used = 0, free = 0;
    final lines = output.split('\n');

    for (final line in lines) {
      if (line.startsWith('Mem:')) {
        final parts = line.trim().split(RegExp(r'\s+'));
        if (parts.length >= 4) {
          // parts[0]="Mem:", parts[1]=total, parts[2]=used, parts[3]=free
          total = int.tryParse(parts[1]) ?? 0;
          used = int.tryParse(parts[2]) ?? 0;
          free = int.tryParse(parts[3]) ?? 0;
        }
        break;
      }
    }

    return [total, used, free];
  }

  // ===========================================================================
  // ps
  // ===========================================================================

  /// Parse `ps aux --sort=-%cpu | head -21` and return a list of process maps.
  /// 解析 ps 输出并返回进程映射列表。
  ///
  /// Each map contains: pid, user, cpu, mem, vsz, rss, tty, stat, start, time, command.
  /// 每个映射包含：pid、user、cpu、mem、vsz、rss、tty、stat、start、time、command。
  ///
  /// Columns from `ps aux`:
  ///   USER PID %CPU %MEM VSZ RSS TTY STAT START TIME COMMAND
  static List<Map<String, dynamic>> parsePs(String output) {
    final lines = output.trim().split('\n');
    final results = <Map<String, dynamic>>[];

    // Skip header line "USER       PID %CPU %MEM ..."
    // 跳过标题行
    for (int i = 1; i < lines.length; i++) {
      final line = lines[i].trim();
      if (line.isEmpty) continue;

      // Split by whitespace, max 11 parts (last is COMMAND which may contain spaces)
      // 按空白分割，最多 11 部分（最后是 COMMAND，可能包含空格）
      final parts = line.split(RegExp(r'\s+'));
      if (parts.length < 11) continue;

      try {
        results.add({
          'user': parts[0],
          'pid': int.tryParse(parts[1]) ?? 0,
          'cpu': double.tryParse(parts[2]) ?? 0.0,
          'mem': double.tryParse(parts[3]) ?? 0.0,
          'vsz': int.tryParse(parts[4]) ?? 0,
          'rss': int.tryParse(parts[5]) ?? 0,
          'tty': parts[6],
          'stat': parts[7],
          'start': parts[8],
          'time': parts[9],
          'command': parts.sublist(10).join(' '),
        });
      } catch (_) {
        // skip malformed lines / 跳过格式异常的行
      }
    }

    return results;
  }

  // ===========================================================================
  // systemctl
  // ===========================================================================

  /// Parse `systemctl list-units --type=service --all --no-pager --no-legend`
  /// output and return a list of service maps.
  /// 解析 systemctl 输出并返回服务映射列表。
  ///
  /// Columns:
  ///   UNIT LOAD ACTIVE SUB DESCRIPTION
  /// Sample:
  ///   ssh.service loaded active running OpenBSD Secure Shell server
  ///
  /// Each map contains: unit, load, active, sub, description.
  /// 每个映射包含：unit、load、active、sub、description。
  static List<Map<String, dynamic>> parseSystemctl(String output) {
    final lines = output.trim().split('\n');
    final results = <Map<String, dynamic>>[];

    for (final rawLine in lines) {
      final line = rawLine.trim();
      if (line.isEmpty) continue;
      // Skip lines starting with ● (bullet) or empty
      // 跳过以 ● 开头的行或空行
      if (line.startsWith('●') || line.startsWith('*')) continue;

      // Systemd output uses fixed-width columns. Split by 2+ spaces.
      // systemd 输出使用定宽列，按 2+ 空格分割
      final parts = line.split(RegExp(r'\s{2,}'));
      if (parts.length < 4) continue;

      try {
        results.add({
          'unit': parts[0].trim(),
          'load': parts[1].trim(),
          'active': parts[2].trim(),
          'sub': parts[3].trim(),
          'description': parts.length > 4
              ? parts.sublist(4).join(' ').trim()
              : '',
        });
      } catch (_) {
        // skip malformed lines / 跳过格式异常的行
      }
    }

    return results;
  }
}

class CpuTimes {
  final int idle;
  final int total;

  const CpuTimes({required this.idle, required this.total});
}
