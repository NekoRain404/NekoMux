// The container list's data model and the parser for `docker ps` output.
// 容器列表的数据模型，以及 `docker ps` 输出的解析器。
//
// [parseDockerOutput] is a pure function of its input, so the rules that decide
// whether a container is shown as running can be tested without a connection,
// a widget, or a remote server.
// [parseDockerOutput] 只依赖入参，因此「容器是否显示为运行中」这类规则无需连接、
// widget 或远端服务器即可测试。

import '../../core/i18n/strings.dart';

/// The listing command whose output [parseDockerOutput] understands.
/// [parseDockerOutput] 所解析的列表命令。
///
/// The format string is pipe-delimited so that an image or status containing a
/// space cannot shift the columns, and it is kept beside the parser so the two
/// cannot drift apart.
/// 格式串用竖线分隔，避免镜像名或状态中的空格导致列错位；它与解析器放在一起，
/// 两者因此不可能各自漂移。
// It is run through `runCommand`, which captures stderr separately, so no
// `2>&1` is appended: [CommandResult.combined] merges the two streams for the
// listing just as the shell used to.
// 该命令通过 `runCommand` 执行，stderr 会被单独捕获，因此不再追加 `2>&1`：
// 列表展示所用的合并由 [CommandResult.combined] 完成，与过去 shell 合并的效果相同。
const String dockerPsCommand =
    "docker ps -a --format '{{.ID}}|{{.Image}}|{{.Names}}|{{.Status}}|{{.Ports}}|{{.RunningFor}}'";

/// One container as `docker ps` reports it.
/// `docker ps` 上报的单个容器。
class DockerContainer {
  /// Short container id.
  /// 容器短 ID。
  final String id;

  /// Container name (the field every action is issued against).
  /// 容器名称（所有操作都以它为目标）。
  final String name;

  /// Image the container was created from.
  /// 创建容器所用的镜像。
  final String image;

  /// Whether `docker ps` reports it as up.
  /// `docker ps` 是否报告其处于运行状态。
  final bool isRunning;

  /// Localised one-word status ("running" / "stopped").
  /// 本地化的一词状态（「运行中」/「已停止」）。
  final String statusText;

  /// Raw status column, kept for detail views.
  /// 原始状态列，供详情展示使用。
  final String statusRaw;

  /// Human-readable uptime, or `-` when it is not running.
  /// 可读的运行时长；未运行时为 `-`。
  final String uptime;

  /// Published ports as `docker ps` renders them.
  /// `docker ps` 渲染出的端口映射。
  final String ports;

  const DockerContainer({
    required this.id,
    required this.name,
    required this.image,
    required this.isRunning,
    required this.statusText,
    required this.statusRaw,
    required this.uptime,
    required this.ports,
  });
}

/// Parse the pipe-delimited Docker CLI output into container objects.
/// 将管道分隔的 Docker CLI 输出解析为容器对象。
///
/// Rows with fewer than the six expected columns are skipped rather than
/// guessed at: a partially-parsed row would show a wrong name or a wrong
/// status, and every action is issued against the name.
/// 列数不足六列的行走被跳过而不是猜测：解析不全的行会显示错误的名称或状态，
/// 而所有操作都是以名称为目标发出的。
List<DockerContainer> parseDockerOutput(String output) {
  final containers = <DockerContainer>[];
  final lines = output.trim().split('\n');

  for (final line in lines) {
    if (line.trim().isEmpty) continue;
    final parts = line.split('|');
    if (parts.length < 6) continue;

    final id = parts[0].trim();
    final image = parts[1].trim();
    final name = parts[2].trim();
    final statusRaw = parts[3].trim();
    final ports = parts[4].trim();
    final runningFor = parts[5].trim();

    /// Parse status: "Up X hours" / "Up 3 days" = running, "Exited (0)..." = stopped.
    /// 解析状态："Up X hours" / "Up 3 days" = 运行中，"Exited (0)..." = 已停止。
    final isRunning = statusRaw.startsWith('Up ');
    final statusText = isRunning
        ? t('container_running')
        : t('container_stopped');
    final uptime = isRunning ? runningFor : '-';

    containers.add(
      DockerContainer(
        id: id,
        name: name,
        image: image,
        isRunning: isRunning,
        statusText: statusText,
        statusRaw: statusRaw,
        uptime: uptime,
        ports: ports,
      ),
    );
  }

  return containers;
}
