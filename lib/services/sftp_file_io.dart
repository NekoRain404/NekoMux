import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

/// Reading and writing a whole small file in one piece.
///
/// Extracted from [SftpService] as free functions over the client: they are the
/// two operations that buffer everything in memory, which is exactly why they
/// are used only where a size guard has already run — the text preview and the
/// "new empty file" flow — and never by a transfer, which streams.
///
/// The service keeps the connection checks and the failure mapping; what lives
/// here is only the part that talks to the SFTP client.

/// Reads all of [path], in whatever chunks the server sends.
Future<Uint8List> readWholeFile(SftpClient sftp, String path) async {
  final file = await sftp.open(path, mode: SftpFileOpenMode.read);
  try {
    final chunks = await file.read().toList();
    final total = chunks.fold<int>(0, (sum, chunk) => sum + chunk.length);
    final buffer = Uint8List(total);
    var offset = 0;
    for (final chunk in chunks) {
      buffer.setRange(offset, offset + chunk.length, chunk);
      offset += chunk.length;
    }
    return buffer;
  } finally {
    await file.close();
  }
}

/// Replaces the contents of [path] with [data], creating the file if it is not
/// there.
///
/// Truncating is the point: this is an overwrite, and every caller has already
/// decided that overwriting is what the user asked for (the preview page's save,
/// or the new-file flow's own overwrite confirmation).
Future<void> writeWholeFile(
  SftpClient sftp,
  String path,
  Uint8List data,
) async {
  final file = await sftp.open(
    path,
    mode:
        SftpFileOpenMode.write |
        SftpFileOpenMode.create |
        SftpFileOpenMode.truncate,
  );
  try {
    await file.writeBytes(data);
  } finally {
    await file.close();
  }
}
