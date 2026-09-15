import 'package:flutter_test/flutter_test.dart';
import 'package:neko_mux/core/i18n/strings.dart';
import 'package:neko_mux/pages/containers/docker_commands.dart';
import 'package:neko_mux/pages/containers/docker_container.dart';

/// The container page's pure half: the listing parser and the command layer.
/// 容器页的纯逻辑部分：列表解析器与命令层。

/// The `{{…}}` field sequence of a `--format '…'` command, in order.
/// 从 `--format '…'` 命令中按顺序取出 `{{…}}` 字段序列。
///
/// Read out of the command itself rather than copied, so the fixture the
/// parser is fed is built from the very string the app runs — the two cannot
/// drift apart the way a hand-written row can.
/// 直接从命令本身读出而非复制，因此喂给解析器的用例是由应用真正执行的那个字符串构造
/// 的——两者不会像手写的行那样各自漂移。
List<String> fieldsOf(String command) {
  final format = RegExp(r"--format '(.*)'").firstMatch(command)?.group(1);
  expect(format, isNotNull, reason: 'no --format string in "$command"');
  return format!.split('|');
}

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

    test('the log command asks for a bounded tail, merged into one stream', () {
      // The exact command, `2>&1` included. The production comment calls that
      // merge load-bearing — the viewer renders one block of text, and without
      // it whatever `docker logs` writes to stderr never reaches that block —
      // and two `contains` checks for `--tail 50` / the container name left
      // deleting it undetected.
      // 完整的命令，包含 `2>&1`。生产代码的注释把这次合并称作关键——查看器渲染的是
      // 一整块文本，没有它，`docker logs` 写往 stderr 的内容永远到不了那块文本——
      // 而只检查 `--tail 50` 与容器名的两条 `contains` 断言，删掉它也发现不了。
      expect(
        dockerLogsCommand('error-logger'),
        'docker logs --tail 50 error-logger 2>&1',
      );
      expect(dockerLogsCommand('web'), 'docker logs --tail 50 web 2>&1');
    });

    test('the listing command matches what the parser expects', () {
      // The format string and the parser are two halves of one contract, and
      // that contract *is* the field order: the format decides which value
      // lands in which pipe-separated column, and the parser reads the columns
      // back by index. Three `contains` checks could not see the order at all —
      // swapping `{{.ID}}` and `{{.Names}}` would make every container display
      // its id as its name, with every test still green.
      // 格式串与解析器是同一份约定的两半，而这份约定的全部内容就是字段顺序：格式串
      // 决定哪个值落在哪一个竖线分隔的列里，解析器按下标把列读回。三条 `contains`
      // 断言完全看不到顺序——把 `{{.ID}}` 与 `{{.Names}}` 对调，每个容器都会把自己
      // 的 ID 显示成名字，而所有测试依然全绿。

      // `-a` is what makes stopped containers appear at all, so the command is
      // pinned as a whole, not by one substring.
      // `-a` 正是让已停止容器出现的原因，因此整条命令被固定下来，而不是只断言某个
      // 子串。
      expect(dockerPsCommand, startsWith("docker ps -a --format '"));

      // 1. The field sequence the format asks Docker for.
      expect(fieldsOf(dockerPsCommand), [
        '{{.ID}}',
        '{{.Image}}',
        '{{.Names}}',
        '{{.Status}}',
        '{{.Ports}}',
        '{{.RunningFor}}',
      ]);

      // 2. The round trip: a row built *from that same sequence* — not from a
      //    hand-written string that could agree with the parser while
      //    disagreeing with the command — must read back into the matching
      //    properties.
      // 2. 往返验证：由**同一个字段序列**构造的行（而不是手写的、可能与解析器一致
      //    却与命令不一致的字符串）必须读回对应的属性。
      final sample = <String, String>{
        '{{.ID}}': 'a1b2c3d4e5f6',
        '{{.Image}}': 'registry:5000/team/nginx:latest',
        '{{.Names}}': 'web-frontend',
        '{{.Status}}': 'Up 3 days',
        '{{.Ports}}': '0.0.0.0:80->80/tcp',
        '{{.RunningFor}}': '3 days ago',
      };
      final row = fieldsOf(
        dockerPsCommand,
      ).map((field) => sample[field]).join('|');

      final container = parseDockerOutput(row).single;
      expect(container.id, sample['{{.ID}}']);
      expect(container.image, sample['{{.Image}}']);
      expect(container.name, sample['{{.Names}}']);
      expect(container.statusRaw, sample['{{.Status}}']);
      expect(container.ports, sample['{{.Ports}}']);
      expect(container.uptime, sample['{{.RunningFor}}']);
      expect(container.isRunning, isTrue);
    });
  });
}
