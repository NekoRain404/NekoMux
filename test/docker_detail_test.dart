import 'package:flutter_test/flutter_test.dart';
import 'package:neko_mux/pages/containers/docker_detail.dart';

/// Guards the container detail parser against real `docker inspect` output.
///
/// Every fixture below is copied from this machine's own daemon rather than
/// invented, because the failure modes that matter are all things a made-up
/// fixture would not contain:
///
///   * a `.State.Error` holding a literal `|` (`flags=MS_BIND|MS_REC`) — the
///     reason a container is dead, and the exact field a pipe-delimited
///     template would split in half;
///   * a network reporting the literal string `invalid IP`;
///   * a `FinishedAt` that is *earlier* than the `StartedAt` beside it;
///   * an environment variable whose value is a credential inside a URL, under
///     a name that says nothing about being one.
void main() {
  // Captured from `docker inspect` on this host. Kept verbatim, tabs and all.
  const caddyHeader =
      '/nekoagent-caddy-1\texited\t127\tfalse\t0\tunless-stopped\t'
      'docker.m.daocloud.io/library/caddy:2.11.4-alpine\t0\t-\t'
      '2026-08-04T07:04:58.33243635Z\t2026-08-08T06:36:26.837849179Z\t'
      'failed to create task for container: failed to create shim task: OCI '
      'runtime create failed: runc create failed: unable to start container '
      'process: error during container init: error mounting "/home/x/Caddyfile" '
      'to rootfs at "/etc/caddy/Caddyfile": mount src=/home/x/Caddyfile, '
      'dst=/etc/caddy/Caddyfile, dstFd=/proc/thread-self/fd/13, '
      'flags=MS_BIND|MS_REC: not a directory: Are you trying to mount a '
      'directory onto a file (or vice-versa)?';

  const sshHeader =
      '/nekomux-test-ssh\trunning\t0\tfalse\t0\tno\t'
      'lscr.io/linuxserver/openssh-server:latest\t0\t-\t'
      '2026-09-18T16:18:28.066491896Z\t2026-09-17T11:28:28.057620823Z\t';

  group('a header line', () {
    test('parses every field, with the leading slash removed', () {
      final detail = parseContainerDetail(sshHeader).single;

      expect(detail.name, 'nekomux-test-ssh');
      expect(detail.status, 'running');
      expect(detail.exitCode, 0);
      expect(detail.oomKilled, isFalse);
      expect(detail.restartCount, 0);
      expect(detail.restartPolicy, 'no');
      expect(detail.image, 'lscr.io/linuxserver/openssh-server:latest');
      expect(detail.memoryLimitBytes, 0);
      expect(detail.memoryUnlimited, isTrue);
      expect(detail.health, isNull, reason: '`-` means there is no healthcheck');
      expect(detail.isRunning, isTrue);
      expect(detail.hasStateError, isFalse);
    });

    test('keeps a State.Error whole, pipes and all', () {
      // The load-bearing case for the tab delimiter. This field is the only
      // place the daemon says *why* a container never started, and runc writes
      // a literal `|` into it. Split on `|` and the sentence ends at
      // `flags=MS_BIND`, which is the half that explains nothing.
      final detail = parseContainerDetail(caddyHeader).single;

      expect(detail.status, 'exited');
      expect(detail.exitCode, 127);
      expect(detail.hasStateError, isTrue);
      expect(
        detail.stateError,
        contains('MS_BIND|MS_REC'),
        reason: 'the pipe inside the error must survive the parse',
      );
      expect(
        detail.stateError,
        contains('not a directory'),
        reason: 'the explanation comes after the pipe, so it is what a bad '
            'delimiter would have thrown away',
      );
    });

    test('parses the daemon nanosecond timestamps', () {
      // The daemon prints nine fractional digits and DateTime keeps six, so
      // this parse depends on the SDK truncating rather than throwing. Pinned
      // here because that is a fact about Dart, not about this parser: if it
      // ever stops holding, every timestamp in the detail view breaks at once.
      final detail = parseContainerDetail(sshHeader).single;

      expect(detail.startedAt, isNotNull);
      expect(detail.startedAt!.year, 2026);
      expect(detail.startedAt!.millisecond, 66);
      expect(detail.startedAt!.microsecond, 491);
      expect(
        detail.finishedAt!.isBefore(detail.startedAt!),
        isTrue,
        reason: 'the daemon reports a stale FinishedAt for a running container; '
            'the parser must report what it said, not tidy it up',
      );
    });

    test('treats the Go zero time as no time at all', () {
      // A container that has never run reports 0001-01-01T00:00:00Z, which
      // DateTime.parse accepts. Rendered, that is a date in the year 1.
      const never = '/x\tcreated\t0\tfalse\t0\tno\talpine\t0\t-\t'
          '0001-01-01T00:00:00Z\t0001-01-01T00:00:00Z\t';

      final detail = parseContainerDetail(never).single;

      expect(detail.startedAt, isNull);
      expect(detail.finishedAt, isNull);
    });

    test('reads a healthcheck and a memory limit when they exist', () {
      const healthy = '/ingest\trunning\t0\tfalse\t0\tunless-stopped\t'
          'nekoagent/knowledge-ingest:0.1.0\t1073741824\thealthy\t'
          '2026-09-18T15:59:30.410111268Z\t2026-09-18T15:59:29.239816043Z\t';

      final detail = parseContainerDetail(healthy).single;

      expect(detail.health, 'healthy');
      expect(detail.memoryLimitBytes, 1073741824);
      expect(detail.memoryUnlimited, isFalse);
    });
  });

  group('sections', () {
    test('mounts belong to the container above them', () {
      final output = [
        sshHeader,
        'MOUNT\tvolume\t/var/lib/docker/volumes/abc/_data\t/config\t\ttrue',
        'MOUNT\tbind\t/home/x/Caddyfile\t/etc/caddy/Caddyfile\tro\tfalse',
        caddyHeader,
        'MOUNT\tvolume\t/var/lib/docker/volumes/def/_data\t/data\trw\ttrue',
      ].join('\n');

      final details = parseContainerDetail(output);

      expect(details, hasLength(2));
      expect(details[0].name, 'nekomux-test-ssh');
      expect(details[0].mounts, hasLength(2));
      expect(details[1].name, 'nekoagent-caddy-1');
      expect(
        details[1].mounts,
        hasLength(1),
        reason: 'a mount must not leak into the next container',
      );
    });

    test('a mount reports its type, endpoints and writability', () {
      final output = [
        sshHeader,
        'MOUNT\tbind\t/home/x/Caddyfile\t/etc/caddy/Caddyfile\tro\tfalse',
        'MOUNT\tvolume\t/var/lib/docker/volumes/def/_data\t/data\trw\ttrue',
      ].join('\n');

      final mounts = parseContainerDetail(output).single.mounts;

      expect(mounts[0].type, 'bind');
      expect(mounts[0].source, '/home/x/Caddyfile');
      expect(mounts[0].destination, '/etc/caddy/Caddyfile');
      expect(mounts[0].isReadOnly, isTrue);
      expect(mounts[1].isReadOnly, isFalse);
      expect(
        mounts[1].mode,
        'rw',
        reason: 'the daemon leaves Mode empty for a plain volume mount; that '
            'is a fact about the output, not an error to paper over',
      );
    });

    test('a network with no address reports none rather than "invalid IP"', () {
      // A stopped container reports the literal string `invalid IP` in the
      // address field. Showing that as an address is showing the daemon's
      // placeholder as though it were a fact.
      final output = [
        caddyHeader,
        'NET\tnekoagent_default\tinvalid IP',
        sshHeader,
        'NET\tbridge\t172.17.0.3',
      ].join('\n');

      final details = parseContainerDetail(output);

      expect(details[0].networks.single.name, 'nekoagent_default');
      expect(details[0].networks.single.address, isEmpty);
      expect(details[1].networks.single.address, '172.17.0.3');
    });

    test('an environment value keeps its own tabs and equals signs', () {
      final output = [
        sshHeader,
        'ENV\tA=b=c',
        'ENV\tEMPTY=',
        'ENV\tNOEQUALS',
        'ENV\tTABBED=value\there',
      ].join('\n');

      final env = parseContainerDetail(output).single.env;

      expect(env[0].key, 'A');
      expect(env[0].value, 'b=c', reason: 'only the first = separates');
      expect(env[1].value, isEmpty);
      expect(env[2].key, 'NOEQUALS');
      expect(env[3].value, 'value\there');
    });
  });

  group('secrets in the environment', () {
    test('a name that says it is a secret is hidden', () {
      for (final name in const [
        'KNOWLEDGE_API_SECRET_KEY',
        'DB_PASSWORD',
        'GITHUB_TOKEN',
        'AWS_SECRET_ACCESS_KEY',
        'SSH_PRIVATE_KEY',
        'MYSQL_ROOT_PWD',
      ]) {
        expect(
          looksLikeSecretEnvName(name),
          isTrue,
          reason: '$name holds a credential and must not be on screen by '
              'default',
        );
      }
    });

    test('an ordinary name is not hidden', () {
      for (final name in const ['PATH', 'TZ', 'LANG', 'PUID', 'HOME']) {
        expect(looksLikeSecretEnvName(name), isFalse);
      }
    });

    test('a credential inside a URL is hidden even when the name says nothing', () {
      // Found on this machine, in a real container:
      //   DATABASE_URL=postgresql://nekoagent:a5239677...@postgres:5432/nekoagent
      // The name contains none of the words the heuristic looks for, and the
      // value is a live password. Name-matching alone would print it.
      const output =
          '/x\trunning\t0\tfalse\t0\tno\timg\t0\t-\t\t\t\n'
          'ENV\tDATABASE_URL=postgresql://nekoagent:a523967796c0ab70@postgres:5432/db\n'
          'ENV\tREDIS_URL=redis://default:hunter2@redis:6379/0\n'
          'ENV\tSENTRY_DSN=https://abc123@o1.ingest.sentry.io/2\n'
          'ENV\tPLAIN_URL=https://example.com/path\n'
          'ENV\tHOSTPORT=postgres:5432\n';

      final env = parseContainerDetail(output).single.env;

      expect(
        env[0].sensitive,
        isTrue,
        reason: 'postgresql://user:password@host is a credential',
      );
      expect(env[1].sensitive, isTrue, reason: 'redis://user:password@host too');
      expect(
        env[2].sensitive,
        isTrue,
        reason: 'a DSN carries a token in the userinfo position',
      );
      expect(
        env[3].sensitive,
        isFalse,
        reason: 'a URL with no credentials in it is not a secret',
      );
      expect(
        env[4].sensitive,
        isFalse,
        reason: 'a bare host:port is not a URL and has no credentials',
      );
    });

    test('the flag is on the variable, so the view can reveal it', () {
      const output = '/x\trunning\t0\tfalse\t0\tno\timg\t0\t-\t\t\t\n'
          'ENV\tAPI_TOKEN=abc\nENV\tTZ=UTC\n';

      final env = parseContainerDetail(output).single.env;

      expect(env[0].sensitive, isTrue);
      expect(
        env[0].value,
        'abc',
        reason: 'the value is parsed in full; hiding is the view\'s decision, '
            'not the parser\'s — a parser that dropped it could not offer a '
            'reveal',
      );
      expect(env[1].sensitive, isFalse);
    });
  });

  group('malformed input', () {
    test('a header with too few fields is skipped, not guessed at', () {
      // Every action is issued against the name, so a half-read row is worse
      // than a missing one.
      final output = [sshHeader, '/short\trunning\t0'].join('\n');

      final details = parseContainerDetail(output);

      expect(details, hasLength(1));
      expect(details.single.name, 'nekomux-test-ssh');
    });

    test('empty output yields nothing rather than throwing', () {
      expect(parseContainerDetail(''), isEmpty);
      expect(parseContainerDetail('\n\n'), isEmpty);
    });

    test('an unknown section line does not become a container', () {
      final output = [sshHeader, 'WAT\tsomething'].join('\n');

      expect(parseContainerDetail(output), hasLength(1));
    });

    test('an unparseable number falls back instead of throwing', () {
      const odd = '/x\trunning\tnull\tfalse\t\tno\timg\t\t-\t\t\t';

      final detail = parseContainerDetail(odd).single;

      expect(detail.exitCode, isNull);
      expect(detail.restartCount, 0);
      expect(detail.memoryLimitBytes, 0);
    });
  });

  test('the command asks for the template and the name', () {
    final command = dockerDetailCommand('web');

    expect(command, startsWith('docker inspect --format '));
    expect(command, endsWith(' web'));
    expect(
      command,
      contains(r'{{.State.Error}}'),
      reason: 'the reason a container is dead is the point of this call',
    );
    expect(
      command.contains("'"),
      isTrue,
      reason: 'the template must be quoted: it is full of braces and quotes',
    );
  });
}
