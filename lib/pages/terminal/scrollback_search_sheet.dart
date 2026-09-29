import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/i18n/strings.dart';
import '../../core/theme/app_fonts.dart';
import 'scrollback_search.dart';

/// The scrollback search, end to end: ask, look, show.
///
/// Extracted from the terminal page, which had reached the project's line limit
/// — and because it is a coherent unit that owns no state beyond a text field.
/// The page's half is one line: hand over the buffer's text, because reading it
/// is the only part that needs the terminal.
///
/// Returns once the results are dismissed. An empty result is a snackbar rather
/// than an empty sheet: a sheet with nothing in it looks like a failure to
/// search, and the honest answer is "no line contains that".

/// Asks what to look for in [lines] and shows what matched.
Future<void> showScrollbackSearch(
  BuildContext context, {
  required List<String> lines,
}) async {
  final query = await showDialog<String>(
    context: context,
    builder: (_) => const ScrollbackSearchDialog(),
  );
  if (query == null || query.isEmpty || !context.mounted) return;

  final matches = searchScrollback(lines, query);
  if (!context.mounted) return;

  if (matches.isEmpty) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(t('terminal_search_no_match').replaceAll('{0}', query)),
        behavior: SnackBarBehavior.floating,
      ),
    );
    return;
  }

  await showModalBottomSheet<void>(
    context: context,
    backgroundColor: Theme.of(context).colorScheme.surface,
    isScrollControlled: true,
    showDragHandle: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(8)),
    ),
    builder: (_) => ScrollbackResults(
      query: query,
      matches: matches,
      truncated: matchesTruncated(lines, query),
    ),
  );
}

/// Asks what to look for in the scrollback.
class ScrollbackSearchDialog extends StatefulWidget {
  const ScrollbackSearchDialog({super.key});

  @override
  State<ScrollbackSearchDialog> createState() =>
      ScrollbackSearchDialogState();
}

class ScrollbackSearchDialogState extends State<ScrollbackSearchDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return AlertDialog(
      backgroundColor: cs.surface,
      title: Text(t('terminal_search'), style: TextStyle(color: cs.onSurface)),
      content: TextField(
        controller: _controller,
        autofocus: true,
        style: TextStyle(
          color: cs.onSurface,
          fontFamily: AppFonts.mono,
          fontSize: 13,
        ),
        decoration: InputDecoration(
          hintText: t('terminal_search_hint'),
          hintStyle: TextStyle(color: cs.onSurface.withValues(alpha: 0.4)),
          border: const OutlineInputBorder(),
        ),
        onSubmitted: (value) => Navigator.pop(context, value.trim()),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(
            t('cancel'),
            style: TextStyle(color: cs.onSurface.withValues(alpha: 0.62)),
          ),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context, _controller.text.trim()),
          child: Text(t('terminal_search'), style: TextStyle(color: cs.primary)),
        ),
      ],
    );
  }
}

/// The lines that matched, each one tappable to copy.
class ScrollbackResults extends StatelessWidget {
  final String query;
  final List<ScrollbackMatch> matches;
  final bool truncated;

  const ScrollbackResults({
    super.key,
    required this.query,
    required this.matches,
    required this.truncated,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.7,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      truncated
                          ? t('terminal_search_matches_more').replaceAll(
                              '{0}',
                              '${matches.length}',
                            )
                          : t('terminal_search_matches').replaceAll(
                              '{0}',
                              '${matches.length}',
                            ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: cs.onSurface.withValues(alpha: 0.7),
                        fontSize: 12,
                      ),
                    ),
                  ),
                  TextButton.icon(
                    onPressed: () {
                      Clipboard.setData(
                        ClipboardData(
                          text: matches.map((m) => m.text).join('\n'),
                        ),
                      );
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text(t('copied'))),
                      );
                    },
                    icon: Icon(Icons.copy, size: 16, color: cs.secondary),
                    label: Text(
                      t('terminal_search_copy_all'),
                      style: TextStyle(color: cs.secondary, fontSize: 12),
                    ),
                  ),
                ],
              ),
            ),
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: matches.length,
                itemBuilder: (context, index) {
                  final match = matches[index];
                  return InkWell(
                    onTap: () {
                      Clipboard.setData(ClipboardData(text: match.text.trim()));
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text(t('copied'))),
                      );
                    },
                    child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 20,
                        vertical: 10,
                      ),
                      decoration: BoxDecoration(
                        border: Border(
                          bottom: BorderSide(
                            color: Theme.of(context).dividerColor,
                            width: 0.5,
                          ),
                        ),
                      ),
                      child: Text(
                        match.text.trim(),
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: cs.onSurface,
                          fontSize: 11,
                          height: 1.45,
                          fontFamily: AppFonts.mono,
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
