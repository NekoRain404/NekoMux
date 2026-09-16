import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../core/i18n/strings.dart';
import '../../models/file_item.dart';
import '../../services/sftp_service.dart';
import '../../widgets/app_ui.dart';
import 'sftp_dialogs.dart';
import 'sftp_error_text.dart';
import 'sftp_path.dart';

/// The page's four write operations on remote entries.
///
/// Each one has the same shape — ask the user, act on the connection, report
/// what happened, reload — and the differences between them are the answers to
/// "what do I ask", "what do I write" and "what do I say". Kept out of the page
/// because that shape repeated four times is what pushed `sftp_page.dart` past
/// the project's 800-line limit, and because none of them touches the listing,
/// the selection or the transfer queue the page is otherwise made of.
///
/// They take the page's pieces rather than reaching for them: the [SftpService]
/// that owns the connection, the directory the page is showing, and a `notify`
/// callback (the page owns the messenger). Each returns once the server has
/// answered; the caller reloads the listing afterwards, because only the caller
/// knows whether the directory on screen is still the one that changed.

/// Renames [file] to a name the user types, in the directory [dir].
Future<void> renameSftpEntry(
  BuildContext context, {
  required SftpService service,
  required String dir,
  required FileItem file,
  required void Function(String message, {bool isError}) notify,
}) async {
  final name = await showSftpNameDialog(
    context,
    title: t('rename'),
    hint: file.name,
    initial: file.name,
    confirmLabel: t('confirm'),
  );
  if (name == null) return;

  try {
    await service.rename(file.path, sftpChildPath(dir, name));
    notify(t('file_renamed'), isError: false);
  } on SftpException catch (e) {
    notify(sftpErrorText(e), isError: true);
  }
}

/// Deletes one entry after confirming it.
Future<void> deleteSftpEntry(
  BuildContext context, {
  required SftpService service,
  required FileItem file,
  required void Function(String message, {bool isError}) notify,
}) async {
  final confirmed = await confirmSftpDelete(context, file.name);
  if (!confirmed) return;

  try {
    await service.deleteFile(file.path);
    notify(t('file_deleted'), isError: false);
  } on SftpException catch (e) {
    notify(sftpErrorText(e), isError: true);
  }
}

/// The "new file / new folder" flow: choose a kind, name it, create it.
///
/// A new file is written as zero bytes, so naming an existing file truncates it
/// — the one action here that destroys data while looking like it creates
/// something. Retyping a name you already used is the ordinary way to reach
/// this, so it is asked about rather than allowed.
Future<void> createSftpEntry(
  BuildContext context, {
  required SftpService service,
  required String dir,
  required void Function(String message, {bool isError}) notify,
}) async {
  final kind = await showSftpNewEntryChooser(context);
  if (kind == null || !context.mounted) return;

  final isFolder = kind == SftpNewEntryKind.folder;
  final name = await showSftpNameDialog(
    context,
    title: isFolder ? t('new_folder') : t('new_file_item'),
    hint: isFolder ? t('input_foldername') : t('input_filename'),
    confirmLabel: t('create'),
  );
  if (name == null || !context.mounted) return;

  final path = sftpChildPath(dir, name);
  try {
    if (isFolder) {
      await service.createDirectory(path);
    } else {
      if (await service.exists(path)) {
        if (!context.mounted) return;
        final overwrite = await showAppConfirmDialog(
          context,
          title: t('confirm_overwrite_title'),
          message: t('confirm_overwrite_file').replaceAll('{0}', name),
          cancelLabel: t('cancel'),
          confirmLabel: t('confirm'),
          destructive: true,
        );
        if (!overwrite || !context.mounted) return;
      }
      await service.writeFile(path, Uint8List(0));
    }
    notify(isFolder ? t('folder_created') : t('file_created'), isError: false);
  } on SftpException catch (e) {
    notify(sftpErrorText(e), isError: true);
  }
}

/// Deletes every path in [paths], then reports what actually happened.
///
/// Returns the number of failures, so the caller can decide whether the listing
/// it is about to reload is still worth showing.
///
/// A failure does not abort the batch: one unprotected file must not leave the
/// other thirty behind, which is the same rule the transfer queue follows.
Future<int> deleteSftpEntries(
  BuildContext context, {
  required SftpService service,
  required List<String> paths,
  required void Function(String message, {bool isError}) notify,
}) async {
  var failed = 0;
  for (final path in paths) {
    try {
      await service.deleteFile(path);
    } on SftpException catch (e) {
      failed++;
      notify(sftpErrorText(e), isError: true);
    } catch (e) {
      failed++;
      // Not an SftpException, so there is no code to map; report it as a failed
      // delete with its detail rather than showing a raw exception.
      notify(sftpFailureText(SftpFailure.delete, '$e'), isError: true);
    }
  }

  // A blanket "deleted" used to be shown even when every single delete had
  // failed, so the last thing the user read was a success message. Report the
  // failures by count instead; each reason was already shown per file.
  if (failed == 0) {
    notify(t('file_deleted'), isError: false);
  } else {
    notify(
      t('service_action_failed')
          .replaceAll('{0}', t('batch_delete'))
          .replaceAll('{1}', '$failed/${paths.length}'),
      isError: true,
    );
  }
  return failed;
}
