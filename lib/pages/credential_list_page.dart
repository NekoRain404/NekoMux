import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/i18n/strings.dart';
import '../models/credential.dart';
import '../providers/providers.dart';
import '../widgets/app_drawer.dart';
import '../widgets/app_ui.dart';
import 'add_credential_page.dart';

/// Page that lists all saved credentials with add/edit/delete capabilities. /// 列出所有已保存凭据的页面，支持新增/编辑/删除。
class CredentialListPage extends ConsumerWidget {
  const CredentialListPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    final credsAsync = ref.watch(credentialListProvider);

    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      drawer: const AppDrawer(currentModule: 'credentials', isTopLevel: true),
      appBar: AppBar(
        leading: Builder(
          builder: (ctx) => IconButton(
            icon: Icon(Icons.menu, color: cs.onSurface),
            onPressed: () => Scaffold.of(ctx).openDrawer(),
          ),
        ),
        title: Text(
          t('credentials'),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          /// Add new credential button in the app bar. /// 导航栏中新增凭据的按钮。
          TextButton.icon(
            onPressed: () async {
              await Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const AddCredentialPage()),
              );
            },
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

      /// Async credential list: handles loading, error, empty, and data states. /// 异步凭据列表：处理加载、错误、空和数据四种状态。
      body: credsAsync.when(
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
        data: (creds) {
          if (creds.isEmpty) {
            /// Empty state: prompt user to add the first credential. /// 空状态：提示用户添加第一个凭据。
            return AppEmptyState(
              icon: Icons.vpn_key_outlined,
              title: t('empty_creds'),
              message: t('empty_creds_hint'),
              actionLabel: t('add_credential'),
              color: cs.secondary,
              onAction: () async {
                await Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const AddCredentialPage()),
                );
              },
            );
          }

          /// Credential list with swipe-to-delete and tap-to-edit. /// 凭据列表，支持滑动删除和点击编辑。
          return ListView.builder(
            padding: const EdgeInsets.symmetric(vertical: 8),
            itemCount: creds.length,
            itemBuilder: (context, index) {
              final cred = creds[index];
              return _CredentialTile(
                credential: cred,
                onTap: () async {
                  /// Navigate to edit page for the tapped credential. /// 导航到被点击凭据的编辑页面。
                  await Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) =>
                          AddCredentialPage(existingCredential: cred),
                    ),
                  );
                },
                onDelete: () => _confirmDelete(context, ref, cred),
              );
            },
          );
        },
      ),
    );
  }

  /// Shows a confirmation dialog before deleting a credential. /// 删除凭据前显示确认对话框。
  Future<void> _confirmDelete(
    BuildContext context,
    WidgetRef ref,
    Credential cred,
  ) async {
    final confirmed = await showAppConfirmDialog(
      context,
      title: t('confirm_delete'),
      message: t('confirm_delete_credential').replaceAll('{0}', cred.name),
      cancelLabel: t('cancel'),
      confirmLabel: t('delete'),
      destructive: true,
    );
    if (!confirmed) return;

    ref.read(credentialListProvider.notifier).deleteItem(cred.id);
  }
}

/// A single credential list tile showing name, username, auth type, and actions. /// 单个凭据列表项，显示名称、用户名、认证类型及操作。
class _CredentialTile extends StatelessWidget {
  final Credential credential;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  const _CredentialTile({
    required this.credential,
    required this.onTap,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isPassword = credential.authType == 0;

    /// Swipe-to-delete wrapper; confirmDismiss triggers the delete callback without actually dismissing. /// 滑动删除包装器；confirmDismiss 触发删除回调但不实际执行滑动消除。
    return Dismissible(
      key: Key(credential.id),
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
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          children: [
            /// Auth type icon: key for password, lock for private key. /// 认证类型图标：密码用钥匙，私钥用锁。
            AppIconBox(
              icon: isPassword ? Icons.password_outlined : Icons.key_outlined,
              color: isPassword ? cs.secondary : cs.primary,
            ),
            const SizedBox(width: 14),

            /// Credential name and username. /// 凭据名称和用户名。
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    credential.name,
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
                    credential.username,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: cs.onSurface.withValues(alpha: 0.6),
                      fontSize: 13,
                    ),
                  ),
                ],
              ),
            ),

            AppBadge(
              label: isPassword ? t('password_auth') : t('key_auth'),
              color: isPassword ? cs.secondary : cs.primary,
            ),
            const SizedBox(width: 4),
            PopupMenuButton<_CredentialAction>(
              tooltip: t('more_actions'),
              icon: Icon(
                Icons.more_vert,
                color: cs.onSurface.withValues(alpha: 0.46),
                size: 20,
              ),
              color: cs.surface,
              onSelected: (action) {
                switch (action) {
                  case _CredentialAction.edit:
                    onTap();
                    break;
                  case _CredentialAction.delete:
                    onDelete();
                    break;
                }
              },
              itemBuilder: (context) => [
                PopupMenuItem(
                  value: _CredentialAction.edit,
                  child: Text(t('edit')),
                ),
                PopupMenuItem(
                  value: _CredentialAction.delete,
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

enum _CredentialAction { edit, delete }
