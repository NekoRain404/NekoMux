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
  ///
  /// Kept for callers that only want the text, but it **discards the exit
  /// status** ([SshConnection.executeCommand] throws it away), so a command that
  /// failed returns whatever it managed to print — an empty string, for a
  /// listing — and the caller cannot tell that apart from a command that
  /// succeeded and printed nothing. A listing that has to be judged (the process
  /// and service managers, the container page) therefore goes through
  /// [SshConnection.runCommand] and `CommandResult.ok` instead; this method is
  /// left in place, working, for any caller that has not been converted. Those
  /// three pages were the only callers in this app, so it currently has none.
  /// 为只想要文本的调用方保留，但它**丢弃退出状态**
  /// （[SshConnection.executeCommand] 会把它扔掉）：失败的命令会返回它勉强打印出的
  /// 内容——对列表命令而言就是空字符串——调用方无法把它与「成功但无输出」区分开。
  /// 因此需要判断成败的列表（进程管理、服务管理、容器页）改走
  /// [SshConnection.runCommand] 与 `CommandResult.ok`；本方法为尚未改造的调用方原样
  /// 保留并保持可用。这三个页面是本应用内仅有的调用方，因此它目前没有调用方。
  static Future<String> exec(SshConnection conn, String cmd) async {
    return await conn.executeCommand(cmd);
  }

  // ===========================================================================
  // proc / free
  // ===========================================================================

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
  /// Sample rows:
  ///   Mem:      7821        1890        3456         ...
  ///   内存：     7821        1890        3456         ...
  ///
  /// The row label is gettext-localized ("Mem:" in the C locale, "内存：" in
  /// zh_CN, …), so the memory row is located structurally instead of by name:
  /// it is the first row whose leading token is a non-numeric label followed by
  /// three integers (total, used, free). The header row is skipped because its
  /// trailing tokens are words, and the Swap row because it comes later.
  /// 行标签会被 gettext 本地化（C 环境为 "Mem:"，zh_CN 为 "内存："），
  /// 因此按结构而非名称定位内存行：首个 token 为非数字标签、其后三个 token
  /// 均为整数。表头行因后续 token 不是数字而被跳过，Swap 行因位置靠后被跳过。
  static List<int> parseFree(String output) {
    for (final line in output.split('\n')) {
      final parts = line.trim().split(RegExp(r'\s+'));
      // Need a label plus at least total/used/free.
      // 至少需要标签 + total/used/free 三个数字。
      if (parts.length < 4) continue;
      // A numeric first token cannot be a row label (e.g. wrap-around output).
      // 首个 token 为数字时不是行标签。
      if (int.tryParse(parts[0]) != null) continue;

      final total = int.tryParse(parts[1]);
      final used = int.tryParse(parts[2]);
      final free = int.tryParse(parts[3]);
      if (total == null || used == null || free == null) continue;

      return [total, used, free];
    }

    return [0, 0, 0];
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
      var line = rawLine.trim();
      if (line.isEmpty) continue;
      // systemd marks failed / not-found units with a bullet in the first
      // column, and --no-legend does not suppress it. That marker is not one of
      // the columns, so strip it and parse the row like any other — dropping
      // marked rows would hide exactly the units the user is looking for.
      // The marker is U+25CF where the locale can render it, with an ASCII '*'
      // fallback otherwise (e.g. LC_ALL=C).
      // 失败/未找到的单元首列带项目符号，--no-legend 不会去掉它。该符号不属于
      // 任何列，应剥离后照常解析；丢弃这些行会恰好隐藏用户最关心的单元。
      // UTF-8 环境下为 U+25CF，否则回退为 ASCII '*'（如 LC_ALL=C）。
      if (line.startsWith('●') || line.startsWith('*')) {
        line = line.substring(1).trimLeft();
        if (line.isEmpty) continue;
      }

      // The columns are space-padded, but the padding is not uniform: systemd
      // sizes each column to its widest value, so a 7-character SUB such as
      // "running" is followed by a SINGLE space before the description, while
      // "exited" is followed by two. Splitting on runs of 2+ spaces therefore
      // folds SUB into DESCRIPTION for "running" — and a row whose LOAD/ACTIVE/
      // SUB all overflow their padding ("not-found inactive dead") is merged
      // into a single field. UNIT, LOAD, ACTIVE and SUB are always single
      // whitespace-free tokens (unit names escape spaces as \x20), so tokenise
      // the row instead: the first four tokens are the columns, everything
      // after them is the description.
      // 各列以空格填充，但填充宽度不一致：7 字符的 SUB（如 "running"）后只有
      // 一个空格，而 "exited" 后有两个，因此按 2+ 空格切分会把 SUB 并入
      // DESCRIPTION；当 LOAD/ACTIVE/SUB 均超出列宽时（"not-found inactive
      // dead"）还会被并成一个字段。UNIT/LOAD/ACTIVE/SUB 都是不含空格的独立
      // token，故改为按空白分词：前四个 token 为各列，其余为描述。
      final parts = line.split(RegExp(r'\s+'));
      if (parts.length < 4) continue;

      try {
        results.add({
          'unit': parts[0],
          'load': parts[1],
          'active': parts[2],
          'sub': parts[3],
          'description': parts.length > 4 ? parts.sublist(4).join(' ') : '',
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
