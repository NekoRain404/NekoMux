import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/i18n/strings.dart';
import '../models/credential.dart';
import '../models/file_item.dart';
import '../models/host.dart';
import '../providers/providers.dart';
import '../providers/ssh_provider.dart';
import '../services/host_key_trust.dart';
import '../services/sftp_service.dart';
import '../widgets/host_key_prompt.dart';
import 'file_preview_page.dart';
import 'sftp/directory_load_state.dart';
import 'sftp/file_selection.dart';
import 'sftp/sftp_bars.dart';
import 'sftp/sftp_dialogs.dart';
import 'sftp/sftp_error_text.dart';
import 'sftp/sftp_file_list.dart';
import 'sftp/sftp_path.dart';

/// SFTP file manager with directory browsing and file operations.
/// 具备目录浏览与文件操作能力的 SFTP 文件管理器。
///
/// The page owns the connection and the operations; the path bar, list, bars and
/// dialogs it composes are presentation-only, and the rules that decide which
/// directory is on screen live in `sftp/` as pure, testable units.
/// 本页面持有连接并执行操作；它组合的路径栏、列表、底栏与对话框都只负责展示，
/// 而「屏幕上显示的是哪个目录」这类规则以可测试的纯逻辑放在 `sftp/` 下。
class SftpPage extends ConsumerStatefulWidget {
  final Host host;
  final Credential? credential;

  const SftpPage({super.key, required this.host, this.credential});

  @override
  ConsumerState<SftpPage> createState() => _SftpPageState();
}

class _SftpPageState extends ConsumerState<SftpPage> {
  SftpService? _sftpService;
  bool _isConnecting = true;
  String? _errorMessage;
  List<FileItem> _files = [];

  /// Directory bookkeeping: which path the bar shows, which one the entries in
  /// [_files] belong to, and which in-flight listing may still publish a result.
  /// 目录状态：路径栏显示哪个路径、[_files] 中的条目属于哪个路径，以及哪个在途列举
  /// 还可以提交结果。
  final DirectoryLoadState _directory = DirectoryLoadState('/');

  /// Ticked entries; emptied whenever the listing changes directory.
  /// 已勾选的条目；列表切换目录时清空。
  final FileSelection _selection = FileSelection();

  /// Whether a listing has been committed at least once since the page opened.
  /// 页面打开后是否至少成功提交过一次列举。
  ///
  /// Once it has, a later failure belongs *on top of* that listing (a snackbar)
  /// rather than replacing it with the full-page error, which would also throw
  /// away a directory the user can still work in.
  /// 一旦提交过，后续失败应当**叠加**在该列表之上（用浮层提示），而不是用整页错误
  /// 取代它——那会连带丢掉用户仍然可以操作的目录。
  bool _hasListingOnScreen = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _resolveAndConnect());
  }

  @override
  void dispose() {
    _sftpService?.disconnect();
    super.dispose();
  }

  /// Resolves the credential and the host-key trust record, then connects.
  /// 解析凭据与主机密钥信任记录，然后建立连接。
  Future<void> _resolveAndConnect() async {
    var cred = widget.credential;
    try {
      if (cred == null) {
        final allCreds = await ref.read(credentialListProvider.future);
        if (!mounted) return;
        cred = allCreds
            .where((c) => c.id == widget.host.credentialId)
            .firstOrNull;
      }
      if (cred == null) {
        setState(() {
          _isConnecting = false;
          _errorMessage = t('credential_not_found');
        });
        return;
      }

      // The accepted keys live in SQLite, so the verifier needs the database.
      // The in-memory cache this replaced could not tell a changed key from a
      // first contact and forgot every accepted key on restart, which is the
      // same as not verifying at all.
      // 已接受的密钥存放在 SQLite，因此验证器需要数据库实例。它取代的内存缓存既无法
      // 区分「密钥变更」与「首次连接」，又会在每次重启后忘掉所有已接受的密钥——
      // 那等于没有验证。
      final db = await ref.read(databaseProvider.future);
      if (!mounted) return;

      _sftpService = SftpService(
        host: widget.host,
        credential: cred,
        // Settings → connect timeout, honoured in full — deliberately not
        // clamped the way the home page's background probe clamps it. The two
        // cases are opposites: a probe runs against every host on every round
        // with nobody watching, while this page opens exactly the one session
        // the user asked for by tapping a host. Clamping here would recreate the
        // defect being fixed — a user on a slow link who chose 30s would still
        // be cut off at 4s — and the cost of obeying it is paid once per
        // attempt, not per tick: a connect happens on open and on retry, both
        // user-initiated.
        // 设置 → 连接超时，在这里被完整遵循——刻意**不**像主页后台探测那样钳制。两者
        // 恰好相反：探测每轮对每台主机执行且无人注视，而本页只打开用户点击主机所请求的
        // 那一条会话。在此钳制会重新造出正在修复的缺陷——慢链路上的用户设了 30 秒，却
        // 依然在 4 秒被切断——而遵循它的代价只按次支付，不按 tick 重复：连接只发生在
        // 打开与重试时，全部由用户发起。
        connectTimeout: ref.read(connectTimeoutProvider),
        onHostKeyVerify: buildHostKeyVerifier(
          db: db,
          address: widget.host.ipAddress,
          port: widget.host.port,
          onPrompt: (fingerprint, verdict) async {
            // Raised from inside connect(), so by the time a key needs judging
            // the page may already be gone.
            // 该提示由 connect() 内部触发，等到需要判定密钥时页面可能已销毁。
            if (!mounted) return false;
            return showHostKeyPrompt(
              context,
              fingerprint: fingerprint,
              verdict: verdict,
            );
          },
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isConnecting = false;
        // Nothing here reached the service, so there is no code to map — the
        // failure is reported as a failed connection with the raw detail, which
        // is what an unexpected exception can honestly offer.
        // 这里的失败根本没有到达 service，因此没有编码可映射——按连接失败上报并附带
        // 原始细节，这也是一份意外异常能诚实提供的信息。
        _errorMessage = sftpFailureText(SftpFailure.connect, '$e');
      });
      return;
    }
    _connect();
  }

  /// Opens the connection and loads the root directory.
  /// 建立连接并载入根目录。
  Future<void> _connect() async {
    setState(() {
      _isConnecting = true;
      _errorMessage = null;
    });
    try {
      await _sftpService!.connect();
      if (!mounted) {
        // The page was popped while the session was opening. dispose() has
        // already run — and ran before the service finished connecting, so it
        // had nothing to close. Closing here is what keeps an abandoned SFTP
        // page from leaving an authenticated session on the server until the
        // app exits.
        // 连接建立期间页面被返回销毁。dispose() 已经执行过，且执行时服务尚未连接完成，
        // 因此它没有东西可关。在这里关闭，才能避免一个被放弃的 SFTP 页面在服务器上
        // 留下已认证会话直到 App 结束。
        await _sftpService?.disconnect();
        return;
      }
      await _loadDirectory('/');
    } on SftpException catch (e) {
      if (!mounted) return;
      setState(() => _errorMessage = sftpErrorText(e));
    } catch (e) {
      if (!mounted) return;
      setState(
        () => _errorMessage = sftpFailureText(SftpFailure.connect, '$e'),
      );
    } finally {
      // Guarded on purpose: connect() is awaited while the user can still press
      // back, and an unguarded setState here throws on every such exit.
      // 有意加守卫：connect() 等待期间用户仍可返回，未加守卫的 setState 会在这种
      // 情况下抛异常。
      if (mounted) setState(() => _isConnecting = false);
    }
  }

  /// Retries from the error page: drop the old session, then connect again.
  /// 从错误页重试：断开旧会话后重新连接。
  Future<void> _retry() async {
    await _sftpService?.disconnect();
    if (!mounted) return;
    await _resolveAndConnect();
  }

  /// The directory the page is showing, in the path bar and for building paths.
  /// 页面正在显示的目录，用于路径栏，也用于拼接子路径。
  String get _currentDir => _directory.requestedPath;

  /// Path bar segments for [_currentDir].
  /// [_currentDir] 对应的路径栏片段。
  List<SftpCrumb> get _crumbs => sftpBreadcrumbs(_currentDir);

  /// Loads [path] into the list.
  /// 将 [path] 载入列表。
  ///
  /// Only the newest request may commit, so an earlier listing that finishes
  /// last cannot overwrite it or clear the spinner while the newer load is still
  /// running — the state that used to leave the path bar and the entries
  /// describing two different directories.
  /// 只有最新的请求可以提交结果，因此较早发出、最后才返回的列举既不能覆盖它，也不能
  /// 在更新的加载仍在进行时清掉转圈——正是那个状态让路径栏与列表条目指向两个不同的目录。
  Future<void> _loadDirectory(String path) async {
    final request = _directory.begin(path);
    final changesDirectory = path != _directory.shownPath;

    setState(() {
      _errorMessage = null;
      // A batch action must never reach a path the user can no longer see, so
      // changing directory drops the selection. A plain refresh keeps it.
      // 批量操作绝不能触及用户已经看不到的路径，因此切换目录会清空选择；单纯刷新则保留。
      if (changesDirectory) _selection.clear();
    });

    try {
      final entries = await _sftpService!.listDirectory(path);
      if (!mounted || !_directory.commitLoaded(request)) return;
      entries.sort(_compareEntries);
      setState(() {
        _files = entries;
        _hasListingOnScreen = true;
      });
    } on SftpException catch (e) {
      _handleLoadFailure(request, sftpErrorText(e));
    } catch (e) {
      _handleLoadFailure(request, sftpFailureText(SftpFailure.list, '$e'));
    }
  }

  /// Reports a failed listing without letting it desync the path bar.
  /// 报告失败的列举，同时不让路径栏失去同步。
  void _handleLoadFailure(DirectoryRequest request, String message) {
    // A stale response is dropped whole: it must not clear the spinner, raise an
    // error, or move the path bar for a load the user has already left.
    // 过期响应被整体丢弃：它不能为一次用户已离开的加载清掉转圈、弹出错误或移动路径栏。
    if (!mounted || !_directory.isCurrent(request)) return;

    final canKeepListing = _hasListingOnScreen;
    setState(() {
      // Puts the path back to the directory that is still listed, so the path
      // bar never names a directory whose contents never arrived — which is what
      // made create/rename write into a directory the user was not looking at.
      // 把路径放回仍有列表在显示的目录，路径栏因此绝不会声称自己在一个内容从未到达的
      // 目录里——正是这一点曾让新建/重命名写进用户没在看的地方。
      _directory.commitFailed(request);
      // The full-page error is the right report only while there is nothing to
      // show; with a listing on screen it would be swallowed entirely.
      // 只有确实无内容可显示时，整页错误才是恰当的报告方式；列表还在屏幕上时它会被
      // 完全吞掉。
      if (!canKeepListing) _errorMessage = message;
    });
    if (canKeepListing) _showSnack(message, isError: true);
  }

  /// Sort order for a freshly listed directory: folders first, then by name.
  /// 新列举目录的排序：目录在前，其余按名称。
  int _compareEntries(FileItem a, FileItem b) {
    if (a.isDirectory && !b.isDirectory) return -1;
    if (!a.isDirectory && b.isDirectory) return 1;
    return a.name.compareTo(b.name);
  }

  /// Opens the directory a row points at.
  /// 打开某一行指向的目录。
  void _navigateToDirectory(FileItem file) => _loadDirectory(file.path);

  /// Jumps to the tapped path bar segment; the last one is the current directory.
  /// 跳转到被点击的路径栏片段；最后一个是当前目录。
  void _navigateToCrumb(int index) {
    final crumbs = _crumbs;
    if (index < 0 || index >= crumbs.length - 1) return;
    _loadDirectory(crumbs[index].path);
  }

  /// Handles a tap on a file row: preview for text, actions for anything else.
  /// 处理文件行的点击：文本文件预览，其余弹出操作面板。
  Future<void> _openEntry(FileItem file) async {
    if (isSftpTextFile(file.name)) {
      await _openFile(file);
    } else {
      await _showFileActions(file);
    }
  }

  /// Opens a text file in the preview page.
  /// 用预览页面打开文本文件。
  Future<void> _openFile(FileItem file) async {
    // Refuse before reading, not after. The preview page has its own size
    // guard, but it only ever sees content that has already been pulled into
    // memory: `readFile` buffers every chunk and the whole thing is decoded to
    // a String first, so the out-of-memory happens before that guard can run.
    // The directory listing already told us the size, so nothing needs to be
    // fetched to make this decision.
    // 在读之前就拒绝，而不是读完之后。预览页自己也有大小上限，但它看到的永远是
    // 已经被读进内存的内容：`readFile` 会把每个分块都缓存下来，随后整份被解码成
    // String，因此 OOM 发生在那个上限来得及生效之前。目录列表已经告诉我们大小，
    // 做这个判断不需要拉取任何数据。
    //
    // Compared in bytes against a limit expressed in code units: for the ASCII
    // logs and configs that matter, bytes >= code units, so this errs towards
    // refusing a file that would in fact have fit — the safe direction.
    // 用字节数与以「码元」表示的限额比较：对本场景真正要紧的 ASCII 日志与配置而言，
    // 字节数 ≥ 码元数，所以这只会倾向于拒绝一个其实装得下的文件——是安全的方向。
    if (file.size > FilePreviewPage.maxContentLength) {
      _showSnack(t('file_too_large'), isError: true);
      return;
    }
    try {
      final bytes = await _sftpService!.readFile(file.path);
      if (!mounted) return;
      // Remote "text" files are routinely GBK or Latin-1 on a Chinese-locale
      // server. Strict decoding threw FormatException, which nothing caught and
      // nobody awaited: the tap simply did nothing. allowMalformed keeps those
      // files readable, and the clauses below cover any other decode failure.
      // 中文环境下服务器上的「文本」文件常为 GBK 或 Latin-1。严格解码会抛
      // FormatException，而此前无人捕获、也无人等待该 Future：点击毫无反应。
      // allowMalformed 让这些文件照常可读，下面的分支兜住其余解码失败。
      final content = utf8.decode(bytes, allowMalformed: true);

      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => FilePreviewPage(
            filename: file.name,
            content: content,
            onSave: (newContent) async {
              try {
                await _sftpService!.writeFile(
                  file.path,
                  Uint8List.fromList(utf8.encode(newContent)),
                );
                if (mounted) _showSnack(t('file_saved'));
              } on SftpException catch (e) {
                if (mounted) _showSnack(sftpErrorText(e), isError: true);
              }
            },
          ),
        ),
      );
    } on SftpException catch (e) {
      if (mounted) _showSnack(sftpErrorText(e), isError: true);
    } on FormatException catch (_) {
      if (mounted) _showSnack(_loadFailedMessage(file.name), isError: true);
    } catch (e) {
      if (mounted) _showSnack(_loadFailedMessage('$e'), isError: true);
    }
  }

  /// "Load failed: …" for a file that could not be read or decoded.
  /// 无法读取或解码文件时的「加载失败: …」提示。
  String _loadFailedMessage(String detail) =>
      t('load_failed_msg').replaceAll('{0}', detail);

  /// Per-file actions sheet, then whatever was chosen.
  /// 单文件操作面板，以及随后执行所选操作。
  Future<void> _showFileActions(FileItem file) async {
    final action = await showSftpFileActions(
      context,
      file,
      canOpenFile: isSftpTextFile(file.name),
    );
    if (action == null || !mounted) return;

    switch (action) {
      case SftpFileAction.open:
        if (isSftpTextFile(file.name)) {
          await _openFile(file);
        } else {
          _showSnack(t('binary_file_hint'));
        }
      case SftpFileAction.rename:
        await _showRenameDialog(file);
      case SftpFileAction.select:
        setState(() => _selection.begin(file.path));
      case SftpFileAction.delete:
        await _confirmDeleteFile(file);
    }
  }

  /// Renames [file] to the name the user types.
  /// 将 [file] 重命名为用户输入的名称。
  Future<void> _showRenameDialog(FileItem file) async {
    final name = await showSftpNameDialog(
      context,
      title: t('rename'),
      hint: file.name,
      initial: file.name,
      confirmLabel: t('confirm'),
    );
    if (name == null || !mounted) return;

    try {
      await _sftpService!.rename(file.path, sftpChildPath(_currentDir, name));
      if (!mounted) return;
      await _loadDirectory(_currentDir);
      if (mounted) _showSnack(t('file_renamed'));
    } on SftpException catch (e) {
      if (mounted) _showSnack(sftpErrorText(e), isError: true);
    }
  }

  /// Deletes one entry after confirming.
  /// 确认后删除单个条目。
  Future<void> _confirmDeleteFile(FileItem file) async {
    final confirmed = await confirmSftpDelete(context, file.name);
    if (!confirmed || !mounted) return;

    try {
      await _sftpService!.deleteFile(file.path);
      if (!mounted) return;
      await _loadDirectory(_currentDir);
      if (mounted) _showSnack(t('file_deleted'));
    } on SftpException catch (e) {
      if (mounted) _showSnack(sftpErrorText(e), isError: true);
    }
  }

  /// The "new file / new folder" flow: choose a kind, name it, create it.
  /// 「新建文件 / 新建文件夹」流程：选择类型、命名、创建。
  Future<void> _showNewEntryDialog() async {
    final kind = await showSftpNewEntryChooser(context);
    if (kind == null || !mounted) return;

    final isFolder = kind == SftpNewEntryKind.folder;
    final name = await showSftpNameDialog(
      context,
      title: isFolder ? t('new_folder') : t('new_file_item'),
      hint: isFolder ? t('input_foldername') : t('input_filename'),
      confirmLabel: t('create'),
    );
    if (name == null || !mounted) return;

    final path = sftpChildPath(_currentDir, name);
    try {
      if (isFolder) {
        await _sftpService!.createDirectory(path);
      } else {
        await _sftpService!.writeFile(path, Uint8List(0));
      }
      if (!mounted) return;
      await _loadDirectory(_currentDir);
      if (mounted) {
        _showSnack(isFolder ? t('folder_created') : t('file_created'));
      }
    } on SftpException catch (e) {
      if (mounted) _showSnack(sftpErrorText(e), isError: true);
    }
  }

  /// Deletes every selected path, then reports what actually happened.
  /// 删除全部已选路径，然后如实报告结果。
  Future<void> _showBatchDeleteConfirm() async {
    final paths = _selection.paths.toList();
    if (paths.isEmpty) return;

    final confirmed = await confirmSftpBatchDelete(context, paths);
    if (!confirmed || !mounted) return;

    setState(_selection.clear);

    var failed = 0;
    for (final path in paths) {
      try {
        await _sftpService!.deleteFile(path);
      } on SftpException catch (e) {
        failed++;
        if (mounted) _showSnack(sftpErrorText(e), isError: true);
      } catch (e) {
        failed++;
        // Not an SftpException, so there is no code to map; report it as a
        // failed delete with its detail rather than showing a raw exception.
        // 不是 SftpException，因此没有编码可映射；按删除失败上报并附带细节，
        // 而不是把原始异常直接显示出来。
        if (mounted) {
          _showSnack(sftpFailureText(SftpFailure.delete, '$e'), isError: true);
        }
      }
    }

    if (!mounted) return;
    await _loadDirectory(_currentDir);
    if (!mounted) return;

    // A blanket "deleted" used to be shown even when every single delete had
    // failed, so the last thing the user read was a success message. Report the
    // failures by count instead; each reason was already shown per file.
    // 即使每一个删除都失败，此前也无条件显示「已删除」，让成功提示成为用户最后读到的
    // 一句话。这里改为按数量报告失败；每条失败原因已在上面逐个提示过。
    if (failed == 0) {
      _showSnack(t('file_deleted'));
    } else {
      _showSnack(
        t('service_action_failed')
            .replaceAll('{0}', t('batch_delete'))
            .replaceAll('{1}', '$failed/${paths.length}'),
        isError: true,
      );
    }
  }

  void _enterSelectionMode(String path) =>
      setState(() => _selection.begin(path));

  void _toggleSelection(String path) => setState(() => _selection.toggle(path));

  void _exitSelectionMode() => setState(_selection.clear);

  void _showSnack(String message, {bool isError = false}) {
    final cs = Theme.of(context).colorScheme;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isError ? cs.error : cs.primary,
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.all(16),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(
        backgroundColor: cs.surface,
        leading: IconButton(
          icon: Icon(
            Icons.arrow_back,
            color: cs.onSurface.withValues(alpha: 0.7),
          ),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text(
          t('file_manager_title'),
          style: TextStyle(color: cs.onSurface),
        ),
        actions: [
          if (!_isConnecting)
            IconButton(
              icon: Icon(
                Icons.refresh,
                color: cs.onSurface.withValues(alpha: 0.72),
                size: 22,
              ),
              tooltip: t('refresh'),
              onPressed: _directory.isLoading
                  ? null
                  : () => _loadDirectory(_currentDir),
            ),
          if (!_isConnecting)
            IconButton(
              icon: Icon(Icons.add, color: cs.secondary, size: 22),
              tooltip: t('new_file'),
              onPressed: _showNewEntryDialog,
            ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    final cs = Theme.of(context).colorScheme;
    if (_isConnecting) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(color: cs.secondary),
            const SizedBox(height: 16),
            Text(
              t('connecting'),
              style: TextStyle(
                color: cs.onSurface.withValues(alpha: 0.6),
                fontSize: 14,
              ),
            ),
          ],
        ),
      );
    }

    if (_errorMessage != null && _files.isEmpty) {
      return Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.cloud_off, size: 56, color: cs.error),
              const SizedBox(height: 16),
              Text(
                _errorMessage!,
                textAlign: TextAlign.center,
                maxLines: 6,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: cs.onSurface.withValues(alpha: 0.6),
                  fontSize: 14,
                ),
              ),
              const SizedBox(height: 24),
              ElevatedButton.icon(
                onPressed: _retry,
                icon: const Icon(Icons.refresh, size: 18),
                label: Text(
                  t('retry'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: cs.secondary,
                  foregroundColor: Theme.of(context).scaffoldBackgroundColor,
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Column(
      children: [
        SftpBreadcrumbBar(
          labels: _crumbs.map((crumb) => crumb.label).toList(),
          isSelectionMode: _selection.isActive,
          onCancelSelection: _exitSelectionMode,
          onCrumbTap: _navigateToCrumb,
        ),
        Divider(height: 1, color: Theme.of(context).dividerColor),
        Expanded(
          child: SftpFileList(
            files: _files,
            isLoading: _directory.isLoading,
            isSelectionMode: _selection.isActive,
            selectedPaths: _selection.paths,
            onOpenDirectory: _navigateToDirectory,
            onTapFile: _openEntry,
            onShowFileActions: _showFileActions,
            onToggleSelection: _toggleSelection,
            onEnterSelectionMode: _enterSelectionMode,
            onCreateEntry: _showNewEntryDialog,
          ),
        ),
        if (_selection.isActive)
          SftpSelectionBar(
            selectedCount: _selection.count,
            onDelete: _showBatchDeleteConfirm,
            onCancel: _exitSelectionMode,
          )
        else
          const SftpUploadBar(),
      ],
    );
  }
}
