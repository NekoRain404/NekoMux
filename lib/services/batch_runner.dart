import 'dart:async';

import '../models/credential.dart';
import '../models/host.dart';
import 'command_result.dart';

/// What one host's run ended as.
enum BatchStatus {
  /// Queued, not started.
  pending,

  /// Connected, command sent, waiting for the answer.
  running,

  /// The command ran and reported success.
  succeeded,

  /// The command ran and reported failure, or reported nothing at all.
  failed,

  /// Never connected: the host key was not trusted.
  ///
  /// Its own status rather than a failure, because the remedy is different and
  /// the batch cannot supply it: trusting a key is a decision the user makes on
  /// a connection they asked for. A batch never makes it — prompting once per
  /// host would be a modal storm, and accepting silently is exactly what the
  /// known-hosts table exists to prevent.
  needsTrust,

  /// Never connected: no credential, or the connection itself failed.
  unreachable,

  /// The user stopped the batch before this host started.
  cancelled,
}

/// One host's result.
class BatchHostResult {
  final Host host;
  final BatchStatus status;

  /// The remote exit status, when the server reported one. Null is *unknown*,
  /// not success — see [CommandResult.ok].
  final int? exitCode;

  final String stdout;
  final String stderr;

  /// Why this host did not run or did not succeed, in the user's language.
  final String? error;

  /// How long the command took on this host, or null when it never ran.
  final Duration? duration;

  const BatchHostResult({
    required this.host,
    required this.status,
    this.exitCode,
    this.stdout = '',
    this.stderr = '',
    this.error,
    this.duration,
  });

  /// Whether this host finished, one way or another.
  bool get isTerminal => switch (status) {
    BatchStatus.succeeded ||
    BatchStatus.failed ||
    BatchStatus.needsTrust ||
    BatchStatus.unreachable ||
    BatchStatus.cancelled => true,
    BatchStatus.pending || BatchStatus.running => false,
  };

  BatchHostResult copyWith({
    BatchStatus? status,
    int? exitCode,
    String? stdout,
    String? stderr,
    String? error,
    Duration? duration,
  }) => BatchHostResult(
    host: host,
    status: status ?? this.status,
    exitCode: exitCode ?? this.exitCode,
    stdout: stdout ?? this.stdout,
    stderr: stderr ?? this.stderr,
    error: error ?? this.error,
    duration: duration ?? this.duration,
  );
}

/// The one operation a batch needs from a connection.
///
/// The narrowest seam that lets the fan-out, the failure isolation and the
/// cancellation be tested without a socket — the same shape `TransferSession`
/// takes for the transfer queue.
abstract class BatchSession {
  /// Opens the connection.
  Future<void> connect();

  /// Runs [command] and waits for it.
  Future<CommandResult> run(String command);

  /// True once a host key was presented and refused during [connect].
  ///
  /// The connection surfaces a refused key as an authentication abort, so the
  /// failure alone cannot say whether it was the key or the credentials — see
  /// `console/connect_outcome.dart`. The batch needs the difference: one is the
  /// user's to fix, the other is a wrong password.
  bool get trustRefused;

  /// Releases the connection.
  void dispose();
}

/// Builds a session for one host, using [credential].
typedef BatchSessionFactory =
    BatchSession Function(Host host, Credential credential);

/// A session that can also move files.
///
/// Deliberately a *subtype* rather than a wider [BatchSession]. A session that
/// runs commands has nothing sensible to do when asked to upload, and putting
/// `putFile` on the base would force every implementer — including the fakes the
/// tests run on — to write a method they cannot honour. The implementers use
/// `implements`, so a throwing default would never be inherited anyway and would
/// only mislead. Here the type says which batch a session may be handed to.
abstract class BatchTransferSession implements BatchSession {
  /// Copies the local file at [localPath] to [remotePath] on the host.
  Future<void> putFile(String localPath, String remotePath);
}

/// Builds a transfer session for one host, using [credential].
typedef BatchTransferSessionFactory =
    BatchTransferSession Function(Host host, Credential credential);

/// Runs one command across many hosts, with a bounded number in flight.
///
/// The whole point is that the user types the command once: on a phone, a
/// command that has to be sent to five machines is otherwise typed five times
/// on a soft keyboard.
///
/// Concurrency is bounded because each host is a full SSH session — a batch of
/// thirty opened at once is thirty handshakes, thirty PTY-less channels and
/// thirty keepalive timers against the same phone radio, and the ones that time
/// out first would be reported as unreachable when they are merely queued.
class BatchRunner {
  /// How many hosts may be connected at once.
  final int concurrency;

  /// Called whenever a host's result changes, so the UI can paint progress.
  final void Function(BatchHostResult result) onUpdate;

  final List<BatchHostResult> _results = [];
  final Map<String, BatchSession> _live = {};
  var _cancelled = false;
  var _running = false;

  BatchRunner({required this.onUpdate, this.concurrency = 4});

  /// Every host's result, in the order the hosts were given.
  List<BatchHostResult> get results => List.unmodifiable(_results);

  /// True while hosts are still being worked through.
  bool get isRunning => _running;

  /// Stops the batch: nothing new starts, and everything in flight is released.
  ///
  /// A command already running on a server cannot be recalled — the remote
  /// process keeps going. What this stops is the app waiting for it, which is
  /// what the user is actually asking for when they press stop.
  void cancel() {
    _cancelled = true;
    for (final session in _live.values.toList()) {
      session.dispose();
    }
    _live.clear();
  }

  /// Runs [command] on every host in [hosts], reporting each result as it lands.
  ///
  /// [credentialFor] returns the credential a host authenticates with, or null
  /// when it has none — reported per host rather than aborting the batch, since
  /// one misconfigured host must not stop the other twenty.
  Future<void> run({
    required List<Host> hosts,
    required String command,
    required BatchSessionFactory sessionFor,
    required Credential? Function(Host host) credentialFor,
  }) => _fanOut(
    hosts: hosts,
    sessionFor: sessionFor,
    credentialFor: credentialFor,
    work: (host, session, started) async {
      final result = await session.run(command);
      return BatchHostResult(
        host: host,
        status: result.ok ? BatchStatus.succeeded : BatchStatus.failed,
        exitCode: result.exitCode,
        stdout: result.stdout,
        stderr: result.stderr,
        duration: DateTime.now().difference(started),
      );
    },
  );

  /// Copies one local file to many hosts.
  ///
  /// The same fan-out as [run] with an upload in place of a command. On a phone
  /// this is the difference between deploying a config to five servers and
  /// typing the same `scp` five times on a soft keyboard.
  ///
  /// The local file is opened once per host rather than once for the batch:
  /// each upload needs its own stream, and buffering the whole file to avoid
  /// re-reading it is how a phone runs out of memory on the one file large
  /// enough to matter.
  Future<void> transfer({
    required List<Host> hosts,
    required String localPath,
    required String remotePath,
    required BatchTransferSessionFactory sessionFor,
    required Credential? Function(Host host) credentialFor,
  }) => _fanOut(
    hosts: hosts,
    sessionFor: sessionFor,
    credentialFor: credentialFor,
    work: (host, session, started) async {
      await session.putFile(localPath, remotePath);
      return BatchHostResult(
        host: host,
        status: BatchStatus.succeeded,
        duration: DateTime.now().difference(started),
      );
    },
  );

  /// Runs [work] against every host, with a bounded number in flight.
  ///
  /// The shape lives here rather than in either caller because it is the part
  /// that is easy to get subtly wrong — the queue, the bound, one host's failure
  /// staying its own, and the difference between cancelling a host that has not
  /// started and one that is already running. Only the work differs between a
  /// command and a file, so only the work is passed in.
  Future<void> _fanOut<S extends BatchSession>({
    required List<Host> hosts,
    required S Function(Host host, Credential credential) sessionFor,
    required Credential? Function(Host host) credentialFor,
    required Future<BatchHostResult> Function(
      Host host,
      S session,
      DateTime started,
    ) work,
  }) async {
    if (_running) return;
    _running = true;
    _cancelled = false;
    _results
      ..clear()
      ..addAll([
        for (final host in hosts)
          BatchHostResult(host: host, status: BatchStatus.pending),
      ]);

    final queue = List<int>.generate(hosts.length, (i) => i);

    Future<void> worker() async {
      while (queue.isNotEmpty) {
        if (_cancelled) return;
        final index = queue.removeAt(0);
        final host = hosts[index];

        final credential = credentialFor(host);
        if (credential == null) {
          _publish(
            index,
            BatchHostResult(
              host: host,
              status: BatchStatus.unreachable,
              error: 'no_credential',
            ),
          );
          continue;
        }

        _publish(
          index,
          BatchHostResult(host: host, status: BatchStatus.running),
        );

        final session = sessionFor(host, credential);
        _live[host.id] = session;
        final started = DateTime.now();
        try {
          await session.connect();
          // Published even if the user cancelled while it was running: the work
          // did happen on that server, and reporting it as cancelled would hide
          // a result the user asked for and cannot get back. Cancel stops hosts
          // that have not run yet; it cannot un-run one.
          _publish(index, await work(host, session, started));
        } catch (e) {
          if (_cancelled) continue;
          _publish(
            index,
            BatchHostResult(
              host: host,
              status: session.trustRefused
                  ? BatchStatus.needsTrust
                  : BatchStatus.unreachable,
              error: e is Exception ? e.toString() : '$e',
              duration: DateTime.now().difference(started),
            ),
          );
        } finally {
          _live.remove(host.id);
          session.dispose();
        }
      }
    }

    try {
      await Future.wait([
        for (var i = 0; i < concurrency && i < hosts.length; i++) worker(),
      ]);
    } finally {
      _running = false;
      // Anything still marked pending or running was never reached: say so
      // rather than leaving a row that looks like it might still happen.
      if (_cancelled) {
        for (var i = 0; i < _results.length; i++) {
          if (!_results[i].isTerminal) {
            _publish(
              i,
              _results[i].copyWith(status: BatchStatus.cancelled),
            );
          }
        }
      }
    }
  }

  void _publish(int index, BatchHostResult result) {
    _results[index] = result;
    onUpdate(result);
  }
}
