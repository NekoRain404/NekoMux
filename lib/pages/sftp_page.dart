import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/i18n/strings.dart';
import '../models/credential.dart';
import '../models/file_item.dart';
import '../models/host.dart';
import '../providers/transfer_provider.dart';
import '../services/sftp_service.dart';
import '../services/sftp_tree.dart';
import '../widgets/app_ui.dart';
import 'sftp/directory_load_state.dart';
import 'sftp/file_selection.dart';
import 'sftp/sftp_bars.dart';
import 'sftp/sftp_connection_mixin.dart';
import 'sftp/sftp_dialogs.dart';
import 'sftp/sftp_error_text.dart';
import 'sftp/sftp_file_list.dart';
import 'sftp/sftp_file_open.dart';
import 'sftp/sftp_path.dart';
import 'sftp/sftp_path_entry.dart';
import 'sftp/sftp_permissions.dart';
import 'sftp/sftp_remote_writes.dart';
import 'sftp/sftp_status_view.dart';
import 'transfer/transfer_actions.dart';
import 'transfer/transfer_format.dart';
import 'transfer/transfer_indicator.dart';
import 'transfer/transfer_io.dart';
import 'transfer/transfer_sheet.dart';

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

class _SftpPageState extends ConsumerState<SftpPage>
    with SftpConnectionState<SftpPage> {
  @override
  Host get host => widget.host;

  @override
  Credential? get initialCredential => widget.credential;

  @override
  Future<void> loadRootDirectory() => _loadDirectory('/');

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

  /// True while a folder's tree is being walked, before anything is queued.
  bool _scanning = false;


  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => resolveAndConnect());
  }

  @override
  void dispose() {
    sftpService?.disconnect();
    super.dispose();
  }

  /// Resolves the credential and the host-key trust record, then connects.
  /// 解析凭据与主机密钥信任记录，然后建立连接。
  String get _currentDir => _directory.requestedPath;

  /// What a batch download of the ticked entries would queue, and what it cannot.
  /// 对被勾选条目的批量下载会入队什么，以及它无法承载什么。
  ///
  /// Computed from [_files] rather than from the selection alone, because a task
  /// needs the entry's name and size, and so that the tasks come out in the order
  /// the list shows.
  /// 由 [_files] 而不是仅由选择集算出，因为任务需要条目的名称与大小，也为了让任务按列表
  /// 显示的顺序产生。
  BatchDownloadPlan get _batchPlan =>
      BatchDownloadPlan.of(_files, _selection.paths);

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
    // Nothing is connected when the page is showing its own error state — the
    // credential backing this host was deleted, or the connection never opened —
    // and the app bar draws refresh over that page anyway. The null check below
    // used to throw a `TypeError` there, which the generic `catch` turned into
    // "List failed: Null check operator used on a null value": the one message
    // that told the user what to fix was replaced by one that says nothing.
    // Leaving the error state alone is the honest answer — the reason is already
    // on screen, and Retry is the way out of it.
    // 当页面正显示自身错误状态时（本主机所依赖的凭据被删除，或连接从未建立），什么都没
    // 连接上——而应用栏在那张错误页上照样画着刷新按钮。下面的空检查此前会在此抛出
    // `TypeError`，由泛化的 `catch` 转成「列举失败: Null check operator used on a null
    // value」：唯一告诉用户该修什么的那句话，被一句什么都没说的替代了。保持错误状态不变
    // 才是诚实的答案——原因已经在屏幕上，而「重试」是离开它的出口。
    final service = sftpService;
    if (service == null) return;

    final request = _directory.begin(path);
    final changesDirectory = path != _directory.shownPath;

    setState(() {
      errorMessage = null;
      // A batch action must never reach a path the user can no longer see, so
      // changing directory drops the selection. A plain refresh keeps it.
      // 批量操作绝不能触及用户已经看不到的路径，因此切换目录会清空选择；单纯刷新则保留。
      if (changesDirectory) _selection.clear();
    });

    try {
      final entries = await service.listDirectory(path);
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
      if (!canKeepListing) errorMessage = message;
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

  /// Scans a directory and queues every file under it.
  ///
  /// The walk happens here, before anything is queued, because the queue moves
  /// files and has no recursion behind it — and because the user is owed the
  /// answer to "how much is this?" before it starts moving. What the scan could
  /// not carry is reported rather than quietly dropped: an empty folder leaves
  /// nothing to download, and a subdirectory that refused is the difference
  /// between a faithful copy and one the user only discovers is incomplete later.
  Future<void> _queueFolderDownload(FileItem folder) async {
    final service = sftpService;
    if (service == null) return;

    setState(() => _scanning = true);
    final TreeScanResult scan;
    try {
      scan = await scanTree(service, folder.path);
    } on SftpException catch (e) {
      if (mounted) _showSnack(sftpErrorText(e), isError: true);
      return;
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
    if (!mounted) return;

    if (!scan.complete) {
      _showSnack(
        t(
          'folder_scan_incomplete',
        ).replaceAll('{0}', scan.failedPath ?? folder.path),
        isError: true,
      );
    }
    if (scan.files.isEmpty) {
      _showSnack(t('folder_has_no_files'));
      return;
    }

    final result = queueFolderDownloadToStaging(
      ref,
      hostId: widget.host.id,
      folderName: folder.name,
      files: scan.files,
    );
    if (!mounted) return;
    if (result.outcome == TransferQueueOutcome.localIo) {
      _showSnack(t('transfer_error_local_io'), isError: true);
      return;
    }
    _showSnack(
      t('folder_queued')
          .replaceAll('{0}', '${result.queued}')
          .replaceAll('{1}', '${scan.emptyDirectories}'),
    );
  }

  /// Asks for a path and goes there.
  ///
  /// The breadcrumb bar can only go *up*: reaching `/var/log/nginx` from `/`
  /// meant tapping through `var`, `log`, `nginx` — and a directory that is more
  /// than one level deep in a list of hundreds is a hunt, not a navigation. A
  /// server's paths are known to the person managing it, so the app asks rather
  /// than making them scroll.
  Future<void> _promptForPath() async {
    final service = sftpService;
    if (service == null) return;

    final resolved = await promptForRemotePath(
      context,
      service: service,
      currentDir: _currentDir,
      onError: (message) => _showSnack(message, isError: true),
    );
    if (resolved == null || !mounted) return;
    await _loadDirectory(resolved);
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
  ///
  /// The read guard, the decoding and the write-back live in
  /// [openSftpTextFile]; what stays here is the choice between previewing and
  /// showing the actions sheet, which is the page's own decision.
  Future<void> _openFile(FileItem file) async {
    final service = sftpService;
    if (service == null) return;
    await openSftpTextFile(
      context,
      service: service,
      file: file,
      notify: _showSnack,
    );
  }

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
      case SftpFileAction.download:
        _queueDownload(file);
      case SftpFileAction.downloadFolder:
        await _queueFolderDownload(file);
      case SftpFileAction.rename:
        await _showRenameDialog(file);
      case SftpFileAction.changePermissions:
        await _showPermissionsDialog(file);
      case SftpFileAction.select:
        setState(() => _selection.begin(file.path));
      case SftpFileAction.delete:
        await _confirmDeleteFile(file);
    }
  }

  /// Picks one or more local files and queues them into the directory on screen
  /// — the path the bar names, which is what every other write on this page
  /// targets too.
  /// 挑选一个或多个本地文件并把它们排入屏幕上显示的目录——路径栏所示、也是本页其它每一处
  /// 写入所针对的那个路径。
  ///
  /// The picker allows multi-selection, and every chosen file is queued: a
  /// selection of five used to send only the first, with nothing on screen to say
  /// the other four had been dropped. The count is reported whenever it differs
  /// from one, so the row of transfers the user is about to see matches what they
  /// picked.
  /// 选择器允许多选，且每个被选中的文件都会入队：过去一次五选只发第一个，而屏幕上没有任何
  /// 东西说明另外四个已被丢弃。只要数量不为 1 就报出这个数量，使用户即将看到的那批传输与
  /// 他们的选择相符。
  Future<void> _queueUpload() async {
    final picked = await pickUploadsSafely();
    if (!mounted) return;
    if (picked.failed) {
      // Nothing reached the queue, so no transfer row can carry this report.
      _showSnack(t('transfer_error_local_io'), isError: true);
      return;
    }
    if (picked.picks.isEmpty) return;
    final picks = picked.picks;

    if (!await _confirmUploadOverwrite(picks)) return;
    if (!mounted) return;

    final result = queueUploads(
      ref,
      hostId: widget.host.id,
      remoteDir: _currentDir,
      picks: picks,
    );
    if (!mounted) return;
    if (result.outcome == TransferQueueOutcome.localIo) {
      _showSnack(t('transfer_error_local_io'), isError: true);
      return;
    }
    if (result.queued > 1) _showSnack(batchUploadReport(result.queued));
  }

  /// Asks before an upload would replace a file that is already there.
  ///
  /// The upload opens its remote path with `truncate`, so dropping a file into a
  /// directory that already holds that name destroys the server's copy with no
  /// warning at all — and the file in hand is very often a different file that
  /// happens to share a name (two builds of `app.apk`, two days of
  /// `access.log`). Only names that already exist are counted, so the question
  /// is asked when it is real rather than on every upload.
  Future<bool> _confirmUploadOverwrite(List<UploadPick> picks) async {
    final service = sftpService;
    if (service == null) return false;

    final clashing = <String>[];
    for (final pick in picks) {
      if (!pick.canUpload) continue;
      try {
        if (await service.exists(sftpChildPath(_currentDir, pick.name))) {
          clashing.add(pick.name);
        }
      } on SftpException {
        // A path that cannot be checked is not evidence of a collision, and
        // refusing the upload because a stat failed would be worse than letting
        // the transfer report its own failure.
        continue;
      }
    }
    if (clashing.isEmpty) return true;
    if (!mounted) return false;

    return showAppConfirmDialog(
      context,
      title: t('confirm_overwrite_title'),
      message: clashing.length == 1
          ? t('confirm_overwrite_file').replaceAll('{0}', clashing.single)
          : t('confirm_overwrite_many').replaceAll('{0}', '${clashing.length}'),
      cancelLabel: t('cancel'),
      confirmLabel: t('confirm'),
      destructive: true,
    );
  }

  /// Queues a download of [file] into this app's staging area; the destination
  /// is chosen on the finished row (see [queueDownloadToStaging]).
  /// 把 [file] 的下载排入本应用的暂存区；目的地在该任务完成后的行上选定
  /// （见 [queueDownloadToStaging]）。
  ///
  /// Synchronous throughout, so there is no `await` between the tap and the task
  /// appearing in the queue — and no `mounted` guard to forget either.
  /// 全程同步，因此从点击到任务出现在队列之间没有任何 `await`——也就没有会被忘记的
  /// `mounted` 守卫。
  void _queueDownload(FileItem file) => _reportTransfer(
    queueDownloadToStaging(ref, hostId: widget.host.id, file: file),
  );

  /// Queues one download per ticked file, and says what it could not carry.
  /// 为每个被勾选的文件各排入一次下载，并说出它无法承载的部分。
  ///
  /// Synchronous, like the single-file download it repeats: nothing here awaits a
  /// socket or a dialog, so a selection of two hundred files costs one loop over
  /// the entries and one appended batch of tasks, and the frame that handled the
  /// tap still paints on time.
  /// 与它所重复的单文件下载一样是同步的：这里不等待套接字或对话框，因此两百个文件的选中集
  /// 只花掉一次条目遍历和一次任务追加，处理点击的那一帧照常按时绘制。
  ///
  /// The selection stays as it was: nothing on the server changed, so the same
  /// entries can be downloaded again or deleted next, and a tick set the user
  /// built by hand is not something to throw away on their behalf.
  /// 选择集保持不变：服务器上没有任何改变，因此同一批条目可以再下一次或被接着删除，而用户
  /// 亲手勾出来的集合不该由我们替他们丢掉。
  void _queueBatchDownload() {
    final plan = _batchPlan;
    if (plan.files.isEmpty) return;

    final result = queueBatchDownloadToStaging(
      ref,
      hostId: widget.host.id,
      files: plan.files,
    );
    _reportTransfer(result.outcome);
    // Not an error: the batch is queued and running. What the user has not been
    // told yet is that the queue took fewer entries than they ticked, and the
    // answer to that is the two numbers rather than a red banner.
    // 这不是错误：整批已入队并在运行。用户尚未被告知的，是队列收下的条目少于他们勾选的
    // 数量，而对此的答复是两个数字，不是一条红色的横幅。
    if (plan.skipped > 0) {
      _showSnack(
        batchDownloadReport(queued: result.queued, selected: _selection.count),
      );
    }
  }

  /// Reports the one outcome a transfer action cannot report by itself: a
  /// device-side failure, which has no row to appear on because nothing was ever
  /// queued. Everything else shows up in the transfer list on its own.
  /// 报告传输操作自身无法报告的那一种结局：设备侧失败——因为什么都没入队，它没有行可以
  /// 出现。其余一切都会自己出现在传输列表中。
  ///
  /// The outcome is awaited rather than the action, so a synchronously enqueued
  /// download is in the queue before this returns.
  /// 这里等待的是结局而不是动作，因此同步入队的下载在它返回之前就已在队列中。
  Future<void> _reportTransfer(FutureOr<TransferQueueOutcome> outcome) async {
    final result = await outcome;
    if (!mounted || result != TransferQueueOutcome.localIo) return;
    _showSnack(t('transfer_error_local_io'), isError: true);
  }

  /// Opens the transfer list over this page, then re-lists the directory it may
  /// have changed.
  /// 在本页之上打开传输列表，返回时重新列举它可能改变了内容的目录。
  ///
  /// The queue runs on a connection of its own, so an upload that finished while
  /// the sheet was open would otherwise look like it never happened — precisely
  /// the question the user opened the sheet to answer. One listing of the
  /// directory already on screen, and none while something is still moving:
  /// mid-transfer there is nothing new to see.
  /// 队列使用自己的一条连接，因此在面板打开期间完成的上传否则会看起来从未发生过——
  /// 而那正是用户打开面板要回答的问题。只列举一次屏幕上已有的那个目录，且在有传输仍在
  /// 进行时完全不列举：传输途中没有新东西可看。
  Future<void> _openTransfers() async {
    await showTransferSheet(context);
    if (!mounted || hasActiveTransfers(ref.read(transferQueueProvider))) {
      return;
    }
    await _loadDirectory(_currentDir);
  }

  /// Renames [file] to the name the user types.
  /// 将 [file] 重命名为用户输入的名称。
  Future<void> _showRenameDialog(FileItem file) async {
    final service = sftpService;
    if (service == null) return;
    await renameSftpEntry(
      context,
      service: service,
      dir: _currentDir,
      file: file,
      notify: _showSnack,
    );
    if (!mounted) return;
    await _loadDirectory(_currentDir);
  }

  /// Asks for a new permission mode and applies it.
  ///
  /// `setPermissions` preserves the file-type bits (see the service), so this
  /// changes who may read, write and execute the entry without turning a
  /// directory into a file — the mistake a bare `chmod`-style write would make
  /// against a mode that also carries the type.
  Future<void> _showPermissionsDialog(FileItem file) async {
    final service = sftpService;
    if (service == null) return;

    final mode = await showSftpChmodDialog(
      context,
      name: file.name,
      current: file.permissions,
    );
    if (mode == null || !mounted) return;

    try {
      await service.setPermissions(file.path, mode);
      if (!mounted) return;
      await _loadDirectory(_currentDir);
      if (mounted) _showSnack(t('permissions_changed'));
    } on SftpException catch (e) {
      if (mounted) _showSnack(sftpErrorText(e), isError: true);
    }
  }

  /// Deletes one entry after confirming.
  /// 确认后删除单个条目。
  Future<void> _confirmDeleteFile(FileItem file) async {
    final service = sftpService;
    if (service == null) return;
    await deleteSftpEntry(
      context,
      service: service,
      file: file,
      notify: _showSnack,
    );
    if (!mounted) return;
    await _loadDirectory(_currentDir);
  }

  /// The "new file / new folder" flow: choose a kind, name it, create it.
  /// 「新建文件 / 新建文件夹」流程：选择类型、命名、创建。
  ///
  /// The asking, the overwrite guard and the write live in [createSftpEntry];
  /// reloading the directory is this page's half, because it is the page that
  /// knows which directory the bar is showing.
  Future<void> _showNewEntryDialog() async {
    final service = sftpService;
    if (service == null) return;
    await createSftpEntry(
      context,
      service: service,
      dir: _currentDir,
      notify: _showSnack,
    );
    if (!mounted) return;
    await _loadDirectory(_currentDir);
  }

  /// Deletes every selected path, then reports what actually happened.
  /// 删除全部已选路径，然后如实报告结果。
  Future<void> _showBatchDeleteConfirm() async {
    final service = sftpService;
    final paths = _selection.paths.toList();
    if (service == null || paths.isEmpty) return;
    // From the listing, so a ticked directory is known to be one and can be
    // walked: the selection carries only paths, and a path cannot say whether
    // removing it needs a recursive delete or a single call.
    final entries = [
      for (final path in paths)
        ..._files.where((file) => file.path == path),
    ];
    if (entries.isEmpty) return;

    final confirmed = await confirmSftpBatchDelete(
      context,
      paths,
      includesDirectory: entries.any((entry) => entry.isDirectory),
    );
    if (!confirmed || !mounted) return;

    setState(_selection.clear);
    await deleteSftpEntries(
      context,
      service: service,
      entries: entries,
      notify: _showSnack,
    );
    if (!mounted) return;
    await _loadDirectory(_currentDir);
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
          // The same treatment the console's refresh gets, for the same reason:
          // a folder scan walks a tree one listing at a time, so on a large
          // directory it is seconds of work with nothing moving on screen, and
          // the icon that started it must not stay tappable through it.
          if (_scanning)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 14),
              child: Center(
                child: SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            )
          else if (!isConnecting)
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
          if (!isConnecting)
            IconButton(
              icon: Icon(Icons.add, color: cs.secondary, size: 22),
              tooltip: t('new_file'),
              onPressed: _showNewEntryDialog,
            ),
          // Hidden by the button itself while the queue is empty, and it watches
          // only the task count — the page must not rebuild on every progress
          // tick, and this is the one place that could make it.
          // 队列为空时由按钮自己隐藏；它只监听任务数量——页面绝不能因每一次进度跳动而
          // 重建，而这里是唯一可能让它那样的地方。
          TransferQueueButton(onOpen: _openTransfers),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    // Which of the three states the page is in is decided here, where the listing
    // and the load state live; what a state looks like is not, because none of the
    // drawing needs either of them.
    // 页面处于三种状态中的哪一种由这里决定——列表与加载状态都在这里；而每种状态长什么样
    // 不由这里决定，因为绘制它们不需要这两样中的任何一样。
    if (isConnecting ||
        sessionLost ||
        (errorMessage != null && _files.isEmpty)) {
      return SftpStatusView(
        isConnecting: isConnecting,
        errorMessage: errorMessage,
        onRetry: retryConnection,
      );
    }

    return Column(
      children: [
        // Above the path bar, because a transfer is not part of the listing: it
        // belongs to the page, and it stays visible while the listing scrolls or
        // is replaced by a spinner.
        // 位于路径栏之上，因为传输不属于列表：它属于页面，因此在列表滚动或被转圈取代
        // 时仍然可见。
        TransferActivityBar(onOpen: _openTransfers),
        SftpBreadcrumbBar(
          labels: _crumbs.map((crumb) => crumb.label).toList(),
          isSelectionMode: _selection.isActive,
          onCancelSelection: _exitSelectionMode,
          onCrumbTap: _navigateToCrumb,
          onEditPathTap: sftpService == null ? null : _promptForPath,
        ),
        Divider(height: 1, color: Theme.of(context).dividerColor),
        Expanded(
          // Reloading a remote directory used to mean hitting the app bar's
          // 22 px icon, which is disabled whenever a listing is already in
          // flight — so the one gesture every other list in this app answers to
          // (systemd, the task manager) did nothing here, on the screen most
          // likely to be showing stale data: a directory changes when something
          // else writes to it, which is exactly when the user pulls.
          child: RefreshIndicator(
            color: Theme.of(context).colorScheme.primary,
            onRefresh: () => _loadDirectory(_currentDir),
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
        ),
        if (_selection.isActive)
          SftpSelectionBar(
            selectedCount: _selection.count,
            fileCount: _batchPlan.files.length,
            onDownload: _queueBatchDownload,
            onDelete: _showBatchDeleteConfirm,
            onCancel: _exitSelectionMode,
          )
        else
          SftpUploadBar(onUpload: _queueUpload),
      ],
    );
  }
}
