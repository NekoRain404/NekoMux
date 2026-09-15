// The three guards that keep a failed transfer from becoming a hung one.
// 让失败的传输不至于变成挂死传输的三道守护。
//
// All three exist for the same reason: a streaming transfer has exactly one
// observable state — bytes are moving, or they are not — and every way it can
// stop moving has to be turned into an *ending*, because the callers above
// (the transfer queue) hang on a future that never completes.
// 三道守护的理由相同：流式传输只有一种可观测状态——字节在移动，或者没有——而每一种
// 「不再移动」都必须被转成一个**结局**，因为上层的调用方（传输队列）会一直等在永不完成
// 的 future 上。
//
// They live here rather than in `sftp_service.dart` because that file is at its
// 800-line limit (`CLAUDE.md`), and because they are a unit of their own: the
// deadline and the teardown bound know about time, `guardedUploadSource` knows
// about streams, and the writer factory knows about dartssh2's writer. None of
// them knows any SFTP protocol.
// 它们放在这里而不是 `sftp_service.dart`，一是因为后者已到 800 行上限（`CLAUDE.md`），
// 二是因为它们本身就是一个单元：期限与拆除上界只认识时间，`guardedUploadSource` 只认识
// 流，写入器工厂只认识 dartssh2 的写入器。它们都不认识任何 SFTP 协议。

import 'dart:async';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

/// One acknowledged write chunk, in bytes: dartssh2's own write chunk size
/// (`sftp_stream_io.dart`, `chunkSize`).
/// 一个被确认的写入分块（字节）：dartssh2 自己的写入分块大小
/// （`sftp_stream_io.dart` 中的 `chunkSize`）。
///
/// This is what counts as a sign of life from a transfer: the write side reports
/// progress once per acknowledged chunk, and the read side once per chunk that
/// arrived. A whole chunk is the smallest unit either side can move, so a link
/// that cannot deliver one is a link that is not moving data.
/// 这就是一次传输「还活着」的最小证据：写入侧每确认一块报告一次进度，读取侧每到达一
/// 块报告一次。整块是两侧能搬运的最小单位，因此连一块都送不到的链路就是没有在搬运数据
/// 的链路。
const int transferStallChunkBytes = 16 * 1024;

/// The slowest link this app still calls alive, in bytes per second.
/// 本应用仍然认为「活着」的最慢链路，单位字节/秒。
///
/// A floor, not a measurement: something has to decide when silence means death,
/// and 2 KB/s is far below anything a user would call a working connection —
/// which is the safe direction, because the cost of being wrong here is a
/// transfer reported as failed that can simply be retried, while the cost of the
/// opposite mistake is a queue that never moves again.
/// 这是下限而非测量值：总得有人来判定沉默到什么时候算死亡，而 2 KB/s 远低于任何用户会
/// 称为「能用」的连接——这正是安全的方向：这里判错的代价是一次被报告为失败、重试即可的
/// 传输，而相反方向的错误代价是一条再也不动的队列。
const int transferStallFloorBytesPerSecond = 2048;

/// How long a transfer may go without moving a byte before it is called dead.
/// 一次传输在多少个字节都没动的情况下就被判定为死亡。
///
/// Derived, not picked: one acknowledged chunk is the smallest sign of life, and
/// at [transferStallFloorBytesPerSecond] that is 8 seconds. Thirty seconds is
/// nearly four of those, so a silence this long is not a slow link — it is a link
/// that has stopped, which on the upload side happens every time the server
/// rejects a write: dartssh2's writer then never completes its `done`, and
/// without this deadline the transfer never ends at all.
/// 这是推导出来的，不是随手挑的：一个被确认的分块就是最小的生命迹象，而在
/// [transferStallFloorBytesPerSecond] 下那是 8 秒。三十秒接近四个这样的间隔，因此沉默
/// 这么久不是慢链路——而是停住的链路；在上传侧，服务器每拒绝一次写入就会如此：dartssh2
/// 的写入器此后永远不会完成它的 `done`，没有这个期限，传输根本不会结束。
const Duration defaultTransferStallTimeout = Duration(seconds: 30);

/// Watches one transfer for silence, and can end the wait when it lasts too
/// long.
/// 监视一次传输的沉默，并在沉默过久时结束等待。
///
/// The unit it measures is the only thing observable in both cases worth
/// defending against — a write the server rejected and a connection that has gone
/// away — namely that no bytes move. It is deliberately *not* a total timeout: a
/// genuinely large upload over a genuinely slow link reports progress the whole
/// way, and every one of those reports pushes the deadline back.
/// 它度量的东西，是两种值得防御的情形——服务器拒绝写入、连接已经消失——中唯一可观测的
/// 共同点：没有任何字节移动。它刻意**不是**总超时：真正的大文件走真正慢的链路时全程都在
/// 报告进度，而每一次报告都会把期限往后推。
class TransferStallWatch {
  /// Creates a watch that tolerates [timeout] of silence.
  /// 创建一个容忍 [timeout] 沉默的监视器。
  TransferStallWatch(this.timeout);

  /// How long this watch tolerates silence.
  /// 本监视器容忍沉默的时长。
  final Duration timeout;

  Timer? _timer;

  /// The latch of the race currently in flight, or null when none is.
  /// 当前进行中的竞速所用的闩，没有则为 null。
  Completer<bool>? _latch;

  /// Records that bytes moved, pushing the deadline back by [timeout].
  /// 记录字节已经移动，把期限往后推 [timeout]。
  ///
  /// A no-op between races: when nothing is being waited for, there is nothing to
  /// time out.
  /// 在两次竞速之间是空操作：没有在等待的东西时，就没有会超时的东西。
  void progress() {
    final latch = _latch;
    if (latch == null || latch.isCompleted) return;
    _arm(latch);
  }

  /// Waits for [work], returning true when it finished and false when [timeout]
  /// passed with no [progress] in between.
  /// 等待 [work]：它完成时返回 true，其间没有任何 [progress] 而经过 [timeout] 时返回
  /// false。
  ///
  /// False is a real answer with a consequence attached, and it is why this
  /// returns a bool instead of throwing: [work] may still be pending when it is
  /// returned, and it must then be assumed **never** to complete. That is the
  /// shape of the failure this exists for — a write the server rejected leaves
  /// dartssh2's `done` pending forever — so the caller has to be able to stop
  /// feeding it and report a failure of its own.
  /// false 是一个带着后果的真实答案，也正是这里返回布尔值而不是抛异常的原因：返回时
  /// [work] 可能仍然悬挂，此时必须假定它**永远不会**完成。这正是本类所要应对的失败形态
  /// ——被服务器拒绝的写入会让 dartssh2 的 `done` 永远悬着——因此调用方必须有能力停止
  /// 供数并自行上报失败。
  ///
  /// An error from [work] is rethrown. An error that arrives *after* the deadline
  /// has fired is dropped rather than rethrown, which is also what keeps it from
  /// becoming an unhandled async error on a future nobody is left to await.
  /// [work] 抛出的错误会继续抛出。**在期限触发之后**才到达的错误会被丢弃而不是继续抛出，
  /// 这也正是它不会变成一个无人等待的 future 上的未处理异步错误的原因。
  Future<bool> race<T>(Future<T> work) async {
    final latch = Completer<bool>();
    _latch = latch;
    _arm(latch);
    work.then<void>(
      (_) {
        if (!latch.isCompleted) latch.complete(true);
      },
      onError: (Object error, StackTrace stack) {
        if (!latch.isCompleted) latch.completeError(error, stack);
      },
    );
    try {
      return await latch.future;
    } finally {
      _disarm(latch);
    }
  }

  /// Ends the watch. A deadline already in flight does nothing.
  /// 结束监视。已经在途的期限不会产生任何效果。
  void stop() {
    _latch = null;
    _timer?.cancel();
    _timer = null;
  }

  /// (Re)starts the deadline for [latch].
  /// 为 [latch]（重新）启动期限。
  void _arm(Completer<bool> latch) {
    _timer?.cancel();
    _timer = Timer(timeout, () {
      if (!latch.isCompleted) latch.complete(false);
    });
  }

  /// Drops the deadline owned by [latch], leaving a newer one alone.
  /// 撤销属于 [latch] 的期限，不干扰更新的那一个。
  void _disarm(Completer<bool> latch) {
    if (!identical(_latch, latch)) return;
    _latch = null;
    _timer?.cancel();
    _timer = null;
  }
}

/// A write dartssh2 has started, plus whatever its own listener reported.
/// dartssh2 已经启动的一次写入，以及它自己的监听器所报告的内容。
class GuardedSftpWrite {
  GuardedSftpWrite._();

  /// The writer, whose `done` means "every byte was acknowledged".
  /// 写入器；它的 `done` 表示「每一个字节都被确认了」。
  ///
  /// Late because the holder has to exist before the write starts: dartssh2's
  /// listener reports from a zone this object's handler runs in, and it needs
  /// somewhere to put what it reports.
  /// 用 late 是因为这个容器必须在写入开始**之前**存在：dartssh2 的监听器从本对象处理器
  /// 所在的 zone 中报告，而它需要一个地方存放所报告的内容。
  late final SftpFileWriter writer;

  /// What dartssh2's listener threw, or null if it threw nothing.
  /// dartssh2 的监听器抛出的东西；它什么都没抛时为 null。
  ///
  /// This is the server's own complaint, e.g. `SftpStatusError: Failure(code 4)`,
  /// and it arrives *here* only because the write was started inside the zone
  /// below — the future it lives on belongs to dartssh2 and nobody awaits it.
  /// 这是服务器自己的抱怨，例如 `SftpStatusError: Failure(code 4)`；它之所以能到达
  /// **这里**，只是因为写入是在下面那个 zone 中启动的——它所在的 future 属于 dartssh2，
  /// 没有任何人会去等待它。
  Object? rejected;

  /// Stops feeding the writer, so the source the caller handed over is released.
  /// 停止为写入器供数，从而释放调用方交过来的数据源。
  ///
  /// Safe to call at any time, including after the write finished normally: it
  /// completes the writer's own `done`, which throws if that already happened,
  /// and an abort that fails is not something a failing transfer can act on.
  /// 任何时候调用都安全，包括写入正常结束之后：它会去完成写入器自己的 `done`，而若那
  /// 已经发生过就会抛出；一次失败的 abort 不是一次失败的传输可以据以行动的。
  void abort() => unawaited(writer.abort().catchError((Object _) {}));
}

/// Starts [file].write([source]) in a zone that captures the error dartssh2's own
/// listener reports, so that a rejected write is never an *unhandled* async
/// error.
/// 在一个能捕获 dartssh2 自身监听器所报错误的 zone 中启动 [file].write([source])，
/// 使被拒绝的写入永远不会成为**未处理**的异步错误。
///
/// Why any of this is needed: `SftpFileWriter._handleLocalData` is an async
/// listener nobody awaits, so a rejected `writeBytes` throws into a future with
/// no listener — an unhandled async error, one per chunk, and (worse) a write
/// whose `_bytesAcked` never catches up with `_bytesSent`, which means its `done`
/// never completes no matter what the caller does. Nothing on this side can catch
/// that error, because the future is dartssh2's; the zone can, and that is also
/// what makes the server's own words available as a diagnosis instead of a
/// sentence this app invented.
/// 为什么需要这些：`SftpFileWriter._handleLocalData` 是一个无人等待的异步监听器，
/// 因此被拒绝的 `writeBytes` 会在一个没有监听者的 future 中抛出——每块一个未处理的异步
/// 错误——更糟的是，这次写入的 `_bytesAcked` 再也追不上 `_bytesSent`，意味着无论调用方
/// 做什么，它的 `done` 都不会完成。这一侧捕获不到那个错误，因为 future 属于 dartssh2；
/// 但 zone 可以，而这也正是服务器的原话（而非本应用编造的句子）能作为诊断出现的原因。
///
/// Only the writer's own listener runs in the forked zone — it is created here —
/// so nothing else in the transfer loses its error handler to it.
/// 只有写入器自己的监听器在那个 fork 出来的 zone 中运行——它是在这里创建的——因此传输
/// 中其它任何东西都不会因此失去自己的错误处理器。
GuardedSftpWrite startGuardedSftpWrite(
  SftpFile file,
  Stream<Uint8List> source, {
  void Function(int bytesWritten)? onProgress,
}) {
  final write = GuardedSftpWrite._();
  final zone = Zone.current.fork(
    specification: ZoneSpecification(
      handleUncaughtError: (self, parent, childZone, error, stack) {
        write.rejected ??= error;
      },
    ),
  );
  write.writer = zone.run(() => file.write(source, onProgress: onProgress));
  return write;
}

/// Finishes [teardown] — a close, a subscription cancel — swallowing what it
/// throws and giving up on the wait after [timeout].
/// 完成 [teardown]——一次关闭、一次订阅取消——忽略它抛出的一切，并在
/// [timeout] 之后放弃等待。
///
/// The bound is load-bearing rather than defensive. A CLOSE, and a cancel that
/// has to reach the server, are one more request each over the same connection,
/// so on a connection that has stopped answering they are requests that never
/// come back; an unbounded wait would hold a stall failure inside a `finally`
/// forever, which is precisely the hang the caller was being rescued from.
/// Giving up does not lose the work — the packet is sent either way — it only
/// gives up on the acknowledgement.
/// 这个上界是承重的，不是防御性的。一次 CLOSE，以及一次必须到达服务器的取消，都只是同
/// 一条连接上的又一个请求，因此在一条已不再回应的连接上，它们就是永远回不来的请求；无
/// 上界地等待会让一次停滞失败永远留在 `finally` 里——而那恰恰是调用方正被从中解救出来的
/// 那种挂死。放弃并不丢失这次动作——数据包无论如何都发出去了——放弃的只是确认。
///
/// Each teardown is passed in on its own rather than as a list, so that one
/// objecting cannot skip the next: the download has both a reader to cancel and a
/// handle to close, and the handle still has to be closed when the reader's
/// cancel is the thing that threw.
/// 每次收尾都单独传入而不是打包成一个列表，这样其中一次提出异议就不会让下一次被跳过：
/// 下载既有要取消的读取方，也有要关闭的句柄，而当前者正是抛出的那一方时，句柄仍然必须
/// 被关闭。
Future<void> boundedTeardown(
  Future<void>? teardown, {
  Duration timeout = defaultTeardownTimeout,
}) async {
  if (teardown == null) return;
  try {
    await teardown.timeout(timeout, onTimeout: () {});
  } catch (_) {
    // Already gone / 已不存在。
  }
}

/// Finishes one piece of a transfer's teardown, waiting for it unless the
/// transfer stalled.
/// 完成一次传输收尾中的一步；除非传输已经停滞，否则等待它。
///
/// A stall means the connection has stopped answering, and every teardown step
/// is one more request over that connection: awaiting them would delay the
/// report of the failure by the very timeouts that exist to make it reportable
/// — with a two-second stall and the five-second bound below, a download against
/// a server behind a link that had stopped forwarding packets took 10.2 s to
/// report instead of 2.3 s. So on that path
/// the teardown is started and left to finish on its own. It is exactly the
/// same call, so the CLOSE still goes out and the handle is still released;
/// what is dropped is only the wait for an acknowledgement nobody is waiting
/// for.
/// 停滞意味着连接已经不再回应，而收尾的每一步都是这条连接上的又一个请求：等待它们会让
/// 失败的上报被「正是为了让失败可上报而存在的那些超时」推迟——在 2 秒停滞、上界 5 秒的
/// 设置下，对一台位于「停止转发数据包的链路」之后的服务器实测：失败要 10.2 秒才上报，
/// 而不是 2.3 秒。因此在这条路径上，收尾只被
/// 启动，然后由它自行完成。调用的还是同一个调用，因此 CLOSE 照样发出、句柄照样释放；
/// 被放弃的只是对一个已经无人等待的确认的等待。
Future<void> finishTeardown(Future<void>? work, {required bool stalled}) async {
  if (!stalled) {
    await boundedTeardown(work);
    return;
  }
  unawaited(boundedTeardown(work));
}

/// How long a teardown waits for a CLOSE (or for a cancel that has to reach the
/// server) to be acknowledged.
/// 拆除时等待 CLOSE（或必须到达服务器的取消）被确认的时长。
///
/// One round trip, and nothing more: a CLOSE carries no data, so even a satellite
/// link answers it inside a second. It exists so that a connection which has
/// stopped answering at all cannot hold a failure inside a `finally`. It is a
/// parameter of [boundedTeardown] as well as a constant, so a test can drive the
/// giving-up in milliseconds.
/// 一次往返，仅此而已：CLOSE 不携带数据，即便是卫星链路也会在一秒内答复。它存在的意义，
/// 是让一条完全不回应的连接无法把一次失败留在 `finally` 里。它既是常量，也是
/// [boundedTeardown] 的参数，好让测试能以毫秒为单位驱动「放弃」。
const Duration defaultTeardownTimeout = Duration(seconds: 5);

/// [source] with any error reported to [onError] and then turned into an ordinary
/// end of stream.
/// 把 [source] 的错误报告给 [onError] 后，转成一次普通的流结束。
///
/// An `async*` body wrapping `await for` is the only shape that both keeps
/// backpressure (a paused consumer pauses [source], which is what a plain
/// `handleError` would give up) and guarantees the output stream *ends* rather
/// than erroring — and ending is the point: dartssh2's writer installs no error
/// handler on the stream it is given, so an error would hang that write instead
/// of failing it.
/// 用 `async*` 包住 `await for` 是唯一同时满足两件事的写法：既保住背压（消费者暂停会
/// 暂停 [source]，而朴素地用 `handleError` 会丢掉这一点），又保证输出流*结束*而不是
/// 报错——而「结束」正是关键：dartssh2 的写入器没有为它收到的流安装错误处理，因此错误
/// 会让那次写入挂死而不是失败。
Stream<Uint8List> guardedUploadSource(
  Stream<Uint8List> source,
  void Function(Object error) onError,
) async* {
  try {
    await for (final chunk in source) {
      yield chunk;
    }
  } catch (e) {
    onError(e);
  }
}
