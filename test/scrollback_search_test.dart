import 'package:flutter_test/flutter_test.dart';
import 'package:neko_mux/pages/terminal/scrollback_search.dart';

/// Guards the terminal's scrollback search.
///
/// Two failure modes matter and neither is visible in a screenshot: a search
/// that misses a line the user can see on screen (because of case, or because it
/// only looked at the first match per line), and one that silently reports a
/// truncated list as if it were complete.
void main() {
  const scrollback = [
    'systemctl status nginx',
    'Active: active (running) since Tue',
    'ERROR: upstream timed out',
    'nginx: worker process 1234',
    'error: connection refused',
    'Jul 12 09:14:22 host sshd[9]: Accepted',
  ];

  test('finds every matching line, with its number', () {
    final matches = searchScrollback(scrollback, 'nginx');

    expect(matches.map((m) => m.lineNumber), [0, 3]);
    expect(matches.first.text, 'systemctl status nginx');
  });

  test('is case-insensitive by default', () {
    // The query is usually a service name or an error word whose capitalisation
    // the user is not sure of; returning nothing over a capital letter is worse
    // than not having the feature.
    final matches = searchScrollback(scrollback, 'error');

    expect(matches.map((m) => m.lineNumber), [2, 4]);
  });

  test('can be made case-sensitive when the user asks', () {
    final matches = searchScrollback(
      scrollback,
      'error',
      caseSensitive: true,
    );

    expect(matches.map((m) => m.lineNumber), [4]);
  });

  test('reports where the match sits inside the line', () {
    final match = searchScrollback(scrollback, 'upstream').single;

    expect(match.start, 7);
    expect(match.end, 15);
    expect(
      match.text.substring(match.start, match.end),
      'upstream',
      reason: 'the offsets have to select the query, not near it',
    );
  });

  test('an empty query matches nothing', () {
    // Matching everything would fill the list with the whole scrollback the
    // moment the field is focused and empty.
    expect(searchScrollback(scrollback, ''), isEmpty);
  });

  test('a scrollback with no match returns nothing rather than throwing', () {
    expect(searchScrollback(scrollback, 'kubernetes'), isEmpty);
    expect(searchScrollback(const [], 'nginx'), isEmpty);
  });

  test('the cap stops the list, and says that it did', () {
    final many = [for (var i = 0; i < 50; i++) 'line $i match'];
    final matches = searchScrollback(many, 'match', maxMatches: 10);

    expect(matches, hasLength(10));
    expect(
      matchesTruncated(many, 'match', maxMatches: 10),
      isTrue,
      reason: 'a list of ten out of fifty must not look like all of them',
    );
    expect(
      matchesTruncated(many, 'nothing-here', maxMatches: 10),
      isFalse,
    );
    expect(
      matchesTruncated([for (var i = 0; i < 5; i++) 'x match'], 'match'),
      isFalse,
      reason: 'a complete list is not truncated',
    );
  });

  test('the truncation check agrees with the case setting', () {
    final lines = [for (var i = 0; i < 5; i++) 'ERROR $i'];

    expect(
      matchesTruncated(lines, 'error', maxMatches: 2),
      isTrue,
      reason: 'all five lines match case-insensitively, so the cap overflows',
    );
    expect(
      matchesTruncated(lines, 'error', caseSensitive: true, maxMatches: 2),
      isFalse,
      reason: 'nothing matches lowercase `error` case-sensitively, so the cap '
          'is never reached',
    );
    expect(
      matchesTruncated(lines, 'ERROR', caseSensitive: true, maxMatches: 2),
      isTrue,
    );
  });
}
