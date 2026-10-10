import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neko_mux/core/i18n/strings.dart';
import 'package:neko_mux/pages/containers/container_cards.dart';
import 'package:neko_mux/pages/containers/docker_container.dart';
import 'package:neko_mux/pages/containers/docker_stats.dart';

/// Guards the resource line the container card gained.
///
/// The whole value of that line is that it is the one thing on the list that
/// changes between two looks — so what has to hold is that it appears only when
/// a snapshot actually arrived. A card reading `CPU 0.00%` for a host that
/// refused the command would be reporting a measurement nobody took, which is
/// the failure this project treats as worse than showing nothing.
void main() {
  setUp(() => AppStrings.setLang('en'));
  tearDown(() => AppStrings.setLang('zh'));

  const container = DockerContainer(
    id: 'abc123',
    name: 'web',
    image: 'nginx:alpine',
    isRunning: true,
    statusText: 'Running',
    statusRaw: 'Up 3 hours',
    uptime: '3 hours',
    ports: '0.0.0.0:8080->80/tcp',
  );

  ContainerStats statsWith(double cpu) => ContainerStats(
    name: 'web',
    cpuPercent: cpu,
    memoryUsed: '14.72MiB',
    memoryPercent: 0.72,
    pids: 5,
  );

  Future<void> pump(WidgetTester tester, {ContainerStats? stats}) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ContainerCard(
            container: container,
            stats: stats,
            onTap: () {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('shows the resource line when a snapshot arrived', (tester) async {
    await pump(tester, stats: statsWith(0.15));

    expect(find.textContaining('CPU 0.15%'), findsOneWidget);
    expect(find.textContaining('14.72MiB'), findsOneWidget);
    expect(find.byIcon(Icons.speed), findsOneWidget);
  });

  testWidgets('shows nothing at all without a snapshot', (tester) async {
    await pump(tester);

    expect(
      find.textContaining('CPU'),
      findsNothing,
      reason: 'a card with no numbers must say nothing rather than show a zero',
    );
    expect(find.byIcon(Icons.speed), findsNothing);

    // And the rest of the card is untouched: the list is still readable.
    expect(find.text('web'), findsOneWidget);
    expect(find.textContaining('nginx:alpine'), findsOneWidget);
    expect(find.textContaining('Running'), findsOneWidget);
  });

  testWidgets('never renders a memory ceiling', (tester) async {
    // `docker stats` puts the host's total RAM in the column after the slash
    // for a container with no limit, and a card cannot tell the two apart. The
    // number in use is true either way; the ceiling is not.
    await pump(tester, stats: statsWith(0.15));

    expect(find.text('/'), findsNothing);
    expect(find.textContaining('GiB'), findsNothing);
  });

  testWidgets('a busy container is marked out from an idle one', (tester) async {
    await pump(tester, stats: statsWith(340.55));
    final busy = tester.widget<Icon>(find.byIcon(Icons.speed)).color;

    await pump(tester, stats: statsWith(0.15));
    final idle = tester.widget<Icon>(find.byIcon(Icons.speed)).color;

    expect(
      busy,
      isNot(idle),
      reason: 'finding the container that is eating the machine is the reason '
          'this line exists, and a colour that never changes cannot do it',
    );
  });

  testWidgets('a multi-core container is not clamped to one hundred', (
    tester,
  ) async {
    // CPU is a share of a single core, so 340.55% is four cores busy — exactly
    // the container someone opens this list to find.
    await pump(tester, stats: statsWith(340.55));

    expect(find.textContaining('CPU 340.55%'), findsOneWidget);
  });
}
