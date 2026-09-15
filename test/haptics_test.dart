import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neko_mux/core/haptics.dart';

/// Guards the setting that used to lie: eleven sites called `HapticFeedback.*`
/// unconditionally while Settings → haptic feedback persisted a switch nothing
/// read.
///
/// What is asserted here is the *decision*, observed at the only place it can
/// be observed without a device — the platform channel the call would travel
/// on. A suppressed call and a fired call are distinguishable precisely because
/// the mock below records what the app actually sent.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// Platform-channel calls the app made, in order.
  late List<MethodCall> calls;

  setUp(() {
    calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          calls.add(call);
          return null;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  /// The haptic payloads sent so far. `HapticFeedback` dispatches its request
  /// without awaiting it, so the channel is drained before the list is read.
  Future<List<String>> sent() async {
    await Future<void>.delayed(Duration.zero);
    return [
      for (final call in calls)
        if (call.method == 'HapticFeedback.vibrate') '${call.arguments}',
    ];
  }

  group('hapticIf fires when haptics are on', () {
    test('light maps to the light platform type', () async {
      hapticIf(true, HapticKind.light);
      expect(await sent(), ['HapticFeedbackType.lightImpact']);
    });

    test(
      'medium, heavy and selection map to their own platform types',
      () async {
        hapticIf(true, HapticKind.medium);
        hapticIf(true, HapticKind.heavy);
        hapticIf(true, HapticKind.selection);
        expect(await sent(), [
          'HapticFeedbackType.mediumImpact',
          'HapticFeedbackType.heavyImpact',
          'HapticFeedbackType.selectionClick',
        ]);
      },
    );
  });

  group('hapticIf is silent when haptics are off', () {
    test('every kind is suppressed', () async {
      hapticIf(false, HapticKind.light);
      hapticIf(false, HapticKind.medium);
      hapticIf(false, HapticKind.heavy);
      hapticIf(false, HapticKind.selection);
      expect(await sent(), isEmpty);
    });
  });

  group('an unloaded setting is not a "no"', () {
    // The value is `null` until `settingsProvider` resolves. Treating that as
    // "disabled" would make every vibration in the app disappear during a cold
    // start, which is the opposite of the default and the sort of regression
    // this whole change must not introduce.
    test('null behaves as the default, which is enabled', () async {
      hapticIf(null, HapticKind.light);
      expect(await sent(), ['HapticFeedbackType.lightImpact']);
    });

    test(
      'null and true are indistinguishable at the platform channel',
      () async {
        hapticIf(null, HapticKind.heavy);
        final fromNull = await sent();
        calls.clear();
        hapticIf(true, HapticKind.heavy);
        expect(await sent(), fromNull);
      },
    );
  });
}
