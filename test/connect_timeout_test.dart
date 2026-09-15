import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neko_mux/providers/settings_provider.dart';
import 'package:neko_mux/providers/ssh_provider.dart';
import 'package:neko_mux/services/ssh_service.dart';

/// Settings that resolve without touching a database, so the only thing under
/// test is how the connect-timeout setting is turned into a [Duration].
class _FixedSettings extends SettingsNotifier {
  _FixedSettings(this.settings);

  final AppSettings settings;

  @override
  Future<AppSettings> build() async => settings;
}

ProviderContainer _containerWith(int connectTimeoutSeconds) =>
    ProviderContainer.test(
      overrides: [
        settingsProvider.overrideWith(
          () => _FixedSettings(
            AppSettings(connectTimeout: connectTimeoutSeconds),
          ),
        ),
      ],
    );

void main() {
  group('connectTimeoutProvider reads the setting', () {
    test('a chosen timeout reaches the caller', () async {
      final container = _containerWith(30);
      await container.read(settingsProvider.future);

      // The defect this guards: the number persisted fine and was then read by
      // nobody, so every session handshake used the constructor's 10s.
      expect(
        container.read(connectTimeoutProvider),
        const Duration(seconds: 30),
      );
    });

    test('a cold start behaves exactly as the old hardcoded default', () {
      final container = _containerWith(30);

      // Deliberately not awaited: this is the read that happens on the first
      // frame, while the settings row is still loading. It must not report the
      // user's value yet, and it must not report anything else either.
      expect(
        container.read(connectTimeoutProvider),
        const Duration(seconds: 10),
      );
    });

    test(
      'the provider fallback and the service default are the same value',
      () {
        // Two constants that must agree, so neither can drift.
        expect(
          const Duration(seconds: kDefaultConnectTimeoutSeconds),
          SshConnection.defaultConnectTimeout,
        );
      },
    );
  });

  group('probeConnectTimeout clamps the background probe', () {
    test('the default setting keeps the probe at its own fixed timeout', () {
      // Nothing the user does by leaving the setting alone may change what the
      // probe has always done.
      expect(
        probeConnectTimeout(const Duration(seconds: 10)),
        const Duration(seconds: 4),
      );
      expect(
        probeConnectTimeout(const Duration(seconds: 10)),
        kProbeConnectTimeoutCeiling,
      );
    });

    test('a long interactive timeout cannot stall a probe round', () {
      expect(
        probeConnectTimeout(const Duration(seconds: 30)),
        const Duration(seconds: 4),
      );
      expect(
        probeConnectTimeout(const Duration(minutes: 5)),
        kProbeConnectTimeoutCeiling,
      );
    });

    test('a shorter timeout is honoured, because a slow link asked for it', () {
      expect(
        probeConnectTimeout(const Duration(seconds: 2)),
        const Duration(seconds: 2),
      );
      expect(
        probeConnectTimeout(const Duration(seconds: 1)),
        const Duration(seconds: 1),
      );
    });

    test('the clamp never lengthens what it is given', () {
      for (final seconds in [1, 3, 4, 5, 10, 60]) {
        final configured = Duration(seconds: seconds);
        expect(probeConnectTimeout(configured) <= configured, isTrue);
        expect(
          probeConnectTimeout(configured) <= kProbeConnectTimeoutCeiling,
          isTrue,
        );
      }
    });
  });
}
