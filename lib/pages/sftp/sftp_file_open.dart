import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../core/i18n/strings.dart';
import '../../models/file_item.dart';
import '../../services/sftp_service.dart';
import '../file_preview_page.dart';
import 'sftp_error_text.dart';

/// Opens a remote text file in the preview page, and saves it back.
///
/// Extracted from the page rather than left as a method: reading the file,
/// guarding its size and writing it back are one story with one owner — the
/// connection — and none of it touches the directory listing, the selection or
/// the transfer queue that the page is otherwise made of.
///
/// [notify] reports what the user needs to see (a size refusal, a failed read, a
/// failed save); the page owns the messenger, so it stays the caller's.
Future<void> openSftpTextFile(
  BuildContext context, {
  required SftpService service,
  required FileItem file,
  required void Function(String message, {bool isError}) notify,
}) async {
  // Refuse before reading, not after. The preview page has its own size guard,
  // but it only ever sees content that has already been pulled into memory:
  // `readFile` buffers every chunk and the whole thing is decoded to a String
  // first, so the out-of-memory happens before that guard can run. The directory
  // listing already told us the size, so nothing needs to be fetched to make
  // this decision.
  //
  // Compared in bytes against a limit expressed in code units: for the ASCII
  // logs and configs that matter, bytes >= code units, so this errs towards
  // refusing a file that would in fact have fit — the safe direction.
  if (file.size > FilePreviewPage.maxContentLength) {
    notify(t('file_too_large'), isError: true);
    return;
  }

  final Uint8List bytes;
  try {
    bytes = await service.readFile(file.path);
  } on SftpException catch (e) {
    notify(sftpErrorText(e), isError: true);
    return;
  } catch (e) {
    notify(_loadFailedMessage('$e'), isError: true);
    return;
  }
  if (!context.mounted) return;

  // Remote "text" files are routinely GBK or Latin-1 on a Chinese-locale
  // server. Strict decoding threw FormatException, which nothing caught and
  // nobody awaited: the tap simply did nothing. allowMalformed keeps those files
  // readable, and the helper below covers any other decode failure.
  String content;
  try {
    content = utf8.decode(bytes, allowMalformed: true);
  } on FormatException catch (_) {
    notify(_loadFailedMessage(file.name), isError: true);
    return;
  }

  await Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (pageContext) => FilePreviewPage(
        filename: file.name,
        content: content,
        onSave: (newContent) async {
          try {
            await service.writeFile(
              file.path,
              Uint8List.fromList(utf8.encode(newContent)),
            );
            notify(t('file_saved'), isError: false);
          } on SftpException catch (e) {
            notify(sftpErrorText(e), isError: true);
          }
        },
      ),
    ),
  );
}

/// "Load failed: …" for a file that could not be read or decoded.
String _loadFailedMessage(String detail) =>
    t('load_failed_msg').replaceAll('{0}', detail);
