import 'package:flutter_test/flutter_test.dart';
import 'package:neko_mux/pages/containers/docker_run_spec.dart';

/// Guards the command builder, which is the only place in this app where a
/// value the user typed becomes something a remote shell executes.
///
/// Every field in the form is attacker-shaped from the builder's point of view:
/// it is text from a keyboard that ends up in `sh -c` on a machine the user may
/// not own. A builder that concatenated strings would happily run
/// `--name "x; rm -rf /"`, so the tests below are less about formatting and more
/// about that single fact.
void main() {
  String commandFor(DockerRunSpec spec) {
    final plan = buildDockerRun(spec);
    expect(plan.isOk, isTrue, reason: 'refused: ${plan.problem}');
    return plan.command!;
  }

  test('the minimum is an image, detached, with the default policy', () {
    // `unless-stopped` is the default for a reason: a container created from a
    // phone and then forgotten should come back after the host reboots, which is
    // what a user means by "run this".
    expect(
      commandFor(const DockerRunSpec(image: 'nginx')),
      "docker run -d --restart unless-stopped 'nginx'",
    );
  });

  group('the quoting', () {
    test('a shell metacharacter in a name is not a second command', () {
      // The test this file exists for. With string concatenation this value
      // closes the argument and runs `rm -rf /` on the server.
      final command = commandFor(
        const DockerRunSpec(image: 'nginx', name: 'x; rm -rf /'),
      );

      // The whole value sits inside single quotes, so the `;` is data rather
      // than a command separator — which is the entire difference between this
      // builder and string concatenation.
      expect(command, contains("'x; rm -rf /'"));
      expect(
        command.split("'x; rm -rf /'").first.length,
        lessThan(command.length),
        reason: 'the value is present as one quoted argument',
      );
    });

    test('a quote inside a value is escaped rather than closing it', () {
      final command = commandFor(
        const DockerRunSpec(image: "it's", name: "o'brien"),
      );

      // `'\''` is the POSIX way to put a quote inside a single-quoted string.
      expect(command, contains(r"'o'\''brien'"));
      expect(command, contains(r"'it'\''s'"));
    });

    test('a dollar sign is not expanded by the remote shell', () {
      // Single quotes stop expansion, which is why the builder uses them.
      final command = commandFor(
        const DockerRunSpec(image: 'nginx', environment: ['TOKEN=\$HOME']),
      );

      expect(command, contains(r"'TOKEN=$HOME'"));
    });

    test('a newline is refused instead of guessed at', () {
      // There is no way to put a newline inside single quotes in a POSIX shell.
      // Dropping it would run a different command from the one described, which
      // is worse than saying no.
      final plan = buildDockerRun(
        const DockerRunSpec(image: 'nginx', name: 'a\nb'),
      );

      expect(plan.isOk, isFalse);
      expect(plan.problem, DockerRunProblem.unsafeValue);
      expect(plan.offendingValue, 'a\nb');
    });

    test('a newline in the image is refused too', () {
      final plan = buildDockerRun(
        const DockerRunSpec(image: 'nginx\nrm -rf /'),
      );
      expect(plan.isOk, isFalse);
      expect(plan.problem, DockerRunProblem.unsafeValue);
    });

    test('a newline in the extra arguments is refused', () {
      final plan = buildDockerRun(
        const DockerRunSpec(image: 'nginx', extraArgs: '--rm\nrm -rf /'),
      );
      expect(plan.isOk, isFalse);
      expect(plan.problem, DockerRunProblem.unsafeValue);
    });
  });

  group('what it refuses', () {
    test('no image', () {
      final plan = buildDockerRun(const DockerRunSpec(image: '   '));
      expect(plan.isOk, isFalse);
      expect(plan.problem, DockerRunProblem.missingImage);
    });

    test('a port without a colon', () {
      // `8080` alone is a typo for `8080:80`; passing it on would produce a
      // docker error the user has to interpret.
      final plan = buildDockerRun(
        const DockerRunSpec(image: 'nginx', ports: ['8080']),
      );
      expect(plan.isOk, isFalse);
      expect(plan.problem, DockerRunProblem.malformedPair);
      expect(plan.offendingValue, '8080');
    });

    test('a mount without a colon, and a trailing colon', () {
      expect(
        buildDockerRun(
          const DockerRunSpec(image: 'nginx', volumes: ['/data']),
        ).problem,
        DockerRunProblem.malformedPair,
      );
      expect(
        buildDockerRun(
          const DockerRunSpec(image: 'nginx', volumes: ['/data:']),
        ).problem,
        DockerRunProblem.malformedPair,
      );
    });

    test('an environment entry with no key', () {
      // A bare `KEY` asks docker to copy the value from the host's environment,
      // and this app is not on that host — so it cannot mean anything here.
      expect(
        buildDockerRun(
          const DockerRunSpec(image: 'nginx', environment: ['=value']),
        ).problem,
        DockerRunProblem.malformedPair,
      );
      expect(
        buildDockerRun(
          const DockerRunSpec(image: 'nginx', environment: ['JUST_A_KEY']),
        ).problem,
        DockerRunProblem.malformedPair,
      );
    });

    test('a restart policy outside the four docker accepts', () {
      // Silently dropping an unknown policy would start a container that does
      // not come back after a reboot, which is not what the user asked for.
      final command = commandFor(
        const DockerRunSpec(image: 'nginx', restartPolicy: 'sometimes'),
      );
      expect(command, isNot(contains('--restart')));
    });
  });

  group('the command it builds', () {
    test('carries every part the form offers, in a runnable order', () {
      final command = commandFor(
        const DockerRunSpec(
          image: 'postgres:16',
          name: 'db',
          ports: ['5432:5432'],
          volumes: ['/srv/pg:/var/lib/postgresql/data'],
          environment: ['POSTGRES_PASSWORD=secret', 'TZ=UTC'],
          restartPolicy: 'always',
        ),
      );

      expect(command, startsWith('docker run -d '));
      expect(command, contains("--name 'db'"));
      expect(command, contains("-p '5432:5432'"));
      expect(command, contains("-v '/srv/pg:/var/lib/postgresql/data'"));
      expect(command, contains("-e 'POSTGRES_PASSWORD=secret'"));
      expect(command, contains("-e 'TZ=UTC'"));
      expect(command, contains('--restart always'));
      expect(
        command,
        endsWith("'postgres:16'"),
        reason: 'the image comes last, where docker expects it',
      );
    });

    test('empty optional fields leave no trace', () {
      final command = commandFor(
        const DockerRunSpec(
          image: 'nginx',
          name: '',
          ports: ['', '  '],
          environment: [''],
          restartPolicy: '',
        ),
      );

      expect(command, endsWith("'nginx'"));
      expect(command, isNot(contains('--name')));
      expect(command, isNot(contains('-p')));
      expect(command, isNot(contains('-e')));
    });

    test('extra arguments are spliced in as an argument list', () {
      // Not quoted as one token: the user is typing docker arguments, and
      // quoting them whole would hand `docker run` a single meaningless string.
      final command = commandFor(
        const DockerRunSpec(image: 'nginx', extraArgs: '--rm --network host'),
      );

      expect(command, contains('--rm --network host'));
    });
  });
}
