/// One line of the terminal's scrollback that matched.
class ScrollbackMatch {
  /// The line's number in the buffer, counting from the oldest line kept.
  final int lineNumber;

  /// The line's text, as the terminal holds it.
  final String text;

  /// Where the query sits inside [text], for a caller that wants to show it in
  /// context rather than the whole line.
  final int start;
  final int end;

  const ScrollbackMatch({
    required this.lineNumber,
    required this.text,
    required this.start,
    required this.end,
  });
}

/// Searches [lines] for [query].
///
/// A phone has no `grep` on the scrollback, and the alternative to this is
/// scrolling a log by thumb until the eye catches something — which is what the
/// user is doing when they open this.
///
/// Case-insensitive by default, because the thing being looked for is usually a
/// service name or an error word whose capitalisation the user is not sure of,
/// and a search that returns nothing because of a capital letter is worse than
/// no search at all.
///
/// [maxMatches] caps the result rather than the work: a query like `e` on a long
/// scrollback matches nearly every line, and a list of thousands of them is not
/// a search result a person can read. The cap is reported by [matchesTruncated]
/// so the caller can say so instead of implying the list is everything.
List<ScrollbackMatch> searchScrollback(
  List<String> lines,
  String query, {
  bool caseSensitive = false,
  int maxMatches = 200,
}) {
  if (query.isEmpty) return const [];

  final needle = caseSensitive ? query : query.toLowerCase();
  final matches = <ScrollbackMatch>[];

  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];
    final haystack = caseSensitive ? line : line.toLowerCase();
    final at = haystack.indexOf(needle);
    if (at < 0) continue;

    matches.add(
      ScrollbackMatch(
        lineNumber: i,
        text: line,
        start: at,
        end: at + query.length,
      ),
    );
    if (matches.length >= maxMatches) break;
  }

  return matches;
}

/// Whether [lines] held more matches than [matches] carries.
///
/// Recomputed rather than returned alongside, so the search stays one function
/// whose result is the list — and so a caller that renders "200+" is doing it
/// from the same numbers the search used.
bool matchesTruncated(
  List<String> lines,
  String query, {
  bool caseSensitive = false,
  int maxMatches = 200,
}) {
  if (query.isEmpty) return false;
  final needle = caseSensitive ? query : query.toLowerCase();
  var found = 0;
  for (final line in lines) {
    final haystack = caseSensitive ? line : line.toLowerCase();
    if (haystack.contains(needle)) {
      found++;
      if (found > maxMatches) return true;
    }
  }
  return false;
}
