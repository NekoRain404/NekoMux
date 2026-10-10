// Prints the `docker run` command the app builds, so it can be run against a
// real daemon.
//
// The container integration suite proves the built command reaches a real shell
// as separate arguments. It cannot prove a daemon *accepts* it: the test fixture
// has no Docker, and asserting against a fake daemon would prove nothing. This
// closes that half by hand.
//
// The command is taken from `buildDockerRun` rather than retyped, so what gets
// checked is what ships — a hand-written command would only ever test the hand.
//
// Usage (from the project root):
//
//   dart --packages=.dart_tool/package_config.json tool/print_run_command.dart
//
// See integration_test/README.md for the inspect commands that read back what
// the daemon recorded.
import 'dart:io';

import 'package:neko_mux/pages/containers/docker_run_spec.dart';

void main() {
  final plan = buildDockerRun(
    const DockerRunSpec(
      image: 'alpine:latest',
      name: 'nekomux-verify-command',
      ports: ['18080:80'],
      environment: ['NEKOMUX_VERIFY=1'],
      restartPolicy: 'no',
    ),
  );

  if (!plan.isOk) {
    throw StateError(
      'the builder refused this spec: ${plan.problem} ${plan.offendingValue}',
    );
  }
  // Written to stdout rather than printed: this is a command-line tool whose
  // entire output is meant to be piped into a shell, and `print` is a lint
  // here for good reason — in the app it would be a debug leftover.
  stdout.writeln(plan.command);
}
