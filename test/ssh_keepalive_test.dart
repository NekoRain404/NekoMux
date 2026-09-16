import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neko_mux/models/credential.dart';
import 'package:neko_mux/models/host.dart';
import 'package:neko_mux/services/sftp_service.dart';
import 'package:neko_mux/services/ssh_service.dart';

/// Guards the keep-alive both connection paths hand to dartssh2.
///
/// The defect this exists for is silence: neither service passed
/// `keepAliveInterval` at all, so dartssh2 used its own default and nothing in
/// the app said so. An idle console or a stalled transfer then died without a
/// word when the phone slept or a carrier NAT dropped the flow — the socket
/// stayed open and the wait never ended. Nothing about that is observable from a
/// test that runs without a server, so the two halves of the guarantee are
/// checked separately: the value (a default two services share, honoured by
/// dartssh2) and the *forwarding* of it (every `SSHClient` construction in
/// `lib/`, which is a property of call sites and is read from the source).

Host hostOn(int port) => Host(
  id: 'h1',
  alias: 'test',
  ipAddress: '127.0.0.1',
  port: port,
  credentialId: 'c1',
);

const credential = Credential(
  id: 'c1',
  name: 'test',
  authType: 0,
  username: 'root',
  secretData: 'secret',
);

/// An [SSHSocket] connected to nothing: enough to construct a client over, which
/// is all these tests need. A real listener would add a port, a timer and a way
/// to be flaky, and would answer none of the questions asked here.
class _SilentSocket implements SSHSocket {
  final _incoming = StreamController<Uint8List>();
  final _outgoing = StreamController<List<int>>();
  final _done = Completer<void>();

  @override
  Stream<Uint8List> get stream => _incoming.stream;

  @override
  StreamSink<List<int>> get sink => _outgoing.sink;

  @override
  Future<void> get done => _done.future;

  @override
  Future<void> close() async {
    if (!_done.isCompleted) _done.complete();
  }

  @override
  void destroy() {}
}

/// The interval dartssh2 actually ends up holding when a client is built the way
/// the services build one.
Future<Duration?> intervalHeldByClient(Duration interval) async {
  final client = SSHClient(
    _SilentSocket(),
    username: 'root',
    keepAliveInterval: interval,
  );
  // Nothing will ever answer this socket, so `authenticated` never completes;
  // the listener is here because a completer nobody listened to would report its
  // error into the test's zone the moment the client is closed.
  unawaited(client.authenticated.then((_) {}, onError: (Object _) {}));
  final held = client.keepAliveInterval;
  client.close();
  return held;
}

//
// Deliberately a second implementation of the shape found in
// `host_key_verifier_wiring_test.dart` rather than an import of it: two
// tripwires that share one parser share its blind spots, and the guarantee each
// one makes is about a different argument of a different constructor.

/// Whether [source] opens a string literal at [i], and how long its delimiter is.
int _stringDelimiterAt(String source, int i) {
  final c = source[i];
  if (c != "'" && c != '"') return 0;
  if (i + 2 < source.length && source[i + 1] == c && source[i + 2] == c) {
    return 3;
  }
  return 1;
}

/// [source] with its comments removed, so a construction named in prose cannot be
/// mistaken for one — and so a `//` inside a string cannot delete real code.
String stripComments(String source) {
  final out = StringBuffer();
  var i = 0;
  String? quote;

  while (i < source.length) {
    final c = source[i];

    if (quote != null) {
      if (c == r'\' && quote.length == 1) {
        out.write(source.substring(i, (i + 2).clamp(0, source.length)));
        i += 2;
        continue;
      }
      if (source.startsWith(quote, i)) {
        out.write(quote);
        i += quote.length;
        quote = null;
        continue;
      }
      if (c == '\n') out.write(c); // keep the line numbers honest
      i++;
      continue;
    }

    final delimiter = _stringDelimiterAt(source, i);
    if (delimiter > 0) {
      quote = source.substring(i, i + delimiter);
      out.write(quote);
      i += delimiter;
      continue;
    }
    if (c == '/' && source.startsWith('//', i)) {
      while (i < source.length && source[i] != '\n') {
        i++;
      }
      continue;
    }
    if (c == '/' && source.startsWith('/*', i)) {
      i += 2;
      while (i < source.length && !source.startsWith('*/', i)) {
        if (source[i] == '\n') out.write('\n');
        i++;
      }
      i += 2;
      continue;
    }

    out.write(c);
    i++;
  }
  return out.toString();
}

/// The text between the parentheses of the call that opens at [open] — nested
/// calls and strings included, because a bracket inside either must not end the
/// argument list early.
String argumentsAt(String source, int open) {
  var depth = 0;
  String? quote;
  var i = open;

  while (i < source.length) {
    final c = source[i];

    if (quote != null) {
      if (c == r'\' && quote.length == 1) {
        i += 2;
        continue;
      }
      if (source.startsWith(quote, i)) {
        i += quote.length;
        quote = null;
        continue;
      }
      i++;
      continue;
    }

    final delimiter = _stringDelimiterAt(source, i);
    if (delimiter > 0) {
      quote = source.substring(i, i + delimiter);
      i += delimiter;
      continue;
    }
    if (c == '(') depth++;
    if (c == ')') {
      depth--;
      if (depth == 0) return source.substring(open + 1, i);
    }
    i++;
  }
  return '';
}

/// One `SSHClient` construction: where it is, and what it passes.
class Construction {
  Construction(this.line, this.args);

  /// 1-based line of the construction in the scanned source.
  final int line;

  /// The text between the call's parentheses.
  final String args;

  /// Whether a keep-alive interval is among the arguments.
  bool get passesKeepAlive => args.contains('keepAliveInterval:');

  @override
  String toString() =>
      'line $line: SSHClient(${args.trim().split('\n').first.trim()} …)';
}

/// Every `SSHClient` construction in [source].
///
/// A type annotation (`SSHClient? _client;`) has no parenthesis and is not
/// matched; a construction always does.
List<Construction> constructionsIn(String source) {
  final code = stripComments(source);
  final found = <Construction>[];

  for (final match in RegExp(r'\bSSHClient\(').allMatches(code)) {
    final args = argumentsAt(code, match.end - 1);
    final line = '\n'.allMatches(code.substring(0, match.start)).length + 1;
    found.add(Construction(line, args));
  }
  return found;
}

/// The constructions in [source] that pass no keep-alive interval.
List<String> silentConstructions(String source) => constructionsIn(
  source,
).where((c) => !c.passesKeepAlive).map((c) => '$c').toList();

/// The Dart files under [root].
List<File> dartSources(String root) {
  final dir = Directory(root);
  expect(dir.existsSync(), isTrue, reason: '$root is missing');
  return dir
      .listSync(recursive: true)
      .whereType<File>()
      .where((file) => file.path.endsWith('.dart'))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));
}

/// What a construction that omits it costs, in the words the reader of a failure
/// needs.
String get whyItMatters =>
    'dartssh2 only pings the server when it was given an interval '
    '(ssh_client.dart: `_keepAlive = keepAliveInterval != null ? '
    'SSHKeepAlive(ping: ping, interval: keepAliveInterval!) : null`), and a '
    'session that never pings is one the phone\'s sleep or a carrier NAT can '
    'drop without anything here noticing: the socket stays open and the wait '
    'for an answer never ends. Pass `keepAliveInterval: keepAliveInterval`.';

void main() {
  group('the keep-alive default', () {
    test('is 30s, and both services answer with the same value', () {
      // Pinned, not read: 30s is the number the two services document, and a
      // change to it is a decision that should have to update this line.
      expect(
        SshConnection.defaultKeepAliveInterval,
        const Duration(seconds: 30),
      );
      // The terminal and the file manager must not keep their sessions alive on
      // two different numbers, so the second is the first rather than a copy.
      expect(
        SftpService.defaultKeepAliveInterval,
        SshConnection.defaultKeepAliveInterval,
      );
    });

    test('a connection that is given nothing keeps the default', () {
      final conn = SshConnection(host: hostOn(22), credential: credential);
      addTearDown(conn.dispose);

      expect(conn.keepAliveInterval, SshConnection.defaultKeepAliveInterval);
    });

    test('a connection honours the interval it is given', () {
      final conn = SshConnection(
        host: hostOn(22),
        credential: credential,
        keepAliveInterval: const Duration(seconds: 5),
      );
      addTearDown(conn.dispose);

      // Five seconds is not thirty: a field that ignored its argument and always
      // reported the constant would pass the test above and fail this one.
      expect(conn.keepAliveInterval, const Duration(seconds: 5));
    });

    test('an SFTP session that is given nothing keeps the default', () {
      final service = SftpService(host: hostOn(22), credential: credential);

      expect(service.keepAliveInterval, SftpService.defaultKeepAliveInterval);
    });

    test('an SFTP session honours the interval it is given', () async {
      final service = SftpService(
        host: hostOn(22),
        credential: credential,
        keepAliveInterval: const Duration(seconds: 5),
      );
      addTearDown(service.disconnect);

      expect(service.keepAliveInterval, const Duration(seconds: 5));
    });

    test('dartssh2 holds the interval it is handed', () async {
      // The other end of the wire: dartssh2 takes the parameter under this name
      // and keeps it (`ssh_client.dart`, line ~183), which is what makes handing
      // ours over worth anything.
      expect(
        await intervalHeldByClient(SshConnection.defaultKeepAliveInterval),
        SshConnection.defaultKeepAliveInterval,
      );
      expect(
        await intervalHeldByClient(const Duration(seconds: 7)),
        const Duration(seconds: 7),
      );
    });
  });

  group('the scanner itself', () {
    // Without these, a scan that matched nothing would look exactly like a scan
    // that found every construction correct.

    test('flags a construction with no interval, and says where', () {
      const source = '''
        final a = SSHClient(
          socket,
          username: user,
        );

        final b = SSHClient(
          socket,
          keepAliveInterval: keepAliveInterval,
          username: user,
        );

        final c = SSHClient(socket, username: user);
      ''';
      expect(silentConstructions(source), [
        startsWith('line 1:'),
        startsWith('line 12:'),
      ]);
    });

    test('does not mistake an annotation, a comment or a string for one', () {
      // `SSHClient? _client;` is a type, not a construction; a construction
      // named in prose is not one; and a `//` inside a string cannot truncate
      // the line it sits on.
      const source = """
        SSHClient? _client;
        // Rebuilt on every connect: SSHClient(socket, username: user).
        final url = 'https://example.invalid/x';
        final a = SSHClient(
          socket,
          keepAliveInterval: keepAliveInterval,
          username: user,
        );
      """;
      expect(silentConstructions(source), isEmpty);
    });

    test('sees through nested calls and strings', () {
      const source = """
        final a = SSHClient(
          socket,
          keepAliveInterval: keepAliveInterval,
          identities: credential.authType == 1
              ? SSHKeyPair.fromPem('not a bracket )')
              : null,
        );
      """;
      expect(silentConstructions(source), isEmpty);

      // The same construction with the argument removed must be flagged, or the
      // parser above is simply swallowing everything.
      const missing = """
        final a = SSHClient(
          socket,
          identities: SSHKeyPair.fromPem('not a bracket )'),
        );
      """;
      expect(silentConstructions(missing), hasLength(1));
    });
  });

  test('every SSHClient in lib/ is given a keep-alive interval', () {
    final offenders = <String>[];
    var scanned = 0;
    var constructions = 0;

    for (final file in dartSources('lib')) {
      scanned++;
      final found = constructionsIn(file.readAsStringSync());
      constructions += found.length;
      offenders.addAll(
        found
            .where((construction) => !construction.passesKeepAlive)
            .map((construction) => '${file.path} $construction'),
      );
    }

    expect(scanned, greaterThan(20), reason: 'the scan read almost nothing');
    // Without this the test would pass by finding nothing, which is the failure
    // mode of every source scan.
    expect(
      constructions,
      greaterThanOrEqualTo(2),
      reason:
          'the two services are the only things in lib/ that open an SSH '
          'connection; finding fewer than two constructions means this tripwire '
          'is not watching them',
    );
    expect(
      offenders,
      isEmpty,
      reason:
          'a client is built without a keep-alive interval:\n'
          '${offenders.join('\n')}\n\n$whyItMatters',
    );
  });
}
