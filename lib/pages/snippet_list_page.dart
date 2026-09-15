import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import '../core/i18n/strings.dart';
import '../models/snippet.dart';
import '../providers/providers.dart';
import '../widgets/app_drawer.dart';
import '../widgets/app_ui.dart';

/// Page that lists all saved command snippets with add/edit/delete capabilities. /// 列出所有已保存快捷指令的页面，支持新增/编辑/删除。
class SnippetListPage extends ConsumerStatefulWidget {
  const SnippetListPage({super.key});

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
                  /// Return the selected snippet to the caller (e.g., terminal page). /// 将选中的指令返回给调用方（如终端页面）。
                  Navigator.pop(context, snippet);
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

  /// Shows a dialog for adding or editing a snippet. /// 显示用于新增或编辑快捷指令的对话框。
  void _showSnippetDialog({Snippet? existing}) {
    final cs = Theme.of(context).colorScheme;
    final isEditing = existing != null;
    final titleController = TextEditingController(text: existing?.title ?? '');
    final commandController = TextEditingController(
      text: existing?.command ?? '',
    );
    final formKey = GlobalKey<FormState>();
    InputDecoration decoration(String label) {
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

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: cs.surface,
        title: Text(
          isEditing ? t('edit_snippet') : t('add_snippet'),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: cs.onSurface),
        ),
        content: SingleChildScrollView(
          child: Form(
            key: formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                /// Snippet title input. /// 指令名称输入。
                TextFormField(
                  controller: titleController,
                  style: TextStyle(color: cs.onSurface),
                  decoration: decoration(t('snippet_title')),
                  validator: (v) => (v == null || v.trim().isEmpty)
                      ? t('must_enter_snippet_title')
                      : null,
                ),
                const SizedBox(height: 16),

                /// Snippet command body input (multi-line). /// 指令内容输入（多行）。
                TextFormField(
                  controller: commandController,
                  style: TextStyle(color: cs.onSurface),
                  maxLines: 5,
                  decoration: decoration(t('snippet_command')),
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
            onPressed: () => Navigator.pop(ctx),
            child: Text(
              t('cancel'),
              style: TextStyle(color: cs.onSurface.withValues(alpha: 0.6)),
            ),
          ),
          TextButton(
            onPressed: () {
              if (!formKey.currentState!.validate()) return;

              /// Build the Snippet model; reuse existing ID when editing. /// 构建 Snippet 模型；编辑时复用已有 ID。
              final snippet = Snippet(
                id: existing?.id ?? const Uuid().v4(),
                title: titleController.text.trim(),
                command: commandController.text.trim(),
              );

              if (isEditing) {
                ref.read(snippetListProvider.notifier).updateItem(snippet);
              } else {
                ref.read(snippetListProvider.notifier).addItem(snippet);
              }

              Navigator.pop(ctx);
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(
                    isEditing ? t('snippet_updated') : t('snippet_added'),
                  ),
                  behavior: SnackBarBehavior.floating,
                ),
              );
            },
            child: Text(t('save'), style: TextStyle(color: cs.secondary)),
          ),
        ],
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

    ref.read(snippetListProvider.notifier).deleteItem(snippet.id);
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
                      fontFamily: 'monospace',
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
