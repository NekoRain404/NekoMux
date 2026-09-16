import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neko_mux/core/i18n/strings.dart';
import 'package:neko_mux/models/snippet.dart';
import 'package:neko_mux/pages/snippet_list_page.dart';
import 'package:neko_mux/providers/providers.dart';

/// What a tap on a snippet row does, which depends on who opened the page.
///
/// The row has always popped the page with the snippet as its result. That is
/// right for the terminal, which opens this page as a picker and awaits what
/// comes back. It is wrong everywhere else: from the drawer the page was opened
/// to manage snippets, nobody read the result, and a tap therefore closed the
/// screen and did nothing — indistinguishable from a broken row.
class _FixedSnippets extends SnippetListNotifier {
  _FixedSnippets(this.snippets);

  final List<Snippet> snippets;

  @override
  Future<List<Snippet>> build() async => snippets;
}

const _restart = Snippet(
  id: 's1',
  title: 'Restart nginx',
  command: 'systemctl restart nginx',
);

/// Pushes [SnippetListPage] onto a route, and returns a getter for whatever the
/// page pops with.
Future<Snippet? Function()> pushSnippetPage(
  WidgetTester tester, {
  required bool popWithSelection,
}) async {
  Snippet? popped;
  var didPop = false;

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        snippetListProvider.overrideWith(() => _FixedSnippets(const [_restart])),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                popped = await Navigator.push<Snippet>(
                  context,
                  MaterialPageRoute(
                    builder: (_) =>
                        SnippetListPage(popWithSelection: popWithSelection),
                  ),
                );
                didPop = true;
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );

  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();

  return () => didPop ? popped : null;
}

void main() {
  setUp(() => AppStrings.setLang('en'));
  tearDown(() => AppStrings.setLang('zh'));

  testWidgets('opened as a picker, a tap returns the snippet', (tester) async {
    final result = await pushSnippetPage(tester, popWithSelection: true);

    await tester.tap(find.text('Restart nginx'));
    await tester.pumpAndSettle();

    expect(result(), isNotNull);
    expect(result()!.command, 'systemctl restart nginx');
    expect(
      find.byType(SnippetListPage),
      findsNothing,
      reason: 'the page closes once it has handed the snippet over',
    );
  });

  testWidgets('opened to manage, a tap copies the command and stays put', (
    tester,
  ) async {
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String?;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );

    final result = await pushSnippetPage(tester, popWithSelection: false);

    await tester.tap(find.text('Restart nginx'));
    await tester.pump();

    expect(
      find.byType(SnippetListPage),
      findsOneWidget,
      reason: 'managing snippets must not close the page on a tap',
    );
    expect(copied, 'systemctl restart nginx');
    expect(find.text('Copied to clipboard'), findsOneWidget);
    expect(result(), isNull, reason: 'nothing was handed to the caller');
  });
}
