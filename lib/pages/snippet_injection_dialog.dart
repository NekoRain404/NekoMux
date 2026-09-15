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

    /// The dialog creates and releases one controller and focus node per
    /// placeholder itself, so that their lifetime is the dialog's own — see
    /// [_InjectionFormDialog] for why releasing them here, once this future has
    /// completed, is a few frames too early.
    /// 每个占位符所需的控制器与焦点节点由对话框自行创建与释放，使它们的生命周期与
    /// 对话框一致——为什么在这个 future 完成后才去释放它们会早几帧，见
    /// [_InjectionFormDialog]。
    return showDialog<String>(
      context: context,
      builder: (ctx) =>
          _InjectionFormDialog(placeholders: placeholders, command: command),
    );
  }
}

/// Internal dialog widget that renders a form with one field per placeholder.
/// 内部对话框部件，为每个占位符渲染一个输入框。
///
/// The controllers and focus nodes it needs are created here and released in
/// [dispose], so they live exactly as long as the dialog's own element.
/// Creating them in [SnippetInjectionDialog.show] and releasing them when
/// `showDialog`'s future completes — once their only repair — is early by a few
/// frames: that future completes when the route is *popped*, while the dialog
/// keeps animating out and its fields keep rebuilding, and a rebuild that
/// reaches a released editor throws
/// `A FocusNode was used after being disposed`.
/// 它需要的控制器与焦点节点在此创建、在 [dispose] 中释放，因此生命周期与对话框自身的
/// element 一致。若在 [SnippetInjectionDialog.show] 中创建、并在 `showDialog` 的
/// future 完成时释放（这曾是唯一的补救做法），则会早几帧：该 future 在路由被弹出时就
/// 完成，而对话框还要继续播放退场动画并重建输入框，一次重建若碰到已释放的编辑器就会
/// 抛出 `A FocusNode was used after being disposed`。
class _InjectionFormDialog extends StatefulWidget {
  final List<String> placeholders;
  final String command;

  const _InjectionFormDialog({
    required this.placeholders,
    required this.command,
  });

  @override
  State<_InjectionFormDialog> createState() => _InjectionFormDialogState();
}

class _InjectionFormDialogState extends State<_InjectionFormDialog> {
  /// Form key for validating all placeholder fields. A `GlobalKey` owns no
  /// resources, so it needs no counterpart in [dispose].
  /// 用于校验全部占位符输入框的表单键。`GlobalKey` 不拥有资源，因此无需在 [dispose]
  /// 中有对应操作。
  final _formKey = GlobalKey<FormState>();

  /// One text controller and focus node per placeholder, in [placeholders]
  /// order.
  /// 每个占位符一个文本控制器与焦点节点，顺序与 [placeholders] 一致。
  final _controllers = <String, TextEditingController>{};
  final _focusNodes = <String, FocusNode>{};

  @override
  void initState() {
    super.initState();
    for (final placeholder in widget.placeholders) {
      _controllers[placeholder] = TextEditingController();
      _focusNodes[placeholder] = FocusNode();
    }
  }

  @override
  void dispose() {
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    for (final focusNode in _focusNodes.values) {
      focusNode.dispose();
    }
    super.dispose();
  }

  /// Validates all fields and performs placeholder substitution, then pops with the result.
  void _confirm() {
    if (!_formKey.currentState!.validate()) return;

    var result = widget.command;
    for (final p in widget.placeholders) {
      result = result.replaceAll('[$p]', _controllers[p]!.text);
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
                  controller: _controllers[widget.placeholders[i]],
                  focusNode: _focusNodes[widget.placeholders[i]],
                  style: TextStyle(color: cs.onSurface),
                  textInputAction: i == widget.placeholders.length - 1
                      ? TextInputAction.done
                      : TextInputAction.next,

                  /// Advance focus to the next field on submit, or confirm on the last field.
                  onFieldSubmitted: (_) {
                    if (i < widget.placeholders.length - 1) {
                      _focusNodes[widget.placeholders[i + 1]]?.requestFocus();
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
