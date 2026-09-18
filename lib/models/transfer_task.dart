/// Which way a [TransferTask] moves bytes.
/// [TransferTask] 搬运字节的方向。
///
/// A direction, not a label: the words a user reads come from the i18n table, so
/// this enum carries no language — the same rule `FileCategory` follows.
/// 方向而非标签：用户读到的文字来自 i18n 表，因此本枚举不携带任何语言——与
/// `FileCategory` 遵循同一条规则。
enum TransferDirection {
  /// Local file → server.
  /// 本地文件 → 服务器。
  upload,

  /// Server → local file.
  /// 服务器 → 本地文件。
  download,
}

/// Where a [TransferTask] is in its life.
/// [TransferTask] 在其生命周期中的位置。
enum TransferStatus {
  /// Waiting for its turn. The queue runs one task at a time per host.
  /// 等待轮到自己。队列对每台主机一次只跑一个任务。
  queued,

  /// Moving bytes right now.
  /// 正在搬运字节。
  running,

  /// Finished: every byte arrived.
  /// 已完成：所有字节都已送达。
  done,

  /// Stopped by an error. [TransferTask.error] says which.
  /// 因错误而中止。[TransferTask.error] 会说明是哪一个。
  failed,

  /// Stopped because the user asked it to stop.
  /// 因用户要求停止而中止。
  cancelled,
}

/// Error codes a [TransferTask] can carry that are not `SftpFailure` names.
/// [TransferTask] 可能携带的、并非 `SftpFailure` 名称的错误编码。
///
/// A task failing on the server side reports the `SftpFailure` that
/// `services/sftp_service.dart` classified (so `sftpFailureText` already has
/// words for it). A task failing on the *phone's* side — the picked directory
/// cannot be written, the local file vanished between enqueue and run — has no
/// `SftpFailure` to report, and this is the code it uses instead.
/// 服务器侧的失败会报告 `services/sftp_service.dart` 归类出的 `SftpFailure`
/// （`sftpFailureText` 已经为它准备了文字）。手机侧的失败——所选目录写不进去、
/// 本地文件在入队与执行之间消失——没有 `SftpFailure` 可报告，改用本编码。
///
/// A plain string constant rather than an enum so the model stays free of service
/// dependencies (`CLAUDE.md`: models import neither Flutter nor services), while
/// still giving the presentation layer one name to switch on.
/// 用普通字符串常量而不是枚举，是为了让模型不依赖服务
/// （`CLAUDE.md`：模型不引入 Flutter，也不引入服务），同时仍给展示层一个可判定的名字。
class TransferErrorCode {
  /// The local (device) side of the transfer failed.
  /// 传输的本地（设备）一侧失败了。
  static const String localIo = 'localIo';

  const TransferErrorCode._();
}

/// One queued or finished upload or download.
/// 一个排队中或已结束的上传/下载任务。
///
/// Immutable: the queue publishes a new instance when anything about a task
/// changes, which is what makes `transferTaskProvider`'s identity comparison a
/// usable "did *this* task change" test.
/// 不可变：任务有任何变化时队列都会发布一个新实例，这正是
/// `transferTaskProvider` 的身份比较能当作「**这个**任务变了吗」来用的原因。
class TransferTask {
  /// Unique identifier, stable across status changes.
  /// 唯一标识符，在状态变化间保持不变。
  final String id;

  /// The host this task runs against — also the queue it waits in.
  /// 本任务所针对的主机——同时也是它排队的队列。
  final String hostId;

  /// Display name (the file's name), for the UI.
  /// 显示名称（文件名），供界面使用。
  final String name;

  /// Path of the file on the server.
  /// 文件在服务器上的路径。
  final String remotePath;

  /// Path of the file on the device: where an upload reads from, where a
  /// download writes to. Null only for a task the caller built without one,
  /// which fails as [TransferErrorCode.localIo] when it runs.
  /// 文件在设备上的路径：上传从它读，下载向它写。只有调用方构造时未提供才为 null，
  /// 这样的任务在运行时会以 [TransferErrorCode.localIo] 失败。
  final String? localPath;

  /// Which way the bytes move.
  /// 字节搬运的方向。
  final TransferDirection direction;

  /// Total size in bytes, or null when it is not known yet.
  /// 总字节数；尚不可知时为 null。
  ///
  /// Filled in at enqueue time for an upload (the local file's length) and when
  /// the task starts for a download (the server's own size for the file). It
  /// stays null when the server reports no size and the local file could not be
  /// measured, and [progress] answers null with it.
  /// 上传在入队时填好（本地文件长度），下载在任务开始时填好（服务器给出的文件大小）。
  /// 当服务器不报大小、本地文件又量不出来时保持 null，此时 [progress] 也返回 null。
  final int? totalBytes;

  /// How many bytes have moved so far.
  /// 目前已经搬运的字节数。
  final int transferredBytes;

  /// Where the task is in its life.
  /// 任务在其生命周期中的位置。
  final TransferStatus status;

  /// Error code when [status] is [TransferStatus.failed]: either a `SftpFailure`
  /// name (`'read'`, `'write'`, `'connTimeout'`, …) or [TransferErrorCode].
  /// [status] 为 [TransferStatus.failed] 时的错误编码：要么是 `SftpFailure` 的名字
  /// （`'read'`、`'write'`、`'connTimeout'` 等），要么是 [TransferErrorCode]。
  final String? error;

  /// The underlying error's own rendering, when there is one — a protocol
  /// status, a socket error, never a sentence this app wrote. Hand it to
  /// `sftpFailureText` alongside [error] to get something a user can read.
  /// 底层错误自身的呈现（若存在）——协议状态、套接字错误，绝不是本应用写下的句子。
  /// 把它与 [error] 一起交给 `sftpFailureText`，就能得到用户可读的文字。
  final String? errorDetail;

  /// The staging root of the folder this download is part of, or null when it
  /// is a single file.
  ///
  /// A folder download is queued as ordinary per-file transfers — which is what
  /// gives each file its own row, its own cancel and its own retry — and this is
  /// the one thing that remembers they belong together. It is also where the
  /// staged tree lives, so the archive that delivers them is built from the same
  /// path the files were written to.
  final String? folderRoot;

  /// A name for that folder: the archive is named after it, and the row that
  /// offers to save it says which folder it is.
  final String? folderName;

  const TransferTask({
    required this.id,
    required this.hostId,
    required this.name,
    required this.remotePath,
    this.localPath,
    required this.direction,
    this.totalBytes,
    this.folderRoot,
    this.folderName,
    this.transferredBytes = 0,
    this.status = TransferStatus.queued,
    this.error,
    this.errorDetail,
  });

  /// Whether the task has stopped for good, whatever the reason.
  /// 任务是否已彻底停止，无论原因是什么。
  bool get isTerminal => switch (status) {
    TransferStatus.done ||
    TransferStatus.failed ||
    TransferStatus.cancelled => true,
    TransferStatus.queued || TransferStatus.running => false,
  };

  /// Fraction complete in the range 0..1, or null when it cannot be computed.
  /// 完成比例，取值 0..1；无法计算时为 null。
  ///
  /// Null is a real answer, not a failure: a server that reports no size for a
  /// file leaves [totalBytes] null, and so does a local file that could not be
  /// measured. The presentation layer must render that as an indeterminate
  /// indicator rather than as a 0 % bar, which is what a caller that naively
  /// divided would show.
  /// null 是真实答案，不是失败：服务器不报文件大小时 [totalBytes] 为 null，本地文件
  /// 量不出来时同样如此。展示层必须把它渲染成不确定态，而不是 0% 的进度条——那正是
  /// 直接做除法的调用方会显示的东西。
  ///
  /// Clamped at both ends: a server that sends more than the size it reported
  /// (a file still being appended to) must not push a progress bar past its end.
  /// 两端都做了钳制：服务器发出的字节多于它报告的大小时（文件仍在被追加），不能把
  /// 进度条推过终点。
  double? get progress {
    final total = totalBytes;
    if (total == null || total <= 0) return null;
    final ratio = transferredBytes / total;
    if (ratio.isNaN || ratio < 0) return 0;
    return ratio > 1 ? 1 : ratio;
  }

  /// A copy of this task with the given fields replaced.
  /// 以给定字段替换后的任务副本。
  ///
  /// [error] and [errorDetail] are cleared by passing [clearError], not by
  /// passing null: null already means "leave it alone" for every other nullable
  /// parameter here, and a caller that wants a stale diagnosis gone (a retry)
  /// has to be able to say so explicitly.
  /// 清除 [error] 与 [errorDetail] 要传 [clearError]，而不是传 null：在这里，对其余
  /// 每个可空参数而言 null 已经表示「保持不变」；而想要抹掉陈旧诊断的调用方（重试）
  /// 必须能明确表达这一点。
  TransferTask copyWith({
    int? totalBytes,
    int? transferredBytes,
    TransferStatus? status,
    bool clearError = false,
  }) {
    return TransferTask(
      id: id,
      hostId: hostId,
      name: name,
      remotePath: remotePath,
      localPath: localPath,
      direction: direction,
      totalBytes: totalBytes ?? this.totalBytes,
      folderRoot: folderRoot,
      folderName: folderName,
      transferredBytes: transferredBytes ?? this.transferredBytes,
      status: status ?? this.status,
      error: clearError ? null : error,
      errorDetail: clearError ? null : errorDetail,
    );
  }

  /// A copy of this task marked [status] and carrying a diagnosis.
  /// 标记为 [status] 并附带诊断信息的任务副本。
  TransferTask withError(String code, String? detail) {
    return TransferTask(
      id: id,
      hostId: hostId,
      name: name,
      remotePath: remotePath,
      localPath: localPath,
      direction: direction,
      totalBytes: totalBytes,
      folderRoot: folderRoot,
      folderName: folderName,
      transferredBytes: transferredBytes,
      status: TransferStatus.failed,
      error: code,
      errorDetail: detail,
    );
  }

  @override
  String toString() =>
      'TransferTask($name, ${direction.name}, ${status.name}, '
      '$transferredBytes/$totalBytes)';
}
