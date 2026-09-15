// Detecting the one transfer failure that cannot be told from a hang: nothing
// moving.
// 识别那一种与卡死无法区分的传输失败：没有任何东西在移动。
//
// It lives on its own so `sftp_service.dart` stays under the 800-line limit
// (`CLAUDE.md`), and because it is a unit with no SFTP protocol knowledge in it
// at all: it knows about intervals and futures, not packets.
// 它单独成文件，一是让 `sftp_service.dart` 保持在 800 行以内（`CLAUDE.md`），
// 二是因为它是一个完全不包含 SFTP 协议知识的单元：它只认识时间间隔和 future，
// 不认识任何数据包。

import 'dart:async';

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
/// transfer that is reported as failed and can simply be retried, while the cost
/// of the opposite mistake is a queue that never moves again.
/// 这是一个下限，不是一次测量：总得有人来判定沉默到什么时候算死亡，而 2 KB/s 远低于
/// 任何用户会称为「能用」的连接——这正是安全的方向：判错的代价是一次被报告为失败、
/// 重试即可的传输，而相反的错误的代价是一条再也不动的队列。
const int transferStallFloorBytesPerSecond = 2048;

/// How long a transfer may go without moving a byte before it is called dead.
/// 一次传输在多少个字节都没动的情况下就被判定为死亡。
///
/// Derived, not picked: one acknowledged chunk is the smallest sign of life, and
/// at [transferStallFloorBytesPerSecond] that is 8 seconds. Thirty seconds is
/// nearly four of those, so a silence this long is not a slow link — it is a
/// link that has stopped, which on the upload side happens every time the server
/// rejects a write: dartssh2's writer then never completes its `done`, and
/// without this deadline the transfer never ends at all. See
/// `services/sftp_service.dart` for what fires it.
/// 这是推导出来的，不是随手挑的：一个被确认的分块就是最小的生命迹象，而在
/// [transferStallFloorBytesPerSecond] 下那是 8 秒。三十秒接近四个这样的间隔，因此
/// 沉默这么久不是慢链路——而是停住的链路；在上传侧，每当服务器拒绝一次写入就会发生
/// 这种情况：dartssh2 的写入器此后永远不会完成它的 `done`，没有这个期限，传输根本
/// 不会结束。触发它的位置见 `services/sftp_service.dart`。
const Duration defaultTransferStallTimeout = Duration(seconds: 30);

/// Watches one transfer for silence, and can end the wait when it lasts too
/// long.
/// 监视一次传输的沉默，并在沉默过久时结束等待。
///
/// The unit it measures is the only thing that is observable in both cases worth
/// defending against — a write the server rejected and a connection that has
/// gone away — namely that no bytes move. It is deliberately *not* a total
/// timeout: a genuinely large upload over a genuinely slow link reports progress
/// the whole way, and every one of those reports pushes the deadline back.
/// 它度量的东西，是两种值得防御的情形——服务器拒绝写入、连接已经消失——中唯一可观测
/// 的共同点：没有任何字节移动。它刻意**不是**总超时：真正的大文件走真正慢的链路时全程
/// 都在报告进度，而每一次报告都会把期限往后推。
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
  /// A no-op between races: when nothing is being waited for, there is nothing
  /// to time out.
  /// 在两次竞速之间是空操作：没有在等待的东西时，就没有会超时的东西。
  void progress() {
    final latch = _latch;
    if (latch == null || latch.isCompleted) return;
    _arm(latch);
  }

  /// Waits for [work], returning true when it finished and false when [timeout]
  /// passed with no [progress] in between.
  /// 等待 [work]：它完成时返回 true，其间没有任何 [progress] 而经过 [timeout] 时
  /// 返回 false。
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
  /// [work] 抛出的错误会继续抛出。**在期限触发之后**才到达的错误会被丢弃而不是继续
  /// 抛出，这也正是它不会变成一个无人等待的 future 上的未处理异步错误的原因。
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

  /// Ends the watch. A deadline that is already in flight does nothing.
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
