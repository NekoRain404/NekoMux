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
        // With a retry, like every other table-backed screen. This one was
        // missed when the others got theirs, and it is the screen a user is on
        // when the credential store itself is what failed — the one failure that
        // most needs a second attempt.
        error: (e, _) => AppLoadFailure(
          detail: t('load_failed_msg').replaceAll('{0}', '$e'),
          onRetry: () => ref.invalidate(credentialListProvider),
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

  /// Shows a confirmation dialog before deleting a credential.
  /// 删除凭据前显示确认对话框。
  ///
  /// The number of hosts that reference the credential is part of the warning.
  /// The database does not enforce the declared foreign key, so deleting a
  /// credential that is in use leaves those hosts behind holding a dangling
  /// `credential_id`: they can never connect again, and nothing on screen
  /// explains why. Nothing is cascaded and no constraint is switched on here —
  /// the user is simply told what the deletion will cost before it happens.
  /// 引用该凭据的主机数量也是警告的一部分。数据库并不强制声明的外键，因此删除正在
  /// 使用的凭据会让这些主机留下悬空的 `credential_id`：它们再也无法连接，而界面上
  /// 没有任何解释。这里既不做级联删除，也不启用约束——只是在删除发生前告知用户
  /// 代价。
  Future<void> _confirmDelete(
    BuildContext context,
    WidgetRef ref,
    Credential cred,
  ) async {
    final affectedHosts = await _countHostsUsing(ref, cred.id);
    if (!context.mounted) return;

    final confirmed = await showAppConfirmDialog(
      context,
      title: t('confirm_delete'),
      message: credentialDeleteConfirmation(cred.name, affectedHosts),
      cancelLabel: t('cancel'),
      confirmLabel: t('delete'),
      destructive: true,
    );
    if (!confirmed) return;

    // Awaited, so a failed delete is reported instead of leaving the row on
    // screen with no explanation.
    // 必须 await：删除失败时要给出提示，而不是让那一行留在界面上且毫无说明。
    final notifier = ref.read(credentialListProvider.notifier);
    try {
      await notifier.deleteItem(cred.id);
    } catch (e) {
      // This page is stateless, so there is no `mounted` to consult — the
      // messenger is looked up from the context that was checked above.
      // 本页是无状态的，没有 `mounted` 可用——信使取自上面已校验过的 context。
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('${t('load_failed_msg')}: $e'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
  }

  /// Counts the saved hosts whose `credential_id` is [credentialId].
  /// 统计 `credential_id` 为 [credentialId] 的已保存主机数量。
  ///
  /// The host list is awaited rather than merely read: on a cold start the page
  /// can be the first thing the app shows, and a synchronous read would find
  /// the provider still unloaded and silently report zero. If the list cannot
  /// be read at all the count falls back to zero — an unreadable host table
  /// must not be able to block a deletion the user has decided on.
  /// 这里等待主机列表，而不是仅仅读取：冷启动时本页面可能是应用显示的第一个界面，
  /// 同步读取会得到尚未加载的提供者并默默报 0。若列表完全无法读取，计数回退为 0
  /// ——不能因为主机表读不出来就阻止用户已经决定要做的删除。
  Future<int> _countHostsUsing(WidgetRef ref, String credentialId) async {
    try {
      final hosts = await ref.read(hostListProvider.future);
      return hosts.where((host) => host.credentialId == credentialId).length;
    } catch (_) {
      return 0;
    }
  }
}

/// Confirmation text shown before the credential named [credentialName] is
/// deleted, naming how many hosts reference it.
/// 删除名为 [credentialName] 的凭据之前显示的确认文本，并说明有多少台主机引用它。
///
/// The count only appears when there is something to warn about, so the common
/// case — a credential no host points at — keeps the plain confirmation.
/// English would rather read "3 hosts use this credential", but the translation
/// table has no key of that shape and `lib/core/i18n/**` is not this page's to
/// edit; `<hosts label>: <count>` is composed from `my_hosts`, which exists in
/// all eight languages. A dedicated key such as
/// `credential_used_by_hosts: '{0} hosts use this credential'` is the change
/// that would let this read as a sentence.
/// 仅在有需要警告的内容时才出现计数，因此常见情形——没有主机引用该凭据——仍是
/// 原来的确认文本。英文更希望读作 "3 hosts use this credential"，但翻译表中没有
/// 这种形状的键，而 `lib/core/i18n/**` 不归本页面修改；`<主机标签>: <数量>` 由
/// `my_hosts` 拼成，八种语言中都有这个键。若能新增
/// `credential_used_by_hosts: '{0} hosts use this credential'` 这样的专用键，
/// 这句话就能读成一个完整的句子。
String credentialDeleteConfirmation(String credentialName, int affectedHosts) {
  final base = t('confirm_delete_credential').replaceAll('{0}', credentialName);
  if (affectedHosts <= 0) return base;
  // A whole sentence, not a label plus a number: this line is the last thing
  // between the user and breaking N hosts, and `credential_used_by_hosts` says
  // what actually happens to them.
  // 一句完整的话，而不是「标签 + 数字」：这一行是用户与「弄坏 N 台主机」之间的最后
  // 一道提示，而 `credential_used_by_hosts` 说明了它们究竟会怎样。
  return '$base\n${t('credential_used_by_hosts').replaceAll('{0}', '$affectedHosts')}';
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
