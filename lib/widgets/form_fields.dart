import 'package:flutter/material.dart';

import '../core/theme/app_fonts.dart';

/// A labelled text field in the app's own shape.
///
/// Every form in this app had grown its own `InputDecoration` — the same four
/// borders, the same label colour, the same fill — and they had already drifted:
/// one used the divider colour for the enabled border and another the surface
/// variant, so two screens asked for the same input in visibly different boxes.
///
/// [monospace] is for values the user is reproducing from somewhere else — a
/// path, an image name, a port pair. Seeing them in the same face as the command
/// preview below the form is what makes the two readable against each other.
class AppFormField extends StatelessWidget {
  final TextEditingController controller;
  final String label;
  final String? hint;

  /// Rendered in the terminal face. Values that are meant to be reproduced
  /// exactly, not prose.
  final bool monospace;

  final bool obscureText;
  final int maxLines;
  final TextInputType? keyboardType;
  final String? Function(String?)? validator;
  final void Function(String)? onChanged;

  const AppFormField({
    super.key,
    required this.controller,
    required this.label,
    this.hint,
    this.monospace = false,
    this.obscureText = false,
    this.maxLines = 1,
    this.keyboardType,
    this.validator,
    this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final divider = Theme.of(context).dividerColor;

    OutlineInputBorder border(Color colour, [double width = 1]) =>
        OutlineInputBorder(
          borderSide: BorderSide(color: colour, width: width),
          borderRadius: const BorderRadius.all(Radius.circular(8)),
        );

    return TextFormField(
      controller: controller,
      obscureText: obscureText,
      maxLines: obscureText ? 1 : maxLines,
      keyboardType: keyboardType,
      validator: validator,
      onChanged: onChanged,
      style: TextStyle(
        color: cs.onSurface,
        fontSize: 14,
        fontFamily: monospace ? AppFonts.mono : null,
      ),
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        labelStyle: TextStyle(color: cs.onSurface.withValues(alpha: 0.6)),
        hintStyle: TextStyle(color: cs.onSurface.withValues(alpha: 0.38)),
        filled: true,
        fillColor: cs.surface,
        enabledBorder: border(divider),
        focusedBorder: border(cs.secondary, 1.5),
        errorBorder: border(cs.error),
        focusedErrorBorder: border(cs.error, 1.5),
      ),
    );
  }
}
