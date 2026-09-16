// Words, numbers and colours for one queued transfer, as the user reads them.
// 一个排队中的传输在用户眼中的文字、数字与颜色。
//
// Pure functions of a [TransferTask] and, where a colour is involved, of the
// active [ColorScheme]. Everything here can therefore be tested without a
// socket, a queue or a widget — and it is the only place a transfer's status or
// error code becomes text, so the sheet row and the compact indicator cannot
// drift apart the way two copies of a label table always do.
// 它们都是 [TransferTask]（涉及颜色时还有当前的 [ColorScheme]）的纯函数，因此这里的
// 一切无需套接字、队列或 widget 即可测试；而且它也是传输状态与错误编码变成文字的唯一
// 位置，面板行与紧凑指示器因此不会像两份标签表那样逐渐分叉。

import 'package:flutter/material.dart';

import '../../core/i18n/strings.dart';
import '../../models/transfer_task.dart';
import '../../services/sftp_service.dart';
import '../sftp/sftp_error_text.dart';

/// The word for [status].
/// [status] 对应的词。
String transferStatusLabel(TransferStatus status) => switch (status) {
  TransferStatus.queued => t('transfer_status_queued'),
  TransferStatus.running => t('transfer_status_running'),
  TransferStatus.done => t('transfer_status_done'),
  TransferStatus.failed => t('transfer_status_failed'),
  TransferStatus.cancelled => t('transfer_status_cancelled'),
};

/// The word for [direction].
/// [direction] 对应的词。
String transferDirectionLabel(TransferDirection direction) =>
    direction == TransferDirection.upload
    ? t('transfer_direction_upload')
    : t('transfer_direction_download');

/// The colour [status] is drawn in under [cs].
/// [status] 在 [cs] 下绘制所用的颜色。
///
/// A failure is the only state that gets the error colour: "done" is the accent,
/// the two in-flight states are the surface's own text colour, and a cancelled
/// task is deliberately not red — the user asked for it, and colouring their own
/// decision as a fault would be a lie about what happened.
/// 只有失败使用错误色：完成用强调色，两个进行中的状态用界面自身的文字色，而已取消
/// 有意不用红色——那是用户自己的决定，把它涂成故障就是在说谎。
Color transferStatusColor(TransferStatus status, ColorScheme cs) =>
    switch (status) {
      TransferStatus.done => cs.secondary,
      TransferStatus.failed => cs.error,
      TransferStatus.queued ||
      TransferStatus.running ||
      TransferStatus.cancelled => cs.onSurface.withValues(alpha: 0.62),
    };

/// The glyph for one task: its direction, or the outcome once it has stopped.
/// 单个任务的图标：其方向，或停止后的结果。
IconData transferTaskIcon(TransferTask task) {
  if (task.status == TransferStatus.failed) return Icons.error_outline;
  if (task.status == TransferStatus.done) return Icons.check_circle_outline;
  return task.direction == TransferDirection.upload
      ? Icons.upload_file
      : Icons.download_for_offline_outlined;
}

/// [bytes] as a human-readable size, using the same units and thresholds as
/// `FileItem.displaySize` so the file list and a transfer row never disagree
/// about how large the same file is.
/// 把 [bytes] 表示为可读大小，单位与阈值与 `FileItem.displaySize` 相同，使文件列表与
/// 传输行对同一个文件的大小不会给出两种说法。
String transferBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
}

/// The byte line under a transfer's progress bar.
/// 传输进度条下方的字节行。
///
/// When the total is unknown the moved bytes are still shown — they are the one
/// true thing available — and the missing half is named by
/// `transfer_unknown_size` rather than by a 0 % or a `?` the reader has to
/// interpret. `totalBytes` of 0 is treated as unknown for the same reason the
/// model does: a server that reports no size is not a server that reported an
/// empty file.
/// 总数未知时仍会显示已搬运的字节——那是当下唯一确定的事实——而缺失的另一半由
/// `transfer_unknown_size` 说明，而不是留给读者去解读的 0% 或 `?`。`totalBytes` 为 0
/// 同样按未知处理，理由与模型相同：不报大小的服务器并不等于报告了空文件。
String transferProgressLine(TransferTask task) {
  final moved = transferBytes(task.transferredBytes);
  final total = task.totalBytes;
  if (total == null || total <= 0) {
    return '$moved · ${t('transfer_unknown_size')}';
  }
  return '$moved / ${transferBytes(total)}';
}

/// Why [task] stopped, in the user's language.
/// [task] 为何停止，以用户的语言表述。
///
/// The queue reports a machine code and never prose, so the mapping lives here.
/// Everything except the device-side failure is a `SftpFailure` name that
/// `sftpFailureText` already has words for — including its raw detail, which is
/// the server's own complaint and the only part of an unexpected failure that
/// carries information. [TransferErrorCode.localIo] is the one code with no
/// `SftpFailure` behind it, and it has its own key.
/// 队列只报告机器编码，从不报告句子，因此映射放在这里。除设备侧失败之外，其余都是
/// `sftpFailureText` 已有现成文案的 `SftpFailure` 名称——包括其原始细节，那是服务器
/// 自己的抱怨，也是意外失败中唯一携带信息的部分。[TransferErrorCode.localIo] 是唯一
/// 背后没有 `SftpFailure` 的编码，它有自己的键。
///
/// A code that is neither — which the queue does not currently emit — is reported
/// as the operation that was being attempted, read or write, rather than as a
/// crash inside a formatter or as a raw identifier shown to the user.
/// 两者都不是的编码（队列目前不会发出）按当时尝试的操作报告——读或写——而不是在格式化
/// 函数里崩溃，也不是把裸标识符摆到用户眼前。
String transferFailureText(TransferTask task) {
  final code = task.error;
  if (code == null || code == TransferErrorCode.localIo) {
    return t('transfer_error_local_io');
  }
  return sftpFailureText(
    _failureByName(code) ?? _fallbackFailure(task.direction),
    task.errorDetail,
  );
}

/// The [SftpFailure] called [code], or null when no member carries that name.
/// 名为 [code] 的 [SftpFailure]；没有成员使用该名称时为 null。
///
/// `values.byName` is the obvious call and is deliberately not used: it throws
/// `ArgumentError` for an unknown name, and the one place that can happen is a
/// string that arrived from the queue — a formatter must not be able to kill the
/// frame that is merely trying to describe a task.
/// `values.byName` 是显而易见的写法，这里刻意不用：它对未知名称抛出 `ArgumentError`，
/// 而唯一可能出现该情况的输入是队列送来的字符串——一个格式化函数绝不该有能力杀死
/// 那个仅仅想描述任务的那一帧。
SftpFailure? _failureByName(String code) {
  for (final kind in SftpFailure.values) {
    if (kind.name == code) return kind;
  }
  return null;
}

/// The operation a task was attempting, for a failure that names nothing usable.
/// 任务当时正在尝试的操作，用于没有可用名称的失败。
SftpFailure _fallbackFailure(TransferDirection direction) =>
    direction == TransferDirection.upload
    ? SftpFailure.write
    : SftpFailure.read;

/// What a batch download did with a selection larger than what it could queue.
/// 一次批量下载对一个大于其承载能力的选中集做了什么。
///
/// Two numbers and no sentence: how many entries were ticked, and how many
/// downloads the tap created. The difference is what a batch cannot carry — a
/// directory above all, since this queue has no recursive walk — and naming both
/// numbers is the honest way to say so with the words the table has. A sentence
/// naming one cause would be wrong for the other: a ticked path can also leave
/// the listing in a refresh, and then it is not a directory that was left behind.
/// 两个数字，没有句子：勾选了多少条目，以及这次点击创建了多少个下载。差额正是批量无法
/// 承载的部分——首先是目录，因为这条队列没有递归遍历——而把两个数字都说出来，才是用表里
/// 已有的词诚实表达它的方式。只说出一种原因的句子对另一种就是错的：一条已勾选的路径也可能
/// 在一次刷新中离开列表，那时被留下的就不是目录了。
///
/// Only shown when the two numbers differ; equal ones say nothing a tapped
/// action has not already said, and the transfer indicator is where a plain
/// success shows up.
/// 仅在两个数字不同时显示；相等时它什么也没说出这次点击尚未说过的话，而普通的成功由传输
/// 指示器负责呈现。
String batchDownloadReport({required int queued, required int selected}) =>
    '${t('selected')}: $selected · ${t('download')}: $queued';

/// "Upload: N" for a pick that may have carried several files.
///
/// The count is the point. A multi-selection used to queue only its first file
/// and say nothing, so the report is what makes the difference between "the four
/// files I chose are on their way" and "one of the four did".
String batchUploadReport(int queued) => '${t('upload')}: $queued';

/// Whether any task in [tasks] still has work to do.
/// [tasks] 中是否仍有任务有待完成。
bool hasActiveTransfers(List<TransferTask> tasks) =>
    tasks.any((task) => !task.isTerminal);

/// The active tasks of [tasks], which are the ones a progress bar may describe.
/// [tasks] 中仍在进行的任务，即进度条可以描述的那些。
List<TransferTask> activeTransfers(List<TransferTask> tasks) =>
    tasks.where((task) => !task.isTerminal).toList();

/// Combined progress of [tasks], or null when it cannot be stated.
/// [tasks] 的合计进度；无法给出时为 null。
///
/// Null has two causes and both mean "indeterminate": nothing is running, and at
/// least one running task whose total is unknown. The second is the one worth
/// stating: averaging a known-size task together with an unknown-size one would
/// produce a bar that fills while the unknown task has moved nothing at all, so
/// the honest answer for the group is the indeterminate one.
/// null 有两种成因，都表示「不确定」：没有任何任务在跑，以及至少有一个在跑的
/// 任务其总数未知。第二种值得说明：把已知大小的任务与未知大小的任务平均在一起，会得到
/// 一根在未知任务一字节未动时就开始填充的进度条，因此对整组而言诚实的答案是不确定。
double? activeTransferProgress(List<TransferTask> tasks) {
  final active = activeTransfers(tasks);
  if (active.isEmpty) return null;

  var moved = 0;
  var total = 0;
  for (final task in active) {
    final size = task.totalBytes;
    if (size == null || size <= 0) return null;
    moved += task.transferredBytes;
    total += size;
  }
  if (total <= 0) return null;
  final ratio = moved / total;
  if (ratio.isNaN || ratio < 0) return 0;
  return ratio > 1 ? 1 : ratio;
}
