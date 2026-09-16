/// The arithmetic behind the "change permissions" dialog.
///
/// Pure and page-side on purpose: one direction converts the listing's symbolic
/// mode into the octal the dialog is prefilled with, the other turns what the
/// user typed back into the integer `setPermissions` wants. Neither touches a
/// connection or a widget, so both are pinned by tests rather than by looking at
/// a screen — and getting this wrong means silently setting a file to 000 or to
/// a mode the user did not ask for.
library;

import 'package:flutter/material.dart';

import '../../core/i18n/strings.dart';

/// The octal mode for a symbolic string, or `''` when it cannot be read.
///
/// [permissions] is what the listing carries: nine characters, `rwx`-style,
/// with `-` for an absent bit (`rw-r--r--`). A ten-character listing string is
/// accepted too, with its type character dropped (`drwxr-xr-x`).
///
/// Returns `''` rather than a guess for a string that is not nine readable
/// characters: prefilling the dialog with a wrong mode is worse than prefilling
/// it with nothing, because the user then confirms arithmetic they never saw.
String octalFromSymbolic(String permissions) {
  // The type character is stripped first, and by *position* rather than by
  // searching for the first `r`/`w`/`x`: `-` is both a permission placeholder
  // and the regular-file type character, so `-rw-r--r--` cannot be told from a
  // nine-character string that starts with an absent bit. Position can: a
  // ten-character string whose first character is a known type character is a
  // listing string, and its mode is the remaining nine.
  var bits = permissions.trim();
  if (bits.length >= 10 && 'dl-cbps'.contains(bits[0])) {
    bits = bits.substring(1);
  }
  if (bits.length < 9) return '';
  bits = bits.substring(0, 9);

  final buffer = StringBuffer();
  for (var group = 0; group < 3; group++) {
    var digit = 0;
    final offset = group * 3;
    if (bits[offset] == 'r') digit += 4;
    if (bits[offset + 1] == 'w') digit += 2;
    // `s` and `t` are the execute bit *plus* a special bit (setuid/setgid on
    // the first two groups, sticky on the last) — never the absence of
    // execute, which is what `-` means and what a naive read would take them
    // for.
    final exec = bits[offset + 2];
    if (exec == 'x' || exec == 's' || exec == 't') digit += 1;
    buffer.write(digit);
  }
  return buffer.toString();
}

/// The permission bits for what the user typed, or null when it is not a mode.
///
/// Accepts three or four octal digits (`755`, `0755`). The four-digit form is
/// kept — it is how `chmod` is usually written and what `stat` prints — but only
/// the low three are used, because the leading digit carries setuid/setgid/sticky
/// and those change what the file *does*, not who may touch it. This dialog
/// exists for permissions.
int? parseOctalMode(String input) {
  final trimmed = input.trim();
  if (trimmed.isEmpty) return null;

  // The four-digit form is the `chmod 4755` / `stat` spelling, where the leading
  // digit carries setuid, setgid and sticky. It is dropped rather than applied:
  // this dialog changes who may read, write and execute an entry, and a digit
  // that silently made a program setuid would be a privilege change nobody
  // asked for and nothing on screen would show. It is still *checked* to be an
  // octal digit first — otherwise any four-character string whose tail looks
  // like a mode (`-755`) would be accepted, and the hyphen would quietly become
  // "no special bits".
  final digits = trimmed.length == 4 ? trimmed.substring(1) : trimmed;
  if (digits.length != 3) return null;
  if (trimmed.length == 4 && !_isOctalDigit(trimmed.codeUnitAt(0))) return null;

  var value = 0;
  for (final rune in digits.codeUnits) {
    if (!_isOctalDigit(rune)) return null;
    value = value * 8 + (rune - 0x30);
  }
  return value;
}

/// Whether [rune] is ASCII `0`-`7`.
bool _isOctalDigit(int rune) => rune >= 0x30 && rune <= 0x37;

/// Asks for a new permission mode for [name], prefilled with [current].
///
/// Returns the parsed bits, or null when the dialog was dismissed or what was
/// typed is not a mode. An empty prefill is deliberate when the listing's
/// symbolic mode could not be read (see [octalFromSymbolic]): a blank field asks
/// the user for the mode, whereas a wrong prefill asks them to approve
/// arithmetic they never saw.
Future<int?> showSftpChmodDialog(
  BuildContext context, {
  required String name,
  required String current,
}) async {
  final typed = await showDialog<String>(
    context: context,
    builder: (_) => _ChmodDialog(name: name, initial: octalFromSymbolic(current)),
  );
  if (typed == null) return null;
  final mode = parseOctalMode(typed);
  if (mode == null && context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(t('chmod_invalid')),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }
  return mode;
}

/// The prompt, stateful so its text field's controller has an owner.
///
/// Disposing the controller after `showDialog`'s future completes is *not* the
/// fix and fails in the field: that future completes when the route is popped,
/// while the dialog is still animating out and its field still rebuilding, and a
/// rebuild that reaches a disposed controller throws. Ownership by the dialog,
/// released when the route itself is disposed, is the only correct shape — the
/// same reason `sftp_dialogs.dart` and `settings/backup_dialogs.dart` made their
/// prompts stateful.
class _ChmodDialog extends StatefulWidget {
  const _ChmodDialog({required this.name, required this.initial});

  final String name;
  final String initial;

  @override
  State<_ChmodDialog> createState() => _ChmodDialogState();
}

class _ChmodDialogState extends State<_ChmodDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initial,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return AlertDialog(
      backgroundColor: cs.surface,
      title: Text(t('chmod'), style: TextStyle(color: cs.onSurface)),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            widget.name,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: cs.onSurface.withValues(alpha: 0.7),
              fontSize: 13,
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _controller,
            autofocus: true,
            keyboardType: TextInputType.number,
            maxLength: 4,
            style: TextStyle(color: cs.onSurface),
            decoration: InputDecoration(
              hintText: '755',
              counterText: '',
              hintStyle: TextStyle(color: cs.onSurface.withValues(alpha: 0.4)),
              border: const OutlineInputBorder(),
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(
            t('cancel'),
            style: TextStyle(color: cs.onSurface.withValues(alpha: 0.62)),
          ),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context, _controller.text),
          child: Text(t('confirm'), style: TextStyle(color: cs.primary)),
        ),
      ],
    );
  }
}
