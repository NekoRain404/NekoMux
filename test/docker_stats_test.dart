import 'package:flutter_test/flutter_test.dart';
import 'package:neko_mux/pages/containers/docker_stats.dart';

/// Guards the `docker stats` parser against real daemon output.
///
/// The fixture is copied from this machine's own daemon. Two of its properties
/// are the reason the parser is not a one-line split, and neither would appear
/// in a fixture written from the documentation:
///
///   * a container with no `--memory` set reports the HOST's total RAM as its
///     limit, so `3.742MiB / 125.4GiB` is not a container bounded at 125 GiB;
///   * CPU is a percentage of one core, not of the machine, so a container
///     using several cores reports above 100.
void main() {
  // `docker stats --no-stream --format …`, copied row for row from one capture.
  // The numbers drift between captures because this is live data; the shapes
  // are what matter and none of them was adjusted by hand.
  const realSnapshot = '''
nekomux-test-ssh-3|0.00%|1.625MiB / 125.4GiB|0.00%|13
nekoagent-litellm-1|0.15%|14.72MiB / 2GiB|0.72%|5
nekoagent-open-webui-1|0.30%|48.57MiB / 1GiB|4.74%|102
nekoagent-redis-1|0.16%|5.984MiB / 512MiB|1.17%|21
hermes-open-webui-1|0.12%|39.44MiB / 125.4GiB|0.03%|107
''';

  test('reads every container in the snapshot, keyed by name', () {
    final stats = parseDockerStats(realSnapshot);

    expect(
      stats.keys,
      containsAll([
        'nekomux-test-ssh-3',
        'nekoagent-litellm-1',
        'nekoagent-open-webui-1',
        'nekoagent-redis-1',
      ]),
    );
    expect(
      stats['nekomux-test-ssh-3']!.name,
      'nekomux-test-ssh-3',
      reason: 'the name has no leading slash here, unlike `docker inspect`',
    );
  });

  test('reads the percentages and the process count', () {
    final redis = parseDockerStats(realSnapshot)['nekoagent-redis-1']!;

    expect(redis.cpuPercent, closeTo(0.16, 0.001));
    expect(redis.memoryPercent, closeTo(1.17, 0.001));
    expect(redis.pids, 21);
    expect(redis.memoryUsed, '5.984MiB');
  });

  test('the misleading half of the memory figure never leaves the parser', () {
    // `docker stats` writes memory as `used / limit`, and with no `--memory`
    // set the daemon puts the HOST's total RAM after the slash: this container
    // reports `1.625MiB / 125.4GiB` while being unbounded. Nothing in the
    // output says which of the two cases a row is, so the parser keeps the
    // figure that is true either way and carries no ceiling it would have to
    // guess at.
    final stats = parseDockerStats(realSnapshot);

    final unbounded = stats['nekomux-test-ssh-3']!;
    expect(unbounded.memoryUsed, '1.625MiB');
    expect(
      unbounded.memoryUsed,
      isNot(contains('125.4GiB')),
      reason: 'the host total must not reach a view, which would render it as '
          'this container\'s ceiling',
    );

    // A container that really is capped, in the same snapshot. It reads exactly
    // the same way — which is the point: the parser does not claim to tell the
    // two apart, and the view is built so that it does not need to.
    final bounded = stats['nekoagent-litellm-1']!;
    expect(bounded.memoryUsed, '14.72MiB');
    expect(bounded.memoryUsed, isNot(contains('2GiB')));

    // A second unbounded container, so the assertion does not rest on one row
    // having been read correctly by luck.
    final alsoUnbounded = stats['hermes-open-webui-1']!;
    expect(alsoUnbounded.memoryUsed, '39.44MiB');
    expect(alsoUnbounded.memoryPercent, closeTo(0.03, 0.001));
  });

  test('a container using several cores reports above one hundred', () {
    // CPU is a share of a single core. Clamping it to 100 would hide exactly
    // the container that is saturating the machine, which is the one the user
    // opened this to find.
    final stats = parseDockerStats('busy|340.55%|1GiB / 2GiB|50.00%|40\n');

    expect(stats['busy']!.cpuPercent, closeTo(340.55, 0.001));
    expect(stats['busy']!.isBusy, isTrue);
    expect(parseDockerStats('idle|0.00%|1MiB / 2GiB|0.05%|1\n')['idle']!.isBusy,
        isFalse);
  });

  test('a memory figure with no slash keeps it whole', () {
    // Not a shape the current daemon emits, but the parser is handed whatever a
    // server sends. A value with no separator is the whole figure rather than
    // a split on a separator that was not there.
    final stats = parseDockerStats('odd|1.00%|12MiB|0.50%|3\n')['odd']!;

    expect(stats.memoryUsed, '12MiB');
  });

  test('a malformed row is dropped rather than joined to the wrong container', () {
    const output = '''
good|1.00%|1MiB / 2GiB|0.50%|3
truncated|1.00%|1MiB
|1.00%|1MiB / 2GiB|0.50%|3
another|2.00%|2MiB / 2GiB|1.00%|4
''';

    final stats = parseDockerStats(output);

    expect(stats.keys, containsAll(['good', 'another']));
    expect(
      stats.containsKey('truncated'),
      isFalse,
      reason: 'a row with missing columns cannot be trusted to line up with '
          'the column it was read from',
    );
    expect(stats.containsKey(''), isFalse);
  });

  test('an unreadable number reads as zero, not as a missing container', () {
    // Dropping the row would make a container vanish from a list that is
    // displaying it; zero is what "no measurable activity" already looks like.
    final stats = parseDockerStats('weird|--|1MiB / 2GiB|--|x\n')['weird']!;

    expect(stats.cpuPercent, 0);
    expect(stats.memoryPercent, 0);
    expect(stats.pids, 0);
  });

  test('an empty snapshot yields nothing rather than throwing', () {
    // What a host with no running containers answers.
    expect(parseDockerStats(''), isEmpty);
    expect(parseDockerStats('\n\n'), isEmpty);
  });

  test('the command asks for a snapshot, not a stream', () {
    // Without `--no-stream` the daemon never returns and the SSH command hangs
    // until the connection times out, which on a phone looks like a dead page.
    expect(dockerStatsCommand, contains('--no-stream'));
    expect(dockerStatsCommand, contains('docker stats'));
  });
}
