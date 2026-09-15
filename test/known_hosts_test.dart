import 'package:flutter_test/flutter_test.dart';
import 'package:neko_mux/services/known_hosts_store.dart';

/// Tests for the decision logic behind host key trust.
///
/// The decision is deliberately separated from persistence so it can be tested
/// without a database. What matters is the three-way outcome: a key we have
/// never seen, a key we already trust, and a key that CHANGED for a host we
/// already know — the last one is the only signal that a machine-in-the-middle
/// may be present, and the previous in-memory-only implementation could not
/// represent it at all.
void main() {
  group('evaluateHostKey', () {
    test('reports unknown for a host we have never recorded', () {
      final verdict = evaluateHostKey(
        storedFingerprint: null,
        presentedFingerprint: 'MD5:aa:bb',
      );

      expect(verdict, HostKeyVerdict.unknown);
    });

    test('reports trusted when the presented key matches the stored one', () {
      final verdict = evaluateHostKey(
        storedFingerprint: 'MD5:aa:bb',
        presentedFingerprint: 'MD5:aa:bb',
      );

      expect(verdict, HostKeyVerdict.trusted);
    });

    test('reports changed when the host presents a different key', () {
      final verdict = evaluateHostKey(
        storedFingerprint: 'MD5:aa:bb',
        presentedFingerprint: 'MD5:cc:dd',
      );

      expect(verdict, HostKeyVerdict.changed);
    });

    test('treats an empty stored fingerprint as unknown, not as changed', () {
      // A blank row is a storage artefact, not evidence of a key swap. Calling
      // it "changed" would train users to click through the one warning that
      // actually matters.
      final verdict = evaluateHostKey(
        storedFingerprint: '',
        presentedFingerprint: 'MD5:aa:bb',
      );

      expect(verdict, HostKeyVerdict.unknown);
    });

    test('comparison is exact, not case-insensitive', () {
      // Fingerprints are hex; a case difference means something garbled the
      // value in transit through storage, which deserves a fresh prompt rather
      // than a silent pass.
      final verdict = evaluateHostKey(
        storedFingerprint: 'MD5:AA:BB',
        presentedFingerprint: 'MD5:aa:bb',
      );

      expect(verdict, HostKeyVerdict.changed);
    });
  });

  group('hostKeyFor', () {
    test(
      'combines address and port so two ports on one host stay separate',
      () {
        expect(hostKeyFor('10.0.0.5', 22), '10.0.0.5:22');
        expect(hostKeyFor('10.0.0.5', 2222), '10.0.0.5:2222');
        expect(
          hostKeyFor('10.0.0.5', 22),
          isNot(equals(hostKeyFor('10.0.0.5', 2222))),
        );
      },
    );

    test('handles IPv6 literals without losing the port', () {
      final key = hostKeyFor('fe80::1', 22);

      expect(key.endsWith(':22'), isTrue);
      expect(key, contains('fe80::1'));
    });
  });
}
