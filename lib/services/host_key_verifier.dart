import 'dart:typed_data';

/// Formats host key fingerprints and provides a short-lived in-memory trust cache.
class HostKeyVerifier {
  static final Set<String> _acceptedFingerprints = {};

  HostKeyVerifier._();

  static String formatMd5(Uint8List bytes) {
    return 'MD5:${bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join(':')}';
  }

  static bool isAccepted(String fingerprint) {
    return _acceptedFingerprints.contains(fingerprint);
  }

  static void accept(String fingerprint) {
    _acceptedFingerprints.add(fingerprint);
  }
}
