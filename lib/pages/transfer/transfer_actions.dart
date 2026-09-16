// Starting a transfer from the file manager: the decisions that are not about
// drawing anything.
// 从文件管理器发起传输：与绘制无关的那些判断。
//
// They live here rather than in the page because each one is a small rule with a
// reason behind it — which remote directory an upload targets, whether a
// download is staged — and a page that is already the longest file in this area
// is the wrong place to read them in.
// 它们放在这里而不是页面里，是因为每一条都是一条带理由的小规则——上传以哪个远程目录为
// 目标、下载是否走暂存——而页面已经是这一带最长的文件，不是读它们的好地方。

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/file_item.dart';
import '../../providers/transfer_provider.dart';
import '../sftp/sftp_path.dart';
import 'transfer_io.dart';

/// What came of asking for a transfer.
/// 一次传输请求的结局。
enum TransferQueueOutcome {
  /// The task is in the queue; it runs on its own from here.
  /// 任务已在队列中；从此刻起它自行运行。
  queued,

  /// The user dismissed the picker, or chose nothing usable.
  /// 用户关闭了选择器，或没有选中可用的东西。
  cancelled,

  /// The device side failed before anything could be queued — nothing was
  /// chosen from disk, or there is nowhere to write.
  /// 设备侧在入队之前就失败了——没有从磁盘选中任何东西，或者无处可写。
  localIo,
}

/// Picks a local file and queues it into [remoteDir] on [hostId].
/// 挑选一个本地文件并把它排入 [hostId] 上的 [remoteDir]。
///
/// The caller passes the directory it is showing. Which directory that is — the
/// path the bar names, which is also what every other write on that page targets
/// — is the page's decision; this function only turns it into a task. The bar
/// and the listing can only differ while a listing is in flight, and
/// `DirectoryLoadState.commitFailed` puts them back together after a failure, so
/// the two never stay apart.
/// 调用方传入它正在显示的目录。「到底是哪一个」——路径栏所示、同时也是该页其它每一处
/// 写入所针对的那个路径——是页面的决定；本函数只负责把它变成一个任务。路径栏与列表只
/// 可能在列举进行中不一致，而 `DirectoryLoadState.commitFailed` 会在失败后把两者复原，
/// 因此二者不会长期分离。
///
/// Returns as soon as the task is in the list: the picker is the only thing the
/// user waits on, and the transfer itself never blocks them.
/// 任务入列后立即返回：用户唯一需要等待的只有选择器，传输本身从不阻塞他们。
/// The outcome of asking the platform which files to upload.
class UploadPickResult {
  /// What the picker returned; empty when it was dismissed or it failed.
  final List<UploadPick> picks;

  /// True when the picker itself threw — a platform-channel failure, which has
  /// no task to appear on and no row to explain itself, so the caller has to
  /// say something.
  final bool failed;

  const UploadPickResult(this.picks, {this.failed = false});
}

/// Asks for files to upload, turning a failed picker into a reported value.
///
/// The picker is a platform channel, and a channel that fails throws where it is
/// called: out of the tap handler, in a build-invalidating place, with nothing
/// queued and no explanation shown. Catching it here keeps that from being the
/// user's whole experience of tapping upload.
Future<UploadPickResult> pickUploadsSafely() async {
  try {
    return UploadPickResult(await pickUploadFiles());
  } catch (_) {
    return const UploadPickResult([], failed: true);
  }
}

/// Queues one upload per pick, and counts what got in.
///
/// The picking itself is the page's: it may want to ask something about the
/// picks first (whether they would replace files already on the server, say),
/// and a helper that picked and queued in one step would leave nowhere to put
/// that question. What stays here is the queueing rule, once.
BatchUploadResult queueUploads(
  WidgetRef ref, {
  required String hostId,
  required String remoteDir,
  required List<UploadPick> picks,
}) {
  // An empty list is a dismissed picker, not a successful queue of nothing. It
  // is reported as such rather than as `queued` with a zero count, which is the
  // shape a caller reads as "it worked" and then cannot tell apart from a real
  // failure to enqueue.
  if (picks.isEmpty) {
    return const BatchUploadResult(0, TransferQueueOutcome.cancelled);
  }

  var queued = 0;
  var outcome = TransferQueueOutcome.queued;
  for (final pick in picks) {
    final result = queueUpload(
      ref,
      hostId: hostId,
      remoteDir: remoteDir,
      pick: pick,
    );
    if (result == TransferQueueOutcome.queued) {
      queued++;
    } else {
      // One unusable pick must not abort the rest: a document-provider file
      // that cannot be read is a reason to skip that file, not to drop the
      // four the user chose alongside it.
      outcome = result;
    }
  }
  return BatchUploadResult(queued, outcome);
}

/// How many picks reached the queue, and whether any did not.
class BatchUploadResult {
  /// Number of uploads queued.
  final int queued;

  /// [TransferQueueOutcome.queued] when every pick was queued, otherwise the
  /// device-side failure one of them hit.
  final TransferQueueOutcome outcome;

  const BatchUploadResult(this.queued, this.outcome);
}

/// Queues [pick] as an upload into [remoteDir] on [hostId].
/// 把 [pick] 作为一次上传排入 [hostId] 上的 [remoteDir]。
///
/// Split from asking the user so that the rule this function states — the remote
/// path is [remoteDir] joined with the picked file's own name, and its reported
/// size travels with it — can be read and tested without a picker, a platform
/// channel or a file on disk. The asking half is one `await` and no decisions.
/// 与「询问用户」分开，是为了让本函数所述的规则——远程路径是 [remoteDir] 与所选文件自身
/// 名称的拼接，其报告的大小随之同行——无需选择器、平台通道或磁盘上的文件即可阅读与测试。
/// 「询问」那一半只有一个 `await`，不含任何判断。
TransferQueueOutcome queueUpload(
  WidgetRef ref, {
  required String hostId,
  required String remoteDir,
  required UploadPick pick,
}) {
  if (pick.cancelled) return TransferQueueOutcome.cancelled;

  final localPath = pick.path;
  if (!pick.canUpload || localPath == null) {
    // Chosen, but with nothing on disk this app can read — which is what a
    // picker answers with when the file lives only behind a document provider
    // it cannot export. Saying so beats a tap that appears to do nothing.
    // 选中了，但磁盘上没有本应用可读的东西——当文件只存在于某个无法导出的文档提供方
    // 后面时，选择器给出的就是这个答案。说出来，好过一次看起来毫无反应的点击。
    return TransferQueueOutcome.localIo;
  }

  ref
      .read(transferQueueProvider.notifier)
      .enqueueUpload(
        hostId: hostId,
        localPath: localPath,
        remotePath: sftpChildPath(remoteDir, pick.name),
        name: pick.name,
        totalBytes: pick.size,
      );
  return TransferQueueOutcome.queued;
}

/// What a batch download of the ticked entries would queue, and what it cannot.
/// 对被勾选条目的批量下载会入队什么，以及它无法承载什么。
///
/// A directory is why this type exists: the queue moves *files* — one remote path
/// to one local path, with no recursive walk anywhere behind it — so a ticked
/// directory has nothing it could enqueue. Dropping it without a word would be a
/// lie about what the tap did, hence [skipped]: the number of ticked entries this
/// plan leaves behind, counted rather than explained, because there are two ways
/// to land there (a directory, or a path a refresh removed from the listing after
/// it was ticked) and a message naming one of them would be wrong about the other.
/// 目录正是本类型存在的理由：队列搬运的是**文件**——一条远程路径对一条本地路径，背后没有
/// 任何递归遍历——因此被勾选的目录没有东西可以入队。只字不提地丢掉它，就是对这次点击做了
/// 什么说谎，因此有了 [skipped]：本方案留下的已勾选条目数，只计数而不解释，因为落到这里的
/// 途径有两条（目录，或某条在勾选之后被刷新从列表中移除的路径），而只说出其中一条的文案
/// 对另一条就是错的。
class BatchDownloadPlan {
  /// The ticked entries that are files, in listing order.
  /// 已勾选中属于文件的条目，按列表顺序。
  final List<FileItem> files;

  /// How many ticked entries this plan cannot queue.
  /// 本方案无法入队的已勾选条目数。
  final int skipped;

  const BatchDownloadPlan(this.files, this.skipped);

  /// The plan for [selectedPaths] among [entries].
  /// [entries] 之中 [selectedPaths] 对应的方案。
  ///
  /// Driven by [entries] and not by the selection, which is what puts the tasks
  /// in the order the user is looking at; and it counts a ticked path that is not
  /// in [entries] as skipped, because a path is not enough to download — the name
  /// and the size a task carries both come from the entry.
  /// 以 [entries] 为主线而不是以选择集为主线，正是这一点让任务按用户眼前的顺序排列；
  /// 它把不在 [entries] 中的已勾选路径计入 skipped，因为光有路径不足以发起下载——任务
  /// 携带的名称与大小都来自条目。
  factory BatchDownloadPlan.of(
    List<FileItem> entries,
    Set<String> selectedPaths,
  ) {
    final files = <FileItem>[
      for (final entry in entries)
        if (!entry.isDirectory && selectedPaths.contains(entry.path)) entry,
    ];
    return BatchDownloadPlan(files, selectedPaths.length - files.length);
  }
}

/// What a batch download actually did.
/// 一次批量下载实际做了什么。
class BatchDownloadResult {
  /// How many tasks reached the queue.
  /// 有多少个任务进入了队列。
  final int queued;

  /// [TransferQueueOutcome.queued] when every file was queued, otherwise the
  /// device-side failure that stopped one of them — the only other thing
  /// [queueDownloadToStaging] reports.
  /// 全部文件都入队时为 [TransferQueueOutcome.queued]，否则是拦下其中某个文件的设备侧
  /// 失败——那是 [queueDownloadToStaging] 唯一会报告的另一种结局。
  final TransferQueueOutcome outcome;

  const BatchDownloadResult(this.queued, this.outcome);
}

/// Queues one download per file in [files], each into this app's staging area.
/// 为 [files] 中的每个文件各排入一次下载，全都进入本应用的暂存区。
///
/// It goes through [queueDownloadToStaging] rather than restating it: the staging
/// path, the size carried over from the listing and the check that there is
/// somewhere to write are that function's rules, and a batch that derived them
/// again would be a second copy of each — the kind that drifts.
/// 它经由 [queueDownloadToStaging] 而不是复述它：暂存路径、从列表带过来的大小，以及
/// 「有没有地方可写」的检查都是那条函数的规则，而重新推导它们的批量版本会成为每一条规则的
/// 第二个副本——也就是会分叉的那一种。
///
/// Synchronous end to end, which is what keeps a two-hundred-file selection from
/// costing a frame: the loop appends to the queue's list and returns, and nothing
/// in it awaits a socket, a disk or a dialog. The one device call it repeats is
/// the staging-directory check inside [queueDownloadToStaging] — a stat on a
/// directory that exists from the first file onwards — and the transfers
/// themselves then run one at a time, in the order they were queued, on the
/// queue's own connection.
/// 从头到尾同步，这正是两百个文件的选中集不会花掉一帧的原因：循环只往队列的列表里追加
/// 然后返回，其中没有任何一处等待套接字、磁盘或对话框。它唯一重复的设备调用是
/// [queueDownloadToStaging] 内部的暂存目录检查——从第一个文件起该目录就已存在，因此那只是
/// 一次 stat——而传输本身随后按入队顺序、在队列自己的连接上逐个运行。
///
/// A failure does not abort the batch: the queue's whole contract is that one
/// unreachable file must not hold up the thirty behind it, and that applies at
/// enqueue time too. The count says how many got in, and [BatchDownloadResult.outcome]
/// says whether any did not.
/// 失败不会中断整批：这条队列的全部契约就是一个取不到的文件不该挡住它后面的三十个，这在
/// 入队阶段同样成立。计数说明进去了多少个，[BatchDownloadResult.outcome] 说明是否有没进去的。
BatchDownloadResult queueBatchDownloadToStaging(
  WidgetRef ref, {
  required String hostId,
  required List<FileItem> files,
}) {
  var queued = 0;
  var outcome = TransferQueueOutcome.queued;
  for (final file in files) {
    final result = queueDownloadToStaging(ref, hostId: hostId, file: file);
    if (result == TransferQueueOutcome.queued) {
      queued++;
    } else {
      outcome = result;
    }
  }
  return BatchDownloadResult(queued, outcome);
}

/// Queues a download of [file] into this app's staging area.
/// 把 [file] 的下载排入本应用的暂存区。
///
/// The bytes cannot be streamed straight to a location the user picks — see
/// `transfer_io.dart` for what `saveFile` actually does on Android and why the
/// download is staged first. The finished row offers "save", which is where a
/// destination is chosen and where the file lands there.
/// 字节无法直接流式写入用户选定的位置——`saveFile` 在 Android 上究竟做什么、下载为何
/// 先暂存，见 `transfer_io.dart`。已完成的行上提供「保存」，目的地正是在那一步选定，
/// 文件也在那一步落到那里。
///
/// The listing's size is passed along when it has one, so the row shows a real
/// bar from the first chunk instead of flipping from indeterminate once the
/// queue has asked the server the same question.
/// 列表给出了大小时会一并传入，使该行从第一块数据起就显示真实的进度条，而不是等到队列
/// 向服务器问了同一个问题之后才从不确定态翻转过来。
TransferQueueOutcome queueDownloadToStaging(
  WidgetRef ref, {
  required String hostId,
  required FileItem file,
}) {
  try {
    // Synchronously, so that queueing has no `await` in it at all: the task is
    // in the list before the tap handler returns, and there is no gap in which
    // the page could be popped out from under the code that reports a failure.
    // On a directory that already exists this is a stat, which is why paying it
    // on the caller's thread is cheaper than the state machine an async version
    // would need.
    // 同步执行，使入队过程中完全没有 `await`：处理函数返回之前任务就已在列表中，也不存在
    // 页面可能在报告失败的那段代码脚下被弹出的空档。对已存在的目录而言这只是一次 stat，
    // 因此在调用方线程上付出它，比异步版本所需的那套状态机更便宜。
    transferStagingDirectory().createSync(recursive: true);
  } catch (e) {
    // Nowhere to write, so the transfer would fail the moment it started.
    // Refusing here names the reason instead of queueing a task whose only
    // possible outcome is `localIo`.
    // 无处可写，传输一开始就会失败。在这里拒绝能说出原因，而不是排入一个结局只可能是
    // `localIo` 的任务。
    return TransferQueueOutcome.localIo;
  }

  ref
      .read(transferQueueProvider.notifier)
      .enqueueDownload(
        hostId: hostId,
        remotePath: file.path,
        localPath: stagedDownloadPath(file.name),
        name: file.name,
        totalBytes: file.size > 0 ? file.size : null,
      );
  return TransferQueueOutcome.queued;
}
