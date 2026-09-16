import 'package:flutter/material.dart';

import '../../core/i18n/strings.dart';
import '../../services/sftp_service.dart';
import 'sftp_dialogs.dart';
import 'sftp_error_text.dart';

/// Asks for a directory path and returns it in the form the server resolved it
/// to, or null when nothing should be opened.
///
/// The breadcrumb bar can only go *up*: reaching `/var/log/nginx` from `/` meant
/// tapping through `var`, `log`, `nginx` — and a directory more than a level
/// deep in a listing of hundreds is a hunt, not a navigation. A server's paths
/// are known to the person managing it, so the app asks instead of making them
/// scroll.
///
/// Free function in the style of the dialogs beside it: it asks and resolves,
/// and the page — which owns the listing, the selection and the current
/// directory — decides what to do with the answer. Failures are reported through
/// [onError] rather than swallowed, because the two ways this can fail (a path
/// that does not resolve, a connection that has gone) both leave the user
/// staring at an unchanged screen.
Future<String?> promptForRemotePath(
  BuildContext context, {
  required SftpService service,
  required String currentDir,
  required void Function(String message) onError,
}) async {
  // The same dialog the rename and create flows use: it asks for a string and
  // reports null for cancelled, blank or unchanged — the three answers that mean
  // "do nothing" here as well.
  final typed = await showSftpNameDialog(
    context,
    title: t('go_to_path'),
    hint: t('go_to_path_hint'),
    confirmLabel: t('confirm'),
    initial: currentDir,
  );
  if (typed == null) return null;

  try {
    // Resolved by the server rather than by string handling here: `..`, a
    // trailing slash and a relative name all mean what sftp-server says they
    // mean, and the path bar then shows the canonical form that was opened.
    // `~` is the one thing this cannot do — sftp-server does not expand it —
    // which the hint says out loud.
    return await service.resolvePath(typed);
  } on SftpException catch (e) {
    onError(sftpErrorText(e));
    return null;
  } catch (e) {
    onError(sftpFailureText(SftpFailure.list, '$e'));
    return null;
  }
}
