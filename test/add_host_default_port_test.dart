import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neko_mux/core/i18n/strings.dart';
import 'package:neko_mux/models/credential.dart';
import 'package:neko_mux/models/host.dart';
import 'package:neko_mux/pages/add_host_page.dart';
import 'package:neko_mux/providers/providers.dart';
import 'package:neko_mux/providers/settings_provider.dart';

/// Settings that resolve without touching a database.
class _FixedSettings extends SettingsNotifier {
  _FixedSettings(this.settings);

  final AppSettings settings;

  @override
  Future<AppSettings> build() async => settings;
}

/// Credentials that resolve to nothing, so the page never reaches the database
/// and the credential dropdown renders its "add one first" branch.
class _NoCredentials extends CredentialListNotifier {
  @override
  Future<List<Credential>> build() async => const <Credential>[];
}

void main() {
  /// Opens [AddHostPage] the way the user does — pushed over the host list —
  /// with the default-port setting already loaded.
  ///
  /// The page reads the setting in `initState`, and in the running app it is
  /// loaded long before the page can be reached; awaiting it here reproduces
  /// that, so the test measures the defect rather than a startup race.
  Future<ProviderContainer> openAddHost(
    WidgetTester tester, {
    required int defaultPort,
    Host? existingHost,
  }) async {
    final container = ProviderContainer.test(
      overrides: [
        settingsProvider.overrideWith(
          () => _FixedSettings(AppSettings(defaultPort: defaultPort)),
        ),
        credentialListProvider.overrideWith(_NoCredentials.new),
      ],
    );
    await container.read(settingsProvider.future);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Builder(
            builder: (ctx) => Scaffold(
              body: TextButton(
                onPressed: () => Navigator.of(ctx).push(
                  MaterialPageRoute<void>(
                    builder: (_) => AddHostPage(existingHost: existingHost),
                  ),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    return container;
  }

  /// The text field carrying [label]. `TextFormField` does not expose its
  /// decoration, but the `TextField` it builds does — so the field is found by
  /// its own label rather than by its position in the form.
  Finder fieldByLabel(String label) => find.byWidgetPredicate(
    (w) => w is TextField && w.decoration?.labelText == label,
    description: 'TextField labelled "$label"',
  );

  /// The port field's current text.
  String portText(WidgetTester tester) =>
      tester.widget<TextField>(fieldByLabel(t('port'))).controller!.text;

  testWidgets('a new host is pre-filled with the default-port setting', (
    tester,
  ) async {
    // The reported defect: the field was seeded from a literal 22, so the
    // setting reached nothing and the user saw 22 after choosing 2222.
    await openAddHost(tester, defaultPort: 2222);
    expect(portText(tester), '2222');
  });

  testWidgets('the default setting still pre-fills 22', (tester) async {
    // The common path must be untouched by the change.
    await openAddHost(tester, defaultPort: 22);
    expect(portText(tester), '22');
  });

  testWidgets('editing a host shows that host\'s port, not the default', (
    tester,
  ) async {
    await openAddHost(
      tester,
      defaultPort: 2222,
      existingHost: Host(
        id: 'h1',
        alias: 'alpha',
        ipAddress: '10.0.0.1',
        port: 22,
        credentialId: 'c1',
      ),
    );
    expect(portText(tester), '22');
  });

  testWidgets('an untouched new-host form is not treated as modified', (
    tester,
  ) async {
    // The trap: if the dirty check kept comparing against a hardcoded '22',
    // a form pre-filled with the user's 2222 would look modified the instant
    // it opened, and backing out would nag about discarding changes nobody
    // made.
    await openAddHost(tester, defaultPort: 2222);

    await tester.tap(find.byIcon(Icons.arrow_back));
    await tester.pumpAndSettle();

    expect(find.text(t('discard_changes_title')), findsNothing);
    // It left immediately, which is the visible half of the same fact.
    expect(find.byType(AddHostPage), findsNothing);
  });

  testWidgets('a form the user did touch is still treated as modified', (
    tester,
  ) async {
    // The other half of the trap: fixing the comparison must not make the
    // page forget to warn about real edits.
    await openAddHost(tester, defaultPort: 2222);

    await tester.enterText(fieldByLabel(t('host_alias')), 'beta');
    await tester.pump();

    await tester.tap(find.byIcon(Icons.arrow_back));
    await tester.pumpAndSettle();

    expect(find.text(t('discard_changes_title')), findsOneWidget);
  });
}
