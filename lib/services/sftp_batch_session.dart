// A batch session that moves a file instead of running a command.
//
// `SftpService` opens its own connection rather than lending one to the command
// session, which is why this is a separate type and not a method on
// `_RealBatchSession`: a transfer needs SFTP and nothing else, and a session
// that only uploads should not be holding an SSH client it never uses.

import 'dart:io';
import 'dart:typed_data';

import 'batch_runner.dart';
import 'command_result.dart';
import 'sftp_service.dart';

/// Uploads one local file per host, over SFTP.
class SftpBatchSession implements BatchTransferSession {
  /// The connected service this session drives.
  final SftpService service;

  SftpBatchSession(this.service);

  /// Never set: a refused host key fails [connect] outright here.
  ///
  /// The command batch distinguishes "refused key" from "wrong password"
  /// because it has to tell the user which to fix. A transfer reports the
  /// connection error it was given, which already names the key when that is
  /// what went wrong, so there is no second signal to invent.
  @override
  bool trustRefused = false;

  @override
  Future<void> connect() => service.connect();

  @override
  Future<CommandResult> run(String command) => throw UnsupportedError(
    'a transfer session moves files; it does not run commands',
  );

  @override
  Future<void> putFile(String localPath, String remotePath) async {
    // Checked before opening the stream so a mistyped or since-deleted local
    // file is reported as exactly that. Letting `openRead` fail surfaces the
    // same fact, but as a `FileSystemException` thrown from inside a stream —
    // which the caller sees only if it is listening when the error lands, and
    // which reads as a stack trace rather than as "that file is not there".
    final file = File(localPath);
    if (!await file.exists()) {
      throw FileSystemException('no such local file', localPath);
    }

    // Opened per host rather than read once into memory: the batch uploads to
    // several hosts, each needs its own stream, and buffering the file to avoid
    // re-reading it is how a phone runs out of memory on the one file big
    // enough to matter.
    await service.uploadStream(
      remotePath,
      file.openRead().map(Uint8List.fromList),
    );
  }

  @override
  void dispose() => service.disconnect();
}
