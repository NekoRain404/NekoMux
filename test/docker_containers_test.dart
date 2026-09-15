import 'package:flutter_test/flutter_test.dart';
import 'package:neko_mux/core/i18n/strings.dart';
import 'package:neko_mux/pages/containers/docker_commands.dart';
import 'package:neko_mux/pages/containers/docker_container.dart';

/// The container page's pure half: the listing parser and the command layer.
/// 容器页的纯逻辑部分：列表解析器与命令层。
void main() {
  // The active language is global mutable state; the parsers embed a localised
  // status word, so the tests pin one and leave the default behind.
  // 当前语言是全局可变状态；解析结果里带有本地化状态词，因此测试固定一种语言并在
  // 结束时还原默认值。
  setUp(() => AppStrings.setLang('en'));
  tearDown(() => AppStrings.setLang('zh'));

  group('parseDockerOutput', () {
    test('parses one container per row', () {
      final containers = parseDockerOutput(
        'a1b2c3d4e5f6|nginx:latest|web|Up 3 days|0.0.0.0:80->80/tcp|3 days ago\n'
        'f6e5d4c3b2a1|redis:7|error-logger|Exited (0) 2 hours ago||2 hours ago',
      );

      expect(containers, hasLength(2));
      expect(containers.first.name, 'web');
      expect(containers.first.image, 'nginx:latest');
      expect(containers.first.ports, '0.0.0.0:80->80/tcp');
      expect(containers.last.name, 'error-logger');
      expect(containers.last.ports, isEmpty);
    });

    test('"Up" means running, with the reported uptime', () {
      final container = parseDockerOutput(
        'id|img|web|Up 3 days||3 days ago',
      ).single;

      expect(container.isRunning, isTrue);
      expect(container.statusText, t('container_running'));
      expect(container.uptime, '3 days ago');
      expect(container.statusRaw, 'Up 3 days');
    });

    test('"Exited" means stopped, with no uptime', () {
      final container = parseDockerOutput(
        'id|img|web|Exited (0) 2 hours ago||2 hours ago',
      ).single;

      expect(container.isRunning, isFalse);
      expect(container.statusText, t('container_stopped'));
      expect(container.uptime, '-');
    });

    test('a container named "error-logger" parses like any other', () {
      // The name that made a successful `docker stop` look like a failure; the
      // parser must not treat it specially either.
      // 正是这个名字让成功的 `docker stop` 看起来像失败；解析器同样不得特殊对待。
      final container = parseDockerOutput(
        'id|img|error-logger|Up 2 minutes||2 minutes ago',
      ).single;

      expect(container.name, 'error-logger');
      expect(container.isRunning, isTrue);
    });

    test('a status text containing a pipe cannot shift the columns', () {
      // The columns are pipe-delimited precisely so that spaces (and anything
      // else) inside a field cannot move the rest along.
      // 各列以竖线分隔，正是为了让字段内的空格（及其它字符）无法把后续列挤走。
      final container = parseDockerOutput(
        'id|registry:5000/team/img|web|Up 5 minutes (healthy)||5 minutes ago',
      ).single;

      expect(container.image, 'registry:5000/team/img');
      expect(container.name, 'web');
      expect(container.isRunning, isTrue);
    });

    test('skips rows that are not six columns', () {
      // A truncated line is dropped rather than guessed at: every action is
      // issued against the name, so a half-parsed row would aim at the wrong
      // container.
      // 残缺的行会被丢弃而不是猜测：所有操作都以名称为目标，解析不全的行会打到
      // 错误的容器上。
      final containers = parseDockerOutput(
        'broken|row\n'
        'also|too|short\n'
        '\n'
        'id|img|web|Up 1 minute||1 minute ago\n',
      );

      expect(containers, hasLength(1));
      expect(containers.single.name, 'web');
    });

    test('an empty listing yields no containers', () {
      expect(parseDockerOutput(''), isEmpty);
      expect(parseDockerOutput('\n \n'), isEmpty);
    });
  });

  group('docker action layer', () {
    test('each action issues its own command', () {
      expect(
        dockerActionCommand(DockerAction.start, 'web'),
        'docker start web',
      );
      expect(dockerActionCommand(DockerAction.stop, 'web'), 'docker stop web');
      expect(
        dockerActionCommand(DockerAction.restart, 'error-logger'),
        'docker restart error-logger',
      );
      expect(
        dockerActionCommand(DockerAction.remove, 'web'),
        'docker rm -f web',
      );
    });

    test('each action reports its own message', () {
      // A mismatched pair would tell the user "Container restarted" after a
      // stop, so the mapping is asserted action by action.
      // 配错会让用户在停止之后看到「容器已重启」，因此逐项断言这层映射。
      expect(
        dockerActionSuccessMessage(DockerAction.start),
        t('container_start_success'),
      );
      expect(
        dockerActionSuccessMessage(DockerAction.stop),
        t('container_stop_success'),
      );
      expect(
        dockerActionSuccessMessage(DockerAction.restart),
        t('container_restart_success'),
      );
      expect(
        dockerActionSuccessMessage(DockerAction.remove),
        t('container_remove_success'),
      );
    });

    test('the log command asks for a bounded tail', () {
      expect(dockerLogsCommand('error-logger'), contains('--tail 50'));
      expect(dockerLogsCommand('error-logger'), contains('error-logger'));
    });

    test('the listing command matches what the parser expects', () {
      // The format string and the parser are two halves of one contract.
      // 格式串与解析器是同一份约定的两半。
      expect(dockerPsCommand, contains('{{.Names}}'));
      expect(dockerPsCommand, contains('|'));
      expect(dockerPsCommand, contains('docker ps -a'));
    });
  });
}
