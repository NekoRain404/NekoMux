import 'package:flutter_test/flutter_test.dart';
import 'package:neko_mux/models/credential.dart';
import 'package:neko_mux/models/host.dart';
import 'package:neko_mux/services/sftp_service.dart';

/// Guards the three capability methods [SftpService] gained on top of the
/// operations it already had.
///
/// What they promise cannot be exercised without a server — one of them returns
/// false for a missing file, and there is no file to be missing here — so this
/// file holds the parts that *are* reachable with no connection: the signatures
/// callers compile against, and the one error path every method can take. The
/// decisions they depend on are asserted in `sftp_format_test.dart`, next to the
/// pure helpers that make them: which status code means "absent", and which mode
/// bits a permission change owns.

SftpService newService() => SftpService(
  host: Host(
    id: 'h1',
    alias: 'test',
    ipAddress: '127.0.0.1',
    credentialId: 'c1',
  ),
  credential: const Credential(
    id: 'c1',
    name: 'test',
    authType: 0,
    username: 'root',
    secretData: 'secret',
  ),
);

/// A mode as it is written everywhere else: `octal(644)` is the `0o644` of a
/// `chmod` you would type. Dart has no octal literals, and 420 would hide the
/// value these tests are about.
int octal(int digits) => int.parse('$digits', radix: 8);

/// The failure every one of these methods raises with no session, asserted on
/// the code rather than on any text.
Matcher get notConnected => throwsA(
  isA<SftpException>().having((e) => e.kind, 'kind', SftpFailure.notConnected),
);

void main() {
  group('the signatures callers compile against', () {
    test('each capability has the shape its call site expects', () {
      final service = newService();

      // Assigning each member to an explicitly typed variable is a compile-time
      // assertion on its signature: if a later change alters one, this file
      // stops compiling rather than silently breaking a call site.
      final Future<bool> Function(String) exists = service.exists;
      final Future<void> Function(String, int) setPermissions =
          service.setPermissions;
      final Future<String> Function(String) resolvePath = service.resolvePath;

      expect(exists, isNotNull);
      expect(setPermissions, isNotNull);
      expect(resolvePath, isNotNull);
    });
  });

  group('with no session', () {
    test('exists throws rather than answering false', () async {
      // The one thing this method must never do is turn "I could not look" into
      // "there is nothing there": a caller that warns before overwriting would
      // warn about nothing, or — worse, were the polarity reversed — overwrite a
      // file without asking. A not-connected service is exactly the case where
      // the answer is unknown, so it has to come back as an error.
      await expectLater(newService().exists('/etc/passwd'), notConnected);
    });

    test('setPermissions reports that there is no session', () async {
      await expectLater(
        newService().setPermissions('/etc/passwd', octal(644)),
        notConnected,
      );
    });

    test('resolvePath reports that there is no session', () async {
      await expectLater(
        newService().resolvePath('../etc/passwd'),
        notConnected,
      );
    });

    test('a disconnect does not make them answer from a stale session', () async {
      // `_ensureConnected` is the whole guard, so the failure has to survive the
      // teardown path too — a method that kept a cached SFTP client around would
      // sail past this.
      final service = newService();
      await service.disconnect();

      await expectLater(service.exists('/etc/passwd'), notConnected);
      await expectLater(
        service.setPermissions('/etc/passwd', octal(600)),
        notConnected,
      );
      await expectLater(service.resolvePath('.'), notConnected);
    });
  });
}
