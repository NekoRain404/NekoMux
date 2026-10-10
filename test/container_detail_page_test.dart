import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neko_mux/core/i18n/strings.dart';
import 'package:neko_mux/pages/containers/container_detail_loader.dart';
import 'package:neko_mux/pages/containers/container_detail_page.dart';
import 'package:neko_mux/pages/containers/docker_detail.dart';

/// Guards what the detail view puts on screen.
///
/// The parser is covered by `docker_detail_test.dart` and the trip by the
/// integration suite; this is the layer between them and the user, and it holds
/// one claim that is not about layout at all: that a credential in the
/// environment is not rendered until it is asked for. A test of the masking
/// helper alone would not notice the view forgetting to call it — which is the
/// only way the hiding can actually fail.
void main() {
  // The app ships eight languages and `AppStrings` defaults to Chinese. These
  // assertions are about which of a container's facts reach the screen, so the
  // language is pinned rather than left to whatever the ambient default is —
  // an assertion that passes only because it matches a translation is not
  // testing the view.
  setUp(() => AppStrings.setLang('en'));
  tearDown(() => AppStrings.setLang('zh'));

  ContainerDetail detail({
    String status = 'running',
    int? exitCode = 0,
    bool oomKilled = false,
    int restartCount = 0,
    String restartPolicy = 'no',
    String stateError = '',
    int memoryLimitBytes = 0,
    String? health,
    List<ContainerEnvVar> env = const [],
    List<ContainerMount> mounts = const [],
    List<ContainerNetwork> networks = const [],
  }) => ContainerDetail(
    name: 'web',
    status: status,
    exitCode: exitCode,
    oomKilled: oomKilled,
    restartCount: restartCount,
    restartPolicy: restartPolicy,
    image: 'nginx:alpine',
    memoryLimitBytes: memoryLimitBytes,
    health: health,
    startedAt: DateTime(2026, 9, 18, 16, 18),
    finishedAt: null,
    stateError: stateError,
    mounts: mounts,
    env: env,
    networks: networks,
  );

  Future<void> pumpDetail(
    WidgetTester tester,
    ContainerDetailOutcome outcome,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: ContainerDetailPage(
          containerName: 'web',
          load: () async => outcome,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('a dead container leads with the daemon\'s own explanation', (
    tester,
  ) async {
    // The reason this view exists. `docker ps` said `Exited (127)`; the runc
    // sentence below is the only thing that says what to actually fix, and it
    // was previously reachable only from a laptop with `jq`.
    const reason =
        'error mounting "/srv/Caddyfile" to rootfs: flags=MS_BIND|MS_REC: '
        'not a directory';

    await pumpDetail(
      tester,
      ContainerDetailOutcome.loaded(
        detail(status: 'exited', exitCode: 127, stateError: reason),
      ),
    );

    expect(
      find.textContaining('not a directory', findRichText: true),
      findsOneWidget,
    );
    expect(find.textContaining('127', findRichText: true), findsWidgets);
    expect(find.text('Stopped'), findsWidgets);
  });

  testWidgets('a running container shows no failure card at all', (
    tester,
  ) async {
    await pumpDetail(tester, ContainerDetailOutcome.loaded(detail()));

    expect(find.text('Why it stopped'), findsNothing);
    expect(find.text('Running'), findsWidgets);
  });

  testWidgets('a credential in the environment is not on screen by default', (
    tester,
  ) async {
    await pumpDetail(
      tester,
      ContainerDetailOutcome.loaded(
        detail(
          env: const [
            ContainerEnvVar(key: 'TZ', value: 'UTC', sensitive: false),
            ContainerEnvVar(
              key: 'DATABASE_URL',
              value: 'postgresql://u:hunter2@db:5432/x',
              sensitive: true,
            ),
          ],
        ),
      ),
    );

    // The name is always shown: knowing that the variable is set is most of
    // what the section is for.
    expect(find.textContaining('DATABASE_URL', findRichText: true), findsOne);
    expect(
      find.textContaining('hunter2', findRichText: true),
      findsNothing,
      reason: 'a live password must not be rendered before it is asked for',
    );
    expect(
      find.textContaining('UTC', findRichText: true),
      findsOne,
      reason: 'an ordinary variable is not hidden',
    );
  });

  testWidgets('asking to see the values reveals them', (tester) async {
    await pumpDetail(
      tester,
      ContainerDetailOutcome.loaded(
        detail(
          env: const [
            ContainerEnvVar(key: 'API_TOKEN', value: 'abc123', sensitive: true),
          ],
        ),
      ),
    );

    await tester.tap(find.text('Show'));
    await tester.pumpAndSettle();

    expect(find.textContaining('abc123', findRichText: true), findsOneWidget);
  });

  testWidgets('mounts show both endpoints, and read-only is marked', (
    tester,
  ) async {
    await pumpDetail(
      tester,
      ContainerDetailOutcome.loaded(
        detail(
          mounts: const [
            ContainerMount(
              type: 'bind',
              source: '/srv/config.yaml',
              destination: '/app/config.yaml',
              mode: 'ro',
              writable: false,
            ),
          ],
        ),
      ),
    );

    expect(find.text('/app/config.yaml'), findsOneWidget);
    expect(
      find.textContaining('/srv/config.yaml', findRichText: true),
      findsOneWidget,
      reason: 'the host path is what the user acts on and must not be hidden',
    );
    expect(find.text('read-only'), findsOneWidget);
  });

  testWidgets('a failed read says so instead of rendering an empty container', (
    tester,
  ) async {
    await pumpDetail(
      tester,
      const ContainerDetailOutcome.failed('docker: command not found'),
    );

    expect(find.textContaining('docker: command not found'), findsOneWidget);
    expect(
      find.text('State'),
      findsNothing,
      reason: 'no sections may render for a container that was never read',
    );
  });

  testWidgets('an unlimited memory limit is named, not shown as 0 B', (
    tester,
  ) async {
    await pumpDetail(tester, ContainerDetailOutcome.loaded(detail()));

    expect(find.text('Unlimited'), findsWidgets);
  });
}
