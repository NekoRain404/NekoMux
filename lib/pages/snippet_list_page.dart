import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/theme/app_fonts.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import '../core/i18n/strings.dart';
import '../models/snippet.dart';
import '../providers/providers.dart';
import '../widgets/app_drawer.dart';
import '../widgets/app_ui.dart';

/// Page that lists all saved command snippets with add/edit/delete capabilities. /// 列出所有已保存快捷指令的页面，支持新增/编辑/删除。
class SnippetListPage extends ConsumerStatefulWidget {
  /// Whether a tap on a row hands that snippet back to the caller.
  ///
  /// True only when this page is opened as a *picker* — the terminal does that,
  /// and awaits the result. Every other way in (the drawer, the `/snippets`
  /// route) opens it to manage snippets, and there a tap used to pop the page
  /// with a result nobody read: the tap closed the screen and did nothing else,
  /// which reads as a broken row rather than as a page that was not a picker.
  /// In those cases the tap copies the command instead, which is the useful
  /// thing to do with a saved command you are looking at.
  final bool popWithSelection;

  const SnippetListPage({super.key, this.popWithSelection = false});

  @override
  ConsumerState<SnippetListPage> createState() => _SnippetListPageState();
}

class _SnippetListPageState extends ConsumerState<SnippetListPage> {
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final snippetsAsync = ref.watch(snippetListProvider);

    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      drawer: const AppDrawer(currentModule: 'snippets', isTopLevel: true),
      appBar: AppBar(
        leading: Builder(
          builder: (ctx) => IconButton(
            icon: Icon(Icons.menu, color: cs.onSurface),
            onPressed: () => Scaffold.of(ctx).openDrawer(),
          ),
        ),
        title: Text(
          t('snippets'),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: cs.onSurface),
        ),
        actions: [
          /// Add new snippet button in the app bar. /// 导航栏中新增快捷指令的按钮。
          TextButton.icon(
            onPressed: () => _showSnippetDialog(),
            icon: Icon(Icons.add, color: cs.secondary, size: 20),
            label: Text(
              t('add'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: cs.secondary),
            ),
          ),
          const SizedBox(width: 4),
        ],
      ),

      /// Async snippet list: handles loading, error, empty, and data states. /// 异步指令列表：处理加载、错误、空和数据四种状态。
      body: snippetsAsync.when(
        loading: () =>
            Center(child: CircularProgressIndicator(color: cs.primary)),
        error: (e, _) => Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
            child: Text(
              '${t('error')}: $e',
              textAlign: TextAlign.center,
              maxLines: 6,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: cs.onSurface.withValues(alpha: 0.6)),
            ),
          ),
        ),
        data: (snippets) {
          if (snippets.isEmpty) {
            /// Empty state: prompt user to add the first snippet. /// 空状态：提示用户添加第一个快捷指令。
            return AppEmptyState(
              icon: Icons.terminal,
              title: t('empty_snippets'),
              message: t('empty_snippets_hint'),
              actionLabel: t('add_snippet'),
              color: cs.primary,
              onAction: () => _showSnippetDialog(),
            );
          }

          /// Snippet list with tap-to-select, long-press-to-edit, swipe-to-delete. /// 指令列表，支持点击选择、长按编辑、滑动删除。
          return ListView.builder(
            padding: const EdgeInsets.symmetric(vertical: 8),
            itemCount: snippets.length,
            itemBuilder: (context, index) {
              final snippet = snippets[index];
              return _SnippetTile(
                snippet: snippet,
                onTap: () {
                  if (widget.popWithSelection) {
                    Navigator.pop(context, snippet);
                    return;
                  }
                  Clipboard.setData(ClipboardData(text: snippet.command));
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(t('copied')),
                      behavior: SnackBarBehavior.floating,
                    ),
                  );
                },
                onEdit: () => _showSnippetDialog(existing: snippet),
                onDelete: () => _confirmDelete(snippet),
              );
            },
          );
        },
      ),
    );
  }

  /// Shows a dialog for adding or editing a snippet.
  /// 显示用于新增或编辑快捷指令的对话框。
  ///
  /// The dialog builds the [Snippet] itself and hands it back; this method only
  /// stores it. The editors the form needs belong to the dialog as well — see
  /// [_SnippetFormDialog] for why releasing them here, once this future has
  /// completed, is a few frames too early.
  /// 对话框自己构造 [Snippet] 并交还，本方法只负责保存。表单需要的编辑器同样属于
  /// 对话框——为什么在这个 future 完成后才去释放它们会早几帧，见 [_SnippetFormDialog]。
  Future<void> _showSnippetDialog({Snippet? existing}) async {
    final snippet = await showDialog<Snippet>(
      context: context,
      builder: (_) => _SnippetFormDialog(existing: existing),
    );
    if (snippet == null || !mounted) return;

    final isEditing = existing != null;
    // Awaited, so the confirmation cannot precede the write.
    // 必须 await，否则确认提示可能早于落库。
    try {
      final notifier = ref.read(snippetListProvider.notifier);
      if (isEditing) {
        await notifier.updateItem(snippet);
      } else {
        await notifier.addItem(snippet);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('${t('load_failed_msg')}: $e'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
      return;
    }
    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(isEditing ? t('snippet_updated') : t('snippet_added')),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  /// Shows a confirmation dialog before deleting a snippet. /// 删除快捷指令前显示确认对话框。
  Future<void> _confirmDelete(Snippet snippet) async {
    final confirmed = await showAppConfirmDialog(
      context,
      title: t('confirm_delete'),
      message: t('confirm_delete_snippet').replaceAll('{0}', snippet.title),
      cancelLabel: t('cancel'),
      confirmLabel: t('delete'),
      destructive: true,
    );
    if (!confirmed) return;

    try {
      await ref.read(snippetListProvider.notifier).deleteItem(snippet.id);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('${t('load_failed_msg')}: $e'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
  }
}

/// The add/edit snippet form, which creates and releases the editors it needs.
/// 新增/编辑快捷指令的表单，自行创建并释放所需的编辑器。
///
/// The two `TextEditingController`s used to be created per invocation in the
/// page and never released, so every opening leaked them along with whatever
/// had been typed. Releasing them from the page when `showDialog`'s future
/// completes — the obvious repair — is early by a few frames: that future
/// completes when the route is *popped*, while the dialog keeps animating out
/// and its fields keep rebuilding, and a rebuild that reaches a released
/// controller throws `A TextEditingController was used after being disposed`.
/// 两个 `TextEditingController` 过去由页面按次创建且从不释放，于是每次打开都会连同
/// 用户输入的内容一起泄漏。若改由页面在 `showDialog` 的 future 完成时释放——这是最
/// 直觉的修补——则会早几帧：该 future 在路由被弹出时就完成，而对话框还要继续播放退场
/// 动画并重建它的输入框，而一次重建若碰到已释放的控制器就会抛出
/// `A TextEditingController was used after being disposed`。
///
/// Owning them here instead ties their lifetime to the dialog's own element,
/// which is exactly the span during which its widgets can reach them.
/// 把它们交给这里，生命周期就与对话框自身的 element 一致，而对话框的部件能访问它们的
/// 时间正好也是这段区间。
class _SnippetFormDialog extends StatefulWidget {
  /// The snippet being edited, or null when a new one is being added.
  /// 正在编辑的快捷指令；新增时为 null。
  final Snippet? existing;

  const _SnippetFormDialog({this.existing});

  @override
  State<_SnippetFormDialog> createState() => _SnippetFormDialogState();
}

class _SnippetFormDialogState extends State<_SnippetFormDialog> {
  /// Validates both fields. A `GlobalKey` owns no resources, so unlike the
  /// controllers below it needs no counterpart in [dispose].
  /// 用于校验两个输入框。`GlobalKey` 不拥有资源，因此与下面的控制器不同，它不需要在
  /// [dispose] 中有对应操作。
  final _formKey = GlobalKey<FormState>();

  late final TextEditingController _titleController;
  late final TextEditingController _commandController;

  bool get _isEditing => widget.existing != null;

  @override
  void initState() {
    super.initState();
    _titleController = TextEditingController(
      text: widget.existing?.title ?? '',
    );
    _commandController = TextEditingController(
      text: widget.existing?.command ?? '',
    );
  }

  @override
  void dispose() {
    _titleController.dispose();
    _commandController.dispose();
    super.dispose();
  }

  /// Validates and closes the dialog with the snippet the user described.
  /// 校验后带着用户描述的快捷指令关闭对话框。
  void _save() {
    if (!_formKey.currentState!.validate()) return;

    /// Build the Snippet model; reuse existing ID when editing. /// 构建 Snippet 模型；编辑时复用已有 ID。
    Navigator.pop(
      context,
      Snippet(
        id: widget.existing?.id ?? const Uuid().v4(),
        title: _titleController.text.trim(),
        command: _commandController.text.trim(),
      ),
    );
  }

  InputDecoration _decoration(String label) {
    final cs = Theme.of(context).colorScheme;
    return InputDecoration(
      labelText: label,
      labelStyle: TextStyle(color: cs.onSurface.withValues(alpha: 0.6)),
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
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return AlertDialog(
      backgroundColor: cs.surface,
      title: Text(
        _isEditing ? t('edit_snippet') : t('add_snippet'),
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
              /// Snippet title input. /// 指令名称输入。
              TextFormField(
                controller: _titleController,
                style: TextStyle(color: cs.onSurface),
                decoration: _decoration(t('snippet_title')),
                validator: (v) => (v == null || v.trim().isEmpty)
                    ? t('must_enter_snippet_title')
                    : null,
              ),
              const SizedBox(height: 16),

              /// Snippet command body input (multi-line). /// 指令内容输入（多行）。
              TextFormField(
                controller: _commandController,
                style: TextStyle(color: cs.onSurface),
                maxLines: 5,
                decoration: _decoration(t('snippet_command')),
                validator: (v) => (v == null || v.trim().isEmpty)
                    ? t('must_enter_snippet_command')
                    : null,
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(
            t('cancel'),
            style: TextStyle(color: cs.onSurface.withValues(alpha: 0.6)),
          ),
        ),
        TextButton(
          onPressed: _save,
          child: Text(t('save'), style: TextStyle(color: cs.secondary)),
        ),
      ],
    );
  }
}

/// A single snippet list tile showing title, command preview, and actions. /// 单个指令列表项，显示标题、命令预览及操作。
class _SnippetTile extends StatelessWidget {
  final Snippet snippet;
  final VoidCallback onTap;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  const _SnippetTile({
    required this.snippet,
    required this.onTap,
    required this.onEdit,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    const maxCommandPreview = 60;

    /// Truncate long commands for preview display. /// 截断过长命令用于预览显示。
    final commandPreview = snippet.command.length > maxCommandPreview
        ? '${snippet.command.substring(0, maxCommandPreview)}...'
        : snippet.command;

    /// Swipe-to-delete wrapper; confirmDismiss triggers the delete callback without actually dismissing. /// 滑动删除包装器；confirmDismiss 触发删除回调但不实际执行滑动消除。
    return Dismissible(
      key: Key(snippet.id),
      direction: DismissDirection.endToStart,
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 24),
        color: cs.error,
        child: const Icon(Icons.delete_outline, color: Colors.white),
      ),
      confirmDismiss: (direction) async {
        onDelete();
        return false;
      },
      child: AppCard(
        onTap: onTap,
        onLongPress: onEdit,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          children: [
            /// Terminal icon for the snippet tile. /// 指令列表项的终端图标。
            AppIconBox(icon: Icons.terminal, color: cs.primary),
            const SizedBox(width: 14),

            /// Snippet title and truncated command preview. /// 指令标题和截断后的命令预览。
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    snippet.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: cs.onSurface,
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    commandPreview,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: cs.onSurface.withValues(alpha: 0.6),
                      fontSize: 13,
                      fontFamily: AppFonts.mono,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            PopupMenuButton<_SnippetAction>(
              tooltip: t('more_actions'),
              icon: Icon(
                Icons.more_vert,
                color: cs.onSurface.withValues(alpha: 0.46),
                size: 20,
              ),
              color: cs.surface,
              onSelected: (action) {
                switch (action) {
                  case _SnippetAction.edit:
                    onEdit();
                    break;
                  case _SnippetAction.delete:
                    onDelete();
                    break;
                }
              },
              itemBuilder: (context) => [
                PopupMenuItem(
                  value: _SnippetAction.edit,
                  child: Text(t('edit')),
                ),
                PopupMenuItem(
                  value: _SnippetAction.delete,
                  child: Text(t('delete'), style: TextStyle(color: cs.error)),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

enum _SnippetAction { edit, delete }
