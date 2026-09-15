import 'package:flutter/material.dart';
import '../core/i18n/strings.dart';
import '../widgets/app_ui.dart';

/// Utility class that shows a dialog for resolving `[PLACEHOLDER]` patterns in a command string.
class SnippetInjectionDialog {
  SnippetInjectionDialog._();

  /// Parses [PLACEHOLDER] patterns from [command] and shows a dialog
  /// for the user to fill in values. Returns the command with placeholders
  /// replaced, or `null` if the user cancelled.
  static Future<String?> show(BuildContext context, String command) async {
    /// Regex to match placeholders like [name], [path], etc.
    final placeholderRegex = RegExp(r'\[(\w+)\]');
    final matches = placeholderRegex.allMatches(command).toList();
    if (matches.isEmpty) return command;

    /// Extract unique placeholders while preserving appearance order.
    final seen = <String>{};
    final placeholders = <String>[];
    for (final m in matches) {
      final name = m.group(1)!;
      if (seen.add(name)) {
        placeholders.add(name);
      }
    }

    /// Create a controller and focus node for each placeholder field.
    final controllers = <String, TextEditingController>{};
    final focusNodes = <String, FocusNode>{};
    for (final p in placeholders) {
      controllers[p] = TextEditingController();
      focusNodes[p] = FocusNode();
    }

    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => _InjectionFormDialog(
        placeholders: placeholders,
        controllers: controllers,
        focusNodes: focusNodes,
        command: command,
      ),
    );

    /// Dispose controllers and focus nodes regardless of the outcome.
    for (final c in controllers.values) {
      c.dispose();
    }
    for (final f in focusNodes.values) {
      f.dispose();
    }

    return result;
  }
}

/// Internal dialog widget that renders a form with one field per placeholder.
class _InjectionFormDialog extends StatefulWidget {
  final List<String> placeholders;
  final Map<String, TextEditingController> controllers;
  final Map<String, FocusNode> focusNodes;
  final String command;

  const _InjectionFormDialog({
    required this.placeholders,
    required this.controllers,
    required this.focusNodes,
    required this.command,
  });

  @override
  State<_InjectionFormDialog> createState() => _InjectionFormDialogState();
}

class _InjectionFormDialogState extends State<_InjectionFormDialog> {
  /// Form key for validating all placeholder fields.
  final _formKey = GlobalKey<FormState>();

  /// Validates all fields and performs placeholder substitution, then pops with the result.
  void _confirm() {
    if (!_formKey.currentState!.validate()) return;

    var result = widget.command;
    for (final p in widget.placeholders) {
      result = result.replaceAll('[$p]', widget.controllers[p]!.text);
    }
    Navigator.pop(context, result);
  }

  /// Builds a styled input decoration for a placeholder field.
  InputDecoration _decoration(String placeholder) {
    final cs = Theme.of(context).colorScheme;
    return InputDecoration(
      labelText: placeholder,
      labelStyle: TextStyle(color: cs.onSurface.withValues(alpha: 0.62)),
      hintText: t('input_value_for').replaceAll('{0}', placeholder),
      hintStyle: TextStyle(color: cs.onSurface.withValues(alpha: 0.42)),
      filled: true,
      fillColor: Theme.of(context).scaffoldBackgroundColor,
      enabledBorder: OutlineInputBorder(
        borderSide: BorderSide(color: Theme.of(context).dividerColor),
        borderRadius: const BorderRadius.all(Radius.circular(8)),
      ),
      focusedBorder: OutlineInputBorder(
        borderSide: BorderSide(color: cs.secondary, width: 1.5),
        borderRadius: const BorderRadius.all(Radius.circular(8)),
      ),
      errorBorder: OutlineInputBorder(
        borderSide: BorderSide(color: cs.error),
        borderRadius: const BorderRadius.all(Radius.circular(8)),
      ),
      focusedErrorBorder: OutlineInputBorder(
        borderSide: BorderSide(color: cs.error, width: 1.5),
        borderRadius: const BorderRadius.all(Radius.circular(8)),
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return AlertDialog(
      backgroundColor: cs.surface,
      title: Text(
        t('inject_variables'),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(color: cs.onSurface),
      ),
      content: SingleChildScrollView(
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              AppCard(
                margin: const EdgeInsets.only(bottom: 16),
                padding: const EdgeInsets.all(12),
                color: Theme.of(context).scaffoldBackgroundColor,
                child: Text(
                  widget.command,
                  maxLines: 4,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: cs.onSurface.withValues(alpha: 0.74),
                    fontFamily: 'monospace',
                    fontSize: 12,
                    height: 1.4,
                  ),
                ),
              ),

              /// Render a text field for each unique placeholder.
              for (int i = 0; i < widget.placeholders.length; i++) ...[
                if (i > 0) const SizedBox(height: 14),
                TextFormField(
                  controller: widget.controllers[widget.placeholders[i]],
                  focusNode: widget.focusNodes[widget.placeholders[i]],
                  style: TextStyle(color: cs.onSurface),
                  textInputAction: i == widget.placeholders.length - 1
                      ? TextInputAction.done
                      : TextInputAction.next,

                  /// Advance focus to the next field on submit, or confirm on the last field.
                  onFieldSubmitted: (_) {
                    if (i < widget.placeholders.length - 1) {
                      widget.focusNodes[widget.placeholders[i + 1]]
                          ?.requestFocus();
                    } else {
                      _confirm();
                    }
                  },
                  decoration: _decoration(widget.placeholders[i]),
                  validator: (v) => (v == null || v.trim().isEmpty)
                      ? t(
                          'please_fill',
                        ).replaceAll('{0}', widget.placeholders[i])
                      : null,
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        /// Cancel button: dismiss without injecting.
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(
            t('cancel'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: cs.onSurface.withValues(alpha: 0.62)),
          ),
        ),

        /// Inject button: perform substitution and return the result.
        TextButton(
          onPressed: _confirm,
          child: Text(
            t('inject'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: cs.secondary),
          ),
        ),
      ],
    );
  }
}
