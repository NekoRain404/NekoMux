// The Docker command layer: which command each lifecycle action issues, and
// which localised message reports it.
// Docker 命令层：每个生命周期操作发出哪条命令，以及用哪条本地化文案汇报。
//
// Keeping the command *text* out of the page is what lets the action path be
// read as one thing — build the command, run it through [runCommand], judge it
// by its exit status — instead of a string buried in a tap handler. The
// commands are pure functions of a container name, so they are testable.
// 把命令**文本**移出页面，才能让操作路径读起来只有一件事——拼命令、经
// [runCommand] 执行、按退出状态判断成败——而不是埋在手势回调里的一个字符串。
// 这些命令是容器名的纯函数，因此可测。

import '../../core/i18n/strings.dart';

/// The lifecycle actions the container sheet offers.
/// 容器面板提供的生命周期操作。
///
/// The action is named rather than passed as a raw `docker …` string so that
/// the command and the message that reports it cannot be paired up wrongly —
/// a mismatched pair would tell the user "Container stopped" after a restart.
/// 操作用枚举而非裸 `docker …` 字符串表示，这样命令与汇报文案就不可能配错——
/// 配错会让用户在重启之后看到「容器已停止」。
enum DockerAction {
  /// `docker start`.
  /// `docker start`。
  start,

  /// `docker stop`.
  /// `docker stop`。
  stop,

  /// `docker restart`.
  /// `docker restart`。
  restart,

  /// `docker rm -f`.
  /// `docker rm -f`。
  remove,
}

/// The remote command [action] issues against [container].
/// [action] 针对 [container] 发出的远端命令。
///
/// The name is used unquoted, exactly as before: Docker container names cannot
/// contain shell metacharacters, and the name comes from `docker ps` itself.
/// 名称不加引号，与之前完全一致：Docker 容器名不能包含 shell 元字符，且该名称
/// 本身来自 `docker ps` 的输出。
String dockerActionCommand(DockerAction action, String container) =>
    switch (action) {
      DockerAction.start => 'docker start $container',
      DockerAction.stop => 'docker stop $container',
      DockerAction.restart => 'docker restart $container',
      DockerAction.remove => 'docker rm -f $container',
    };

/// The message shown once [action] has reported success.
/// [action] 上报成功之后展示的文案。
///
/// Every one of these is only ever shown after the exit status said so.
/// 这些文案只有在退出状态确认为成功之后才会出现。
String dockerActionSuccessMessage(DockerAction action) => switch (action) {
  DockerAction.start => t('container_start_success'),
  DockerAction.stop => t('container_stop_success'),
  DockerAction.restart => t('container_restart_success'),
  DockerAction.remove => t('container_remove_success'),
};

/// The command that reads the last 50 log lines of [container].
/// 读取 [container] 最近 50 行日志的命令。
///
/// `2>&1` is kept here on purpose: the log viewer shows one block of text, and
/// merging the streams remotely preserves the order in which `docker logs`
/// wrote them.
/// 这里刻意保留 `2>&1`：日志查看器展示的是一整块文本，在远端合并两条流可以保留
/// `docker logs` 写出的先后顺序。
String dockerLogsCommand(String container) =>
    'docker logs --tail 50 $container 2>&1';
