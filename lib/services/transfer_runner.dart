import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../models/transfer_task.dart';
import 'sftp_service.dart';

/// The two streaming operations a transfer needs from a connected host, plus a
/// way to let it go.
/// 一次传输需要从一台已连接主机获得的两个流式操作，外加释放它的方法。
///
/// It is deliberately the narrowest interface the byte-moving needs: an
/// [SftpService] has a dozen other members and none of them are used here. It is
/// also the seam the queue's tests replace, which is what lets ordering,
/// failure and cancellation be tested without a socket.
/// 它刻意只包含搬运字节所需的最小接口：[SftpService] 另有十来个成员，这里一个都不用。
/// 它也是队列测试所替换的接缝，正是它让顺序、失败与取消无需套接字即可被测试。
///
/// The cancellation contract is the one [SftpService] documents: closing the
/// stream handed to [upload] stops an upload, and cancelling the subscription to
/// the stream returned by [download] stops a download.
/// 取消契约就是 [SftpService] 所记载的那一条：关闭交给 [upload] 的流即可停止上传，
/// 取消 [download] 返回的流的订阅即可停止下载。
abstract class TransferSession {
  /// Size of the remote file at [path] in bytes, or null when unknown.
  /// [path] 路径下远程文件的大小（字节），未知时为 null。
  Future<int?> size(String path);

  /// Streams the remote file at [path] in chunks.
  /// 以分块方式流式读取 [path] 路径下的远程文件。
  Stream<Uint8List> download(
    String path, {
    void Function(int bytesRead)? onProgress,
  });

  /// Writes [data] to the remote file at [path].
  /// 将 [data] 写入 [path] 路径下的远程文件。
  Future<void> upload(
    String path,
    Stream<Uint8List> data, {
    void Function(int bytesWritten)? onProgress,
  });

  /// Releases the connection behind this session.
  /// 释放本会话背后的连接。
  Future<void> close();
}

/// A [TransferSession] backed by a real SSH/SFTP connection.
/// 由真实 SSH/SFTP 连接支持的 [TransferSession]。
class SftpTransferSession implements TransferSession {
  SftpTransferSession(this.service);

  /// The connected service this session drives.
  /// 本会话所驱动的已连接服务。
  final SftpService service;

  @override
  Future<int?> size(String path) => service.fileSize(path);

  @override
  Stream<Uint8List> download(
    String path, {
    void Function(int bytesRead)? onProgress,
  }) => service.downloadStream(path, onProgress: onProgress);

  @override
  Future<void> upload(
    String path,
    Stream<Uint8List> data, {
    void Function(int bytesWritten)? onProgress,
  }) => service.uploadStream(path, data, onProgress: onProgress);

  @override
  Future<void> close() => service.disconnect();
}

/// The signal a running transfer watches for "the user asked you to stop".
/// 运行中的传输用来监听「用户要求你停下」的信号。
///
/// The smallest shape that stops I/O: one flag and one callback. The callback is
/// set by whichever side owns the byte stream, and it is *that* side's job to
/// cancel a subscription or close a source — the flag itself moves no bytes. A
/// single slot rather than a listener list because exactly one consumer exists
/// by construction: the transfer that is running.
/// 能停住 I/O 的最小形态：一个标志加一个回调。回调由拥有字节流的那一方设置，而取消
/// 订阅或关闭数据源正是**那一方**的职责——标志本身不搬运任何字节。用单个槽位而不是
/// 监听器列表，是因为按构造就只有一个消费者：正在运行的那次传输。
class TransferCancelSignal {
  bool _cancelled = false;

  /// Invoked once, synchronously, when [cancel] is first called.
  /// 首次调用 [cancel] 时同步调用一次。
  void Function()? onCancel;

  /// Whether stopping has been requested.
  /// 是否已请求停止。
  bool get isCancelled => _cancelled;

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    onCancel?.call();
  }

  /// Drops the callback once the transfer it belonged to has stopped, so a late
  /// [cancel] cannot reach into a finished one.
  /// 传输停止后丢弃回调，使迟到的 [cancel] 无法触及已结束的传输。
  void detach() => onCancel = null;
}

/// A failure on the device's side of a transfer: no local path, an unreadable
/// source, an unwritable destination.
/// 传输中设备一侧的失败：没有本地路径、源不可读、目标不可写。
///
/// Distinct from [SftpException] on purpose. The two are the only distinction a
/// user can act on — "the server refused" and "your phone could not" call for
/// different things — and the queue maps them to different codes.
/// 有意与 [SftpException] 区分。这两者是用户唯一能据以行动的区别——「服务器拒绝」与
/// 「你的手机做不到」需要不同的应对——队列会把它们映射成不同的编码。
class TransferLocalIoException implements Exception {
  const TransferLocalIoException(this.detail);

  /// The underlying error's own rendering, never a sentence this app wrote.
  /// 底层错误自身的呈现，绝不是本应用写下的句子。
  final String detail;

  @override
  String toString() => detail;
}

/// Moves one task's bytes, and can be stopped part way.
/// 搬运一个任务的字节，并且可以中途停止。
///
/// This is the whole of the queue that touches a file: everything above it —
/// ordering, one at a time per host, what happens after a failure, when the
/// connection is released — is decision-making that needs no socket, and lives
/// in `providers/transfer_provider.dart`.
/// 这是队列中唯一接触文件的部分：它之上的一切——顺序、每台主机一次一个、失败之后如何、
/// 何时释放连接——都是不需要套接字的决策，位于 `providers/transfer_provider.dart`。
///
/// Cancellation is arranged by the caller through [signal], and it is real rather
/// than cosmetic in both directions — see [upload] and [download].
/// 取消由调用方经由 [signal] 安排，且两个方向都是真停而非表面功夫——见 [upload] 与
/// [download]。
class TransferRunner {
  const TransferRunner(this.session);

  /// The connection the bytes travel over.
  /// 字节所经的连接。
  final TransferSession session;

  /// The size to divide by for [task], or null when it cannot be established.
  /// [task] 用作分母的大小；无法确定时为 null。
  ///
  /// Null is a supported answer, not a failure: a server that reports no size
  /// leaves the download indeterminate, and a local file that cannot be measured
  /// leaves the upload indeterminate. Neither is a reason to refuse the
  /// transfer, so neither throws.
  /// null 是受支持的答案而非失败：服务器不报大小时下载就是不定的，本地文件量不出来时
  /// 上传就是不定的。两者都不是拒绝传输的理由，因此都不抛出。
  Future<int?> measure(TransferTask task) async {
    try {
      if (task.direction == TransferDirection.upload) {
        final localPath = task.localPath;
        return localPath == null ? null : await File(localPath).length();
      }
      return await session.size(task.remotePath);
    } catch (_) {
      return null;
    }
  }

  /// Moves the bytes for [task] in whichever direction it goes.
  /// 按 [task] 的方向搬运字节。
  Future<void> move(
    TransferTask task,
    TransferCancelSignal signal,
    void Function(int bytes) onProgress,
  ) {
    return switch (task.direction) {
      TransferDirection.upload => upload(task, signal, onProgress),
      TransferDirection.download => download(task, signal, onProgress),
    };
  }

  /// Reads the local file and feeds it to the server.
  /// 读取本地文件并喂给服务器。
  ///
  /// A controller is interposed rather than `openRead()` being handed straight to
  /// the service, because stopping an upload means *closing the source*, and only
  /// the side that owns the stream can do that. Closing it ends dartssh2's
  /// `done`, which closes the server-side handle — so a cancelled upload releases
  /// its handle instead of leaving a half-open one behind.
  /// 这里插入一个控制器，而不是把 `openRead()` 直接交给服务，因为停止上传意味着
  /// **关闭数据源**，而只有拥有该流的一方才能做到。关闭它会结束 dartssh2 的 `done`，
  /// 从而关闭服务器端句柄——因此被取消的上传会释放句柄，而不是留下一个半开的。
  ///
  /// The initial pause is what keeps the whole file out of memory: without it the
  /// controller would buffer every chunk the file system could produce while the
  /// SFTP channel is still being opened.
  /// 最初的暂停正是让整个文件不进内存的原因：没有它，控制器会在 SFTP 通道仍在打开时
  /// 缓冲文件系统能吐出的每一块。
  Future<void> upload(
    TransferTask task,
    TransferCancelSignal signal,
    void Function(int bytesWritten) onProgress,
  ) async {
    final localPath = task.localPath;
    if (localPath == null) {
      throw const TransferLocalIoException('upload has no local path');
    }

    final controller = StreamController<Uint8List>();
    Object? readError;
    final source = File(localPath).openRead().listen(
      (chunk) => controller.add(_asBytes(chunk)),
      onDone: () => _closeController(controller),
      onError: (Object e, StackTrace _) {
        // Never forwarded to the controller. dartssh2's writer installs no error
        // handler on the stream it is given: an error would be an unhandled async
        // error *and* leave `done` pending forever, hanging this host's whole
        // queue. Closing the stream ends the write; the cause is rethrown below,
        // once the upload has unwound.
        // 绝不转发给控制器。dartssh2 的写入器没有为它收到的流安装错误处理：错误会
        // 变成未处理的异步错误，**并且**让 `done` 永远悬着，把该主机的整条队列挂死。
        // 关闭这条流即可结束写入；原因在上传收尾之后于下方重新抛出。
        readError = e;
        _closeController(controller);
      },
      cancelOnError: true,
    );

    // Nothing is read until the writer subscribes, and reading stops again
    // whenever the writer applies backpressure.
    // 在写入器订阅之前不读任何东西，写入器施加背压时读取再次停止。
    source.pause();
    controller
      ..onListen = source.resume
      ..onPause = source.pause
      ..onResume = source.resume
      ..onCancel = source.cancel;

    signal.onCancel = () => unawaited(_stopUpload(source, controller));

    try {
      await session.upload(
        task.remotePath,
        controller.stream,
        onProgress: onProgress,
      );
    } finally {
      signal.onCancel = null;
      await source.cancel();
      _closeController(controller);
    }

    if (readError != null) {
      throw TransferLocalIoException(readError.toString());
    }
  }

  /// Writes the server's bytes to the local file.
  /// 把服务器发来的字节写入本地文件。
  ///
  /// Cancelling the subscription is the stop, and it is a real one: the service's
  /// generator runs its `finally` on cancellation, which closes the `SftpFile` —
  /// no further READ is issued and no handle is left open.
  /// 取消订阅就是停止动作，而且是真正的停止：服务的生成器在取消时会执行其 `finally`，
  /// 关闭 `SftpFile`——不会再发出 READ，也不会留下打开的句柄。
  Future<void> download(
    TransferTask task,
    TransferCancelSignal signal,
    void Function(int bytesRead) onProgress,
  ) async {
    final localPath = task.localPath;
    if (localPath == null) {
      throw const TransferLocalIoException('download has no local path');
    }

    final sink = File(localPath).openWrite();
    final finished = Completer<void>();
    StreamSubscription<Uint8List>? subscription;

    signal.onCancel = () {
      if (!finished.isCompleted) finished.complete();
    };

    try {
      final stream = session.download(task.remotePath, onProgress: onProgress);
      subscription = stream.listen(
        sink.add,
        onError: (Object e, StackTrace st) {
          if (!finished.isCompleted) finished.completeError(e, st);
        },
        onDone: () {
          if (!finished.isCompleted) finished.complete();
        },
        cancelOnError: true,
      );

      // Either the stream ended or the user asked it to stop; both arrive here,
      // so there is exactly one place the transfer can unwind from.
      // 要么流结束了，要么用户要求停止；两者都汇到这里，因此传输只有一处收尾。
      await finished.future;
    } finally {
      signal.onCancel = null;
      // Unconditional: after a cancellation this is what stops the read, and
      // after a normal end it is a no-op.
      // 无条件执行：取消之后，正是它停住了读取；正常结束之后，它是空操作。
      await subscription?.cancel();
      // Surfaces a disk-full or permission failure. On success it is just the
      // flush.
      // 让磁盘写满或权限失败浮现出来。成功时它只是刷盘。
      await sink.close();
    }
  }
}

/// Ends [controller]'s stream, unless it has already ended.
/// 结束 [controller] 的流，除非它已经结束。
///
/// Called from three places that can coincide — the source ending, the source
/// erroring, and the transfer being cancelled — so it is safe to call twice,
/// which `close()` on a closed controller already is.
/// 有三处会调用它，且这三处可能同时发生——数据源结束、数据源出错、传输被取消——
/// 因此它可以安全地重复调用，而对已关闭的控制器调用 `close()` 本就如此。
///
/// Deliberately synchronous, and deliberately *not* awaiting `close()`'s future —
/// that future completes only once the done event has been **delivered**, and a
/// controller nobody ever subscribed to never delivers it. That is not a corner
/// case: when the server refuses the open, `uploadStream` throws before it ever
/// attaches a writer, so the whole `finally` that stops an upload would otherwise
/// hang, taking this host's entire queue with it. The close still happens; only
/// the waiting for a listener that may not exist is dropped.
/// 刻意做成同步，且刻意**不**等待 `close()` 的 future——它只在 done 事件被**投递**后
/// 才完成，而一个从未有人订阅过的控制器永远不会投递。这不是边角情形：当服务器拒绝打开
/// 时，`uploadStream` 在接入写入器之前就抛出了，于是停止上传的整个 `finally` 就会挂住，
/// 并把该主机的整条队列一起拖住。关闭照常发生，被去掉的只是「等待一个可能并不存在的
/// 监听者」。
void _closeController(StreamController<Uint8List> controller) {
  if (controller.isClosed) return;
  unawaited(controller.close());
}

/// Stops an upload by closing its source.
/// 通过关闭数据源来停止上传。
Future<void> _stopUpload(
  StreamSubscription<List<int>> source,
  StreamController<Uint8List> controller,
) async {
  await source.cancel();
  _closeController(controller);
}

/// [chunk] as a [Uint8List], copying only if it is not one already.
/// 把 [chunk] 转成 [Uint8List]，本来就是则不再复制。
Uint8List _asBytes(List<int> chunk) =>
    chunk is Uint8List ? chunk : Uint8List.fromList(chunk);
