import 'package:flutter_test/flutter_test.dart';
import 'package:neko_mux/pages/console/monitor_poll_state.dart';

void main() {
  group('in-flight guard', () {
    test('lets one tick run at a time', () {
      final poll = MonitorPollState();

      final first = poll.begin();
      expect(first, isNotNull);
      expect(poll.isInFlight, isTrue);

      // The second tick of an overlapping pair is what used to stack a fresh
      // pair of exec channels on top of a pair that had not finished, and it is
      // what made `previous` in the delta calculation point at a sample that
      // was not the immediately preceding one.
      expect(poll.begin(), isNull);
      expect(poll.isInFlight, isTrue);
    });

    test('releases the slot on success', () {
      final poll = MonitorPollState();
      final ticket = poll.begin()!;

      expect(poll.finishSuccess(ticket), isTrue);
      expect(poll.isInFlight, isFalse);
      expect(poll.begin(), isNotNull);
    });

    test('releases the slot on failure', () {
      final poll = MonitorPollState(maxConsecutiveFailures: 5);
      final ticket = poll.begin()!;

      expect(poll.finishFailure(ticket), isFalse);
      expect(poll.isInFlight, isFalse);
      expect(poll.begin(), isNotNull);
    });
  });

  group('failure limit', () {
    test('stops the loop once failures reach the limit', () {
      final poll = MonitorPollState(maxConsecutiveFailures: 2);

      expect(poll.finishFailure(poll.begin()!), isFalse);
      expect(poll.consecutiveFailures, 1);
      expect(poll.finishFailure(poll.begin()!), isTrue);
      expect(poll.consecutiveFailures, 2);
    });

    test('a successful tick resets the count', () {
      final poll = MonitorPollState(maxConsecutiveFailures: 2);

      poll.finishFailure(poll.begin()!);
      poll.finishSuccess(poll.begin()!);
      expect(poll.consecutiveFailures, 0);

      // One failure after a success is not two failures in a row.
      expect(poll.finishFailure(poll.begin()!), isFalse);
      expect(poll.consecutiveFailures, 1);
    });

    test('rejects a limit that could never be reached', () {
      expect(
        () => MonitorPollState(maxConsecutiveFailures: 0),
        throwsA(isA<AssertionError>()),
      );
    });
  });

  group('generations', () {
    test('a new generation refuses the old ticket and frees the slot', () {
      final poll = MonitorPollState();
      final stale = poll.begin()!;

      final current = poll.restart();

      expect(poll.isCurrent(stale), isFalse);
      expect(poll.isCurrent(current), isTrue);
      // The restart is what makes the new session usable again even though the
      // abandoned tick is still awaiting its SSH answer.
      expect(poll.isInFlight, isFalse);
      expect(poll.begin(), isNotNull);
    });

    test('a stale ticket can neither commit nor count as a failure', () {
      final poll = MonitorPollState(maxConsecutiveFailures: 1);
      final stale = poll.begin()!;
      poll.restart();

      expect(poll.finishSuccess(stale), isFalse);
      expect(poll.finishFailure(stale), isFalse);
      // In particular a stale failure must not stop the session that replaced
      // it, which is the case a restart during a reconnect would otherwise hit.
      expect(poll.consecutiveFailures, 0);
    });

    test('a stale finish cannot release the new generation\'s slot', () {
      final poll = MonitorPollState();
      final stale = poll.begin()!;
      poll.restart();
      final current = poll.begin()!;

      expect(poll.finishFailure(stale), isFalse);
      // The slot is still held by the live tick, so a third tick still cannot
      // start on top of it.
      expect(poll.isInFlight, isTrue);
      expect(poll.begin(), isNull);

      expect(poll.finishSuccess(current), isTrue);
      expect(poll.isInFlight, isFalse);
    });

    test('restarting clears the failure count', () {
      final poll = MonitorPollState(maxConsecutiveFailures: 2);
      poll.finishFailure(poll.begin()!);

      poll.restart();

      expect(poll.consecutiveFailures, 0);
      expect(poll.generation, 1);
    });
  });
}
