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
Future<TransferQueueOutcome> queueUploadFromPicker(
  WidgetRef ref, {
  required String hostId,
  required String remoteDir,
}) async {
  final UploadPick picked;
  try {
    picked = await pickUploadFile();
  } catch (e) {
    // A picker that threw. Nothing reached the queue, so there is no task to
    // carry the report.
    // 选择器抛出异常。什么都没有到达队列，因此没有任务可以承载这条报告。
    return TransferQueueOutcome.localIo;
  }
  return queueUpload(ref, hostId: hostId, remoteDir: remoteDir, pick: picked);
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
