import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/i18n/strings.dart';
import '../providers/providers.dart';
import '../services/known_hosts_store.dart';
import '../widgets/app_drawer.dart';
import '../widgets/app_ui.dart';

// What the app trusts, and the only place that trust can be taken back.
// 应用信任了什么，以及唯一能收回这份信任的地方。
//
// Every SSH connection verifies the host key against `tb_known_hosts`, and a
// *changed* key is the one warning that matters. Until this page existed the
// records behind that check were write-only: accepting a key — including
// accepting a changed key over the record it replaced — could not be reviewed
// or undone anywhere in the app, and `KnownHostsStore.forget` had no caller at
// all. A user who suspected they had accepted the wrong key had no remedy.
// 每次 SSH 连接都会用 `tb_known_hosts` 校验主机密钥，而「密钥已变更」是其中唯一
// 真正重要的警告。在本页出现之前，支撑该校验的记录是只写的：接受一个密钥——包括用
// 变更后的密钥覆盖它所替代的那条记录——在应用里既无法复查也无法撤销，
// `KnownHostsStore.forget` 甚至没有任何调用方。怀疑自己接受了错误密钥的用户无处补救。
//
// This page reads and forgets, and deliberately offers nothing else. There is
// no switch here to relax verification, and everything it does offer can only
// make the app ask *more* questions on the next connection, never fewer.
// 本页只做两件事：读取与删除，并且刻意不提供别的。这里没有放松校验的开关，而它所
// 提供的每个操作，都只会让应用在下次连接时问得**更多**，绝不会更少。

/// One accepted host key, in the shape the page needs it.
/// 一条已接受的主机密钥记录，以本页所需的形态呈现。
///
/// Built from a raw `tb_known_hosts` row by [KnownHostEntry.fromRow], which is
/// where a missing or unexpected column value is absorbed: the table is the
/// source of these strings and the page must not be able to throw on one.
/// 由 [KnownHostEntry.fromRow] 从 `tb_known_hosts` 的原始行构造，缺失或类型意外的列值
/// 都在那里被吸收：这些字符串来自数据表，本页绝不能因其中一条而抛异常。
class KnownHostEntry {
  /// `host:port` — the identity every connection is keyed by.
  /// `host:port`——每次连接所用的标识。
  final String host;

  /// Key algorithm ("ssh-ed25519", "ssh-rsa", ...), blank when the verifier had
  /// none to record. See `host_key_trust.dart`: the connection wrapper drops the
  /// type, so today every stored value is blank — which is why a blank one is
  /// treated as absent rather than rendered as if it were data.
  /// 密钥算法（"ssh-ed25519"、"ssh-rsa" 等）；校验方无从记录时为空串。见
  /// `host_key_trust.dart`：连接包装层丢掉了类型，因此目前存储值一律为空——
  /// 这正是空值要按「没有」处理、而不能当成数据渲染的原因。
  final String keyType;

  /// The fingerprint the user accepted, as stored.
  /// 用户所接受的那个指纹，原样存储。
  final String fingerprint;

  /// The stored `trusted_at`, kept exactly as the database holds it — an
  /// ISO-8601 UTC string written by `KnownHostsStore.trust`. Raw, because what
  /// it should look like on screen is [trustedAtLabel]'s business and a value
  /// that will not parse still has to reach the user somehow.
  /// 存储的 `trusted_at`，与数据库中的内容完全一致——即 `KnownHostsStore.trust`
  /// 写入的 ISO-8601 UTC 字符串。保持原始形态，是因为它在屏幕上该长什么样属于
  /// [trustedAtLabel] 的职责，而无法解析的值仍然需要以某种方式送到用户眼前。
  final String trustedAt;

  const KnownHostEntry({
    required this.host,
    required this.keyType,
    required this.fingerprint,
    required this.trustedAt,
  });

  /// Reads one database row, tolerating a missing or non-string column.
  /// 读取一行数据库记录，容忍列值缺失或类型不符。
  factory KnownHostEntry.fromRow(Map<String, Object?> row) {
    final host = row['host'];
    final keyType = row['key_type'];
    final fingerprint = row['fingerprint'];
    final trustedAt = row['trusted_at'];
    return KnownHostEntry(
      host: host is String ? host : '',
      keyType: keyType is String ? keyType.trim() : '',
      fingerprint: fingerprint is String ? fingerprint : '',
      trustedAt: trustedAt is String ? trustedAt : '',
    );
  }

  /// [trustedAt] rendered for a human: local time, or blank when there is none.
  /// [trustedAt] 的展示值：本地时间；没有值时为空串。
  ///
  /// Stored values are UTC (`DateTime.now().toUtc().toIso8601String()`), and
  /// the user compares them against what they were doing at the time, so the
  /// conversion happens here rather than being left to the reader.
  /// 存储值是 UTC（`DateTime.now().toUtc().toIso8601String()`），而用户要拿它与自己
  /// 当时在做的事对照，因此换算在这里完成，不留给读者。
  ///
  /// Nothing in this getter throws. An absent or blank value yields an empty
  /// string — the page then omits the line entirely, because an unknown date is
  /// not a date — and a value that will not parse is shown *as stored* instead
  /// of being hidden or replaced by a placeholder: the row exists, the page says
  /// what it holds, and an unreadable date must not read as "no date recorded".
  /// This string comes out of the database, and a bad one may not take the page
  /// down — nothing here parses in a way that can throw.
  /// 本 getter 不会抛出。缺失或空白的值返回空串——页面随即整行省略，因为未知的日期
  /// 不是日期；无法解析的值则**按原样**显示，而不是隐藏或用占位文字替代：这条记录
  /// 确实存在，页面就如实说出它存了什么，读不懂的日期不能读成「没有记录日期」。这些
  /// 字符串来自数据库，一条坏数据不允许把整页拖垮——这里的解析方式不会抛异常。
  ///
  /// One caveat about "will not parse": `DateTime.tryParse` *normalises*
  /// out-of-range components instead of rejecting them, so `2026-13-45` comes
  /// back as a real (if surprising) date and is rendered as one. Only values it
  /// truly cannot read reach the verbatim branch.
  /// 「无法解析」有一个前提：`DateTime.tryParse` 对越界字段是**归一化**而不是拒绝，
  /// 因此 `2026-13-45` 会变成一个真实（虽然出人意料）的日期并被当作日期渲染。只有它
  /// 确实读不出来的值才会走「按原样显示」这一支。
  String get trustedAtLabel {
    final raw = trustedAt.trim();
    if (raw.isEmpty) return '';
    final parsed = DateTime.tryParse(raw);
    if (parsed == null) return raw;
    final local = parsed.toLocal();
    // No `intl` in this project's dependencies, so the layout is written out.
    // Year first and 24-hour, which is unambiguous in every one of the eight
    // languages the app ships and sorts the way a log does.
    // 本项目没有 `intl` 依赖，因此这里手写格式。年在前、24 小时制，在应用支持的八种
    // 语言里都无歧义，且像日志一样可排序。
    return '${local.year}-${_two(local.month)}-${_two(local.day)} '
        '${_two(local.hour)}:${_two(local.minute)}';
  }
}

String _two(int value) => value.toString().padLeft(2, '0');

/// The accepted host keys, straight out of the known-hosts table.
/// 已接受的主机密钥，直接读自已知主机表。
///
/// A plain [FutureProvider] rather than a notifier: the page reads the table and
/// drops one row at a time, and `ref.invalidate` after a forget is the whole
/// refresh story. It lives here rather than in `providers/` so the page and the
/// only thing that refreshes it stay in one file — the records belong to
/// `KnownHostsStore`, and this provider adds nothing to it but the read.
/// 用普通的 [FutureProvider] 而不是通知器：本页只读取数据表并逐条删除，删除之后
/// `ref.invalidate` 就是全部的刷新逻辑。它放在本文件而非 `providers/`，是为了让页面
/// 与唯一刷新它的东西待在一起——记录属于 `KnownHostsStore`，本 provider 除了读取
/// 之外没有给它增加任何东西。
final knownHostsProvider = FutureProvider<List<KnownHostEntry>>((ref) async {
  final db = await ref.watch(databaseProvider.future);
  final rows = await KnownHostsStore(db).all();
  return rows.map(KnownHostEntry.fromRow).toList();
});

/// Lists every accepted host key, with a per-row way to forget it.
/// 列出全部已接受的主机密钥，并提供逐条删除的方式。
class KnownHostsPage extends ConsumerStatefulWidget {
  const KnownHostsPage({super.key});

  @override
  ConsumerState<KnownHostsPage> createState() => _KnownHostsPageState();
}

class _KnownHostsPageState extends ConsumerState<KnownHostsPage> {
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final entriesAsync = ref.watch(knownHostsProvider);

    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      // `isTopLevel: false`: this page is not one of the drawer's own entries,
      // so none of them is marked as the current module and the Settings entry
      // stays a working way back to where this page was opened from.
      // `isTopLevel: false`：本页不是抽屉自己的条目，因此其中没有哪一项被标为当前
      // 模块，而 Settings 那一项仍然是回到本页来源处的可用入口。
      drawer: const AppDrawer(currentModule: 'settings', isTopLevel: false),
      appBar: AppBar(
        leading: Builder(
          builder: (ctx) => IconButton(
            icon: Icon(Icons.menu, color: cs.onSurface),
            onPressed: () => Scaffold.of(ctx).openDrawer(),
          ),
        ),
        title: Text(
          t('known_hosts_title'),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          /// Re-read the table; a key accepted on another screen shows up here.
          /// 重新读取数据表；在别处接受的密钥会出现在这里。
          IconButton(
            tooltip: t('refresh'),
            onPressed: _reload,
            icon: Icon(Icons.refresh, color: cs.secondary, size: 20),
          ),
          const SizedBox(width: 4),
        ],
      ),

      /// Same three states the rest of the app renders for a table-backed list.
      /// 与其它由数据表支撑的列表相同的三种状态。
      ///
      /// `skipLoadingOnReload` is what keeps the error state reachable at all.
      /// Riverpod re-runs a failed provider on its own backoff, and every one of
      /// those re-runs puts it back into a *reloading* state — with the default
      /// (`false`) this branch would render the spinner again and the failure,
      /// with its retry button, would never be shown while the retries keep
      /// coming. An empty initial load has no previous state to skip, so it
      /// still shows the spinner.
      /// `skipLoadingOnReload` 是错误状态还能被看到的关键。Riverpod 会按自己的退避
      /// 策略自动重跑失败的 provider，而每一次重跑都会让它回到**重新加载**状态——在默认
      /// 值（`false`）下，这里会重新渲染转圈，只要重试还在继续，失败与它的重试按钮就永远
      /// 不会出现。首次加载没有可跳过的先前状态，因此仍然显示转圈。
      body: entriesAsync.when(
        skipLoadingOnReload: true,
        loading: () =>
            Center(child: CircularProgressIndicator(color: cs.primary)),
        error: (e, _) => _LoadFailure(detail: e.toString(), onRetry: _reload),
        data: (entries) {
          if (entries.isEmpty) {
            /// Nothing accepted yet. The hint is the same text the list view
            /// shows above its rows, so what forgetting does is explained in
            /// both states, not only in the confirmation dialog.
            /// 尚未接受任何密钥。提示文字与列表视图上方那条相同，因此「删除意味着
            /// 什么」在两种状态下都会说明，而不只是出现在确认对话框里。
            return AppEmptyState(
              icon: Icons.verified_user_outlined,
              title: t('known_hosts_empty'),
              message: t('known_hosts_hint'),
              color: cs.secondary,
            );
          }

          return ListView(
            padding: const EdgeInsets.symmetric(vertical: 8),
            children: [
              const _HintBanner(),
              for (final entry in entries)
                _KnownHostTile(
                  entry: entry,
                  onForget: () => _confirmForget(entry),
                ),
              const SizedBox(height: 24),
            ],
          );
        },
      ),
    );
  }

  /// Re-reads the table through the database, for both the refresh action and
  /// the retry button.
  /// 经由数据库重新读取数据表，供刷新操作与重试按钮共用。
  ///
  /// The database is invalidated as well as this page's own provider. A database
  /// that failed to open leaves `databaseProvider` retrying on its own backoff,
  /// and re-reading only the known-hosts table would wait on that same attempt
  /// instead of starting a new one — so the refresh button, which stays
  /// reachable while the page is spinning, is what forces an immediate fresh
  /// try. When the table is readable and only this page's read failed, the same
  /// invalidation simply re-runs it. `AppDatabase` caches its handle, so neither
  /// case re-opens a database that is already open.
  /// 除了本页自己的 provider，数据库本身也一并失效。打不开的数据库会让
  /// `databaseProvider` 按自己的退避策略不断重试，此时只重新读取已知主机表只会等待同
  /// 一次尝试，而不会发起新的尝试——因此，在页面转圈时仍然可点的刷新按钮，才是立刻
  /// 重新尝试的手段。若数据表本可读取、只是本页这次读取失败，同一次失效则只是重跑它。
  /// `AppDatabase` 会缓存其句柄，因此两种情况下都不会重新打开已经打开的数据库。
  ///
  /// The reads this page performs are read-only; nothing here can disturb the
  /// records themselves.
  /// 本页执行的读取都是只读的，这里没有任何操作会动到记录本身。
  void _reload() {
    ref.invalidate(databaseProvider);
    ref.invalidate(knownHostsProvider);
  }

  /// Asks before forgetting [entry], then drops its record.
  /// 删除 [entry] 的记录之前先询问，然后再执行。
  ///
  /// The confirmation carries the consequence, not just the question: the
  /// record goes away for good and the next connection to this host asks again.
  /// That is the point of the action — it is how a user who thinks they accepted
  /// the wrong key gets a fresh prompt — so nothing here offers to put the record
  /// back, and the dialog says so.
  /// 确认框说的是后果而不只是问题：记录会永久消失，下次连接该主机将重新询问。这正是
  /// 该操作的意义——怀疑自己接受了错误密钥的用户借此拿到一次全新的询问——因此这里
  /// 不提供恢复记录的选项，对话框也如实说明。
  ///
  /// The delete is awaited and its failure is reported. A `forget` that throws
  /// while the row stays on screen, with no message anywhere, is exactly the
  /// state this page exists to remove — the user would believe the key was
  /// forgotten when the next connection would still pass silently.
  /// 删除是 await 的，失败会被报告。一次抛出的 `forget` 若让那一行继续留在屏幕上、
  /// 且没有任何提示，恰恰是本页要消除的状态——用户会以为密钥已被删除，而下一次连接
  /// 仍会静默通过。
  Future<void> _confirmForget(KnownHostEntry entry) async {
    final confirmed = await showAppConfirmDialog(
      context,
      title: t('known_hosts_forget'),
      message: t('known_hosts_forget_confirm').replaceAll('{0}', entry.host),
      cancelLabel: t('cancel'),
      confirmLabel: t('delete'),
      destructive: true,
    );
    if (!confirmed || !mounted) return;

    try {
      final db = await ref.read(databaseProvider.future);
      await KnownHostsStore(db).forget(entry.host);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('${t('error')}: $e'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } finally {
      // Re-queried whether or not the delete succeeded, the same shape the
      // notifiers use: what the list shows is then always what the table holds.
      // A failed delete leaves the row on screen — the truthful result — and no
      // path here can leave the page describing a table it disagrees with.
      // 无论删除是否成功都重新查询，与各通知器同形：列表显示的永远是数据表中实际存在
      // 的内容。删除失败时那一行仍在屏幕上——这是如实的结果——且本页没有任何一条路径
      // 会让界面与数据表不一致。
      if (mounted) ref.invalidate(knownHostsProvider);
    }
  }
}

/// The hint that explains what forgetting does, above the rows it applies to.
/// 说明「删除记录意味着什么」的提示，位于它所说明的那些行之上。
///
/// It sits before the first row so the explanation is read while the list is
/// being scanned, not only after the user has already committed to the action
/// by opening the confirmation.
/// 它位于第一行之前，用户浏览列表时就会读到这段说明，而不是等到他已经打开确认框、
/// 决定要动手之后才看到。
class _HintBanner extends StatelessWidget {
  const _HintBanner();

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.info_outline,
            size: 14,
            color: cs.onSurface.withValues(alpha: 0.42),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              t('known_hosts_hint'),
              style: TextStyle(
                color: cs.onSurface.withValues(alpha: 0.56),
                fontSize: 12,
                height: 1.35,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// One record: which host, which key, and since when it has been trusted.
/// 单条记录：哪台主机、哪个密钥、自何时起受信。
class _KnownHostTile extends StatelessWidget {
  final KnownHostEntry entry;
  final VoidCallback onForget;

  const _KnownHostTile({required this.entry, required this.onForget});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final trustedAt = entry.trustedAtLabel;

    return AppCard(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              AppIconBox(
                icon: Icons.verified_user_outlined,
                color: cs.secondary,
                size: 34,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  entry.host,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: cs.onSurface,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              /// The action keeps its word: a security decision the user has to
              /// reverse should read as what it does, not as an icon to decode.
              /// 这个操作保留文字：用户需要撤销的安全决定，应当写明它做什么，而不是
              /// 一个需要猜测的图标。
              TextButton(
                onPressed: onForget,
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  minimumSize: const Size(0, 32),
                  tapTargetSize: MaterialTapTargetSize.padded,
                ),
                child: Text(
                  t('known_hosts_forget'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: cs.error, fontSize: 12),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),

          /// Only when there is a type to show. `host_key_trust.dart` currently
          /// stores an empty one, and rendering that would put an empty chip on
          /// every row — an absence dressed up as a value.
          /// 只有在确实有类型时才显示。`host_key_trust.dart` 目前存储的是空串，
          /// 若照渲染，每一行都会挂一个空标签——把「没有」装扮成一个值。
          if (entry.keyType.isNotEmpty) ...[
            AppBadge(label: entry.keyType, color: cs.primary),
            const SizedBox(height: 8),
          ],

          /// Selectable, monospaced: this string is meant to be compared against
          /// `ssh-keyscan` output, which means copying it out of the app intact.
          /// 可选中、等宽：这个字符串是用来与 `ssh-keyscan` 的输出比对的，也就意味着
          /// 它必须能被原样复制出去。
          SelectableText(
            entry.fingerprint,
            maxLines: 2,
            style: TextStyle(
              color: cs.primary,
              fontSize: 12,
              fontFamily: 'monospace',
              height: 1.35,
            ),
          ),

          /// Omitted when the row carries no usable date — see
          /// [KnownHostEntry.trustedAtLabel] for why an unreadable one is shown
          /// verbatim.
          /// 行内没有可用日期时整行省略——无法解析的日期为何按原文显示，见
          /// [KnownHostEntry.trustedAtLabel]。
          if (trustedAt.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              '${t('known_hosts_trusted_at')} · $trustedAt',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: cs.onSurface.withValues(alpha: 0.48),
                fontSize: 11,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// The page could not read the table; says so and offers to try again.
/// 页面无法读取数据表；如实说明并提供重试。
class _LoadFailure extends StatelessWidget {
  final String detail;
  final VoidCallback onRetry;

  const _LoadFailure({required this.detail, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              t('load_failed_msg').replaceAll('{0}', detail),
              textAlign: TextAlign.center,
              maxLines: 6,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: cs.onSurface.withValues(alpha: 0.6)),
            ),
            const SizedBox(height: 16),
            TextButton.icon(
              onPressed: onRetry,
              icon: Icon(Icons.refresh, color: cs.secondary, size: 18),
              label: Text(
                t('retry'),
                style: TextStyle(color: cs.secondary),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
