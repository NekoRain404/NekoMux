import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../models/credential.dart';
import '../models/transfer_task.dart';
import '../services/host_key_trust.dart';
import '../services/known_hosts_store.dart';
import '../services/sftp_service.dart';
import '../services/transfer_runner.dart';
import 'providers.dart';
import 'ssh_provider.dart';

// ---- Wiring / 接线 ----

/// Opens a transfer session for [hostId], or throws if it cannot.
/// 为 [hostId] 打开传输会话，打不开则抛出异常。
///
/// The port it returns is `TransferSession`, which lives in
/// `services/transfer_runner.dart` — import that file alongside this one.
/// 它返回的端口是 `TransferSession`，位于 `services/transfer_runner.dart`——使用时
/// 需要与本文件一起 import。
typedef TransferSessionFactory =
    Future<TransferSession> Function(String hostId);

/// Asks the user to accept a host key the queue has never seen before.
/// 就队列从未见过的主机密钥征求用户同意。
typedef TransferHostKeyPrompt =
    Future<bool> Function(String fingerprint, HostKeyVerdict verdict);

/// The queue's host-key policy, defaulting to "refuse, because there is nobody
/// to ask".
/// 队列的主机密钥策略，默认为「拒绝，因为无人可问」。
///
/// The queue connects from the background, with no page and no `BuildContext`,
/// so it cannot raise the dialog `pages/sftp_page.dart` raises. It must not
/// therefore skip verification either: `dartssh2` treats a null verify callback
/// as "trust anything", and six of the eight connection paths that predated
/// `services/host_key_trust.dart` did exactly that — see that file. Refusing is
/// the only honest answer available without a UI.
/// 队列在后台建立连接，既没有页面也没有 `BuildContext`，因此无法弹出
/// `pages/sftp_page.dart` 弹出的对话框。但它也绝不能因此跳过验证：`dartssh2` 把 null
/// 验证回调当作「无条件信任」，而 `services/host_key_trust.dart` 出现之前的八条连接
/// 路径里有六条正是这么做的——见该文件。在没有界面的情况下，拒绝是唯一诚实的答案。
///
/// This only ever fires for a host the user has never accepted a key for: an
/// already-trusted host returns from the store without consulting this. So the
/// ordinary case — transferring to a server the file manager has already
/// opened — is unaffected. Overriding this provider with a real prompt is how a
/// caller that *does* have a UI upgrades the refusal into a question.
/// 它只会在用户从未接受过该主机密钥时触发：已受信的主机会直接从存储返回，不会询问
/// 到这里。因此常见情形——向文件管理器已经打开过的服务器传输——不受影响。确实拥有
/// 界面的调用方可以通过覆盖本 provider 提供一个真正的询问，把拒绝升级为提问。
final transferHostKeyPromptProvider = Provider<TransferHostKeyPrompt>(
  (ref) =>
      (String fingerprint, HostKeyVerdict verdict) async => false,
);

/// Opens the session a queued transfer runs on.
/// 打开排队任务所运行的会话。
///
/// Overridden in tests with a fake, which is what lets the queue's decision logic
/// be tested without a server.
/// 测试中以假实现覆盖，这正是队列的决策逻辑能脱离服务器被测试的原因。
final transferSessionFactoryProvider = Provider<TransferSessionFactory>(
  (ref) =>
      (String hostId) => _openSftpSession(ref, hostId),
);

/// Minimum gap between two progress-only updates of the queue's state.
/// 队列状态两次「仅进度」更新之间的最小间隔。
///
/// See [TransferQueueNotifier] for why progress is coalesced and what happens to
/// the bytes that arrive between two publications.
/// 进度为何要合并、两次发布之间到达的字节去了哪里，见 [TransferQueueNotifier]。
final transferProgressIntervalProvider = Provider<Duration>(
  (ref) => const Duration(milliseconds: 120),
);

Future<TransferSession> _openSftpSession(Ref ref, String hostId) async {
  final hosts = await ref.read(hostListProvider.future);
  final host = hosts.where((h) => h.id == hostId).firstOrNull;
  if (host == null) {
    throw const SftpException(SftpFailure.connect, 'host not found');
  }

  final credentials = await ref.read(credentialListProvider.future);
  final credential = credentials
      .where((Credential c) => c.id == host.credentialId)
      .firstOrNull;
  if (credential == null) {
    throw const SftpException(SftpFailure.authFailed, 'credential not found');
  }

  // The accepted keys live in SQLite, so the verifier needs the database — the
  // same wiring, for the same reason, as the SFTP page's.
  // 已接受的密钥存放在 SQLite，因此验证器需要数据库——与 SFTP 页面相同的接线、
  // 相同的理由。
  final db = await ref.read(databaseProvider.future);
  final prompt = ref.read(transferHostKeyPromptProvider);

  final service = SftpService(
    host: host,
    credential: credential,
    // The user's own connect-timeout setting, honoured in full rather than
    // clamped: a queued transfer is a session the user asked for by tapping
    // "upload", not a background probe nobody is watching.
    // 用户自己的连接超时设置，完整遵循而不钳制：排队传输是用户点「上传」所请求的
    // 会话，而不是无人注视的后台探测。
    connectTimeout: ref.read(connectTimeoutProvider),
    onHostKeyVerify: buildHostKeyVerifier(
      db: db,
      address: host.ipAddress,
      port: host.port,
      onPrompt: prompt,
    ),
  );

  await service.connect();
  return SftpTransferSession(service);
}

// ---- Queue internals / 队列内部 ----

/// The per-host runtime state, deliberately outside the published task list.
/// 每台主机的运行期状态，刻意不放在对外发布的任务列表里。
///
/// None of it belongs in a widget: the session is a socket, and the pump flag is
/// a scheduling detail. Publishing them would make every progress tick look like
/// a change to something the UI can see.
/// 它们都不属于 widget：会话是一个套接字，泵标志是调度细节。发布它们会让每一次进度
/// 跳动都看起来像界面能看到的某个东西变了。
class _HostQueue {
  /// The live connection, opened lazily by the first task and released when the
  /// last one leaves.
  /// 活动连接，由第一个任务惰性打开，在最后一个任务离开时释放。
  TransferSession? session;

  /// Whether a pump loop is walking this host's queue.
  /// 是否有泵循环正在走这台主机的队列。
  bool pumpActive = false;
}

// ---- The queue / 队列 ----

/// Provider for the app-wide transfer queue.
/// 全局传输队列的 provider。
///
/// Deliberately **not** `autoDispose`: the whole point of this queue is that a
/// transfer outlives the page that started it. The SFTP page owns its own
/// connection and disposes it on pop; a queue built on that connection would die
/// with the page, and a 500 MB upload would die with it. This queue therefore
/// owns one connection per host instead, opened lazily and released when that
/// host's queue empties.
/// 刻意**不**使用 `autoDispose`：这条队列存在的全部意义，就是让传输比启动它的页面
/// 活得更久。SFTP 页面拥有自己的连接并在 pop 时销毁它；建立在那种连接上的队列会随
/// 页面一同死掉，一次 500 MB 的上传也会随之而死。因此本队列改为每台主机自拥一条连接，
/// 按需惰性打开，在该主机队列清空时释放。
final transferQueueProvider =
    NotifierProvider<TransferQueueNotifier, List<TransferTask>>(
      TransferQueueNotifier.new,
    );

/// The queue's state for one task, rebuilding only when *that* task changes.
/// 队列中某一个任务的状态，只在**该**任务变化时重建。
///
/// Watch this instead of [transferQueueProvider] from a row. The queue publishes
/// a whole new list whenever any task moves, so a widget watching the list
/// rebuilds on every other task's progress too; `select` narrows it to one task,
/// and `TransferTask` has no `==` override, so the comparison is by identity —
/// which is exactly right, because the queue only ever mints a new instance for
/// a task that actually changed.
/// 列表行请监听本 provider 而不是 [transferQueueProvider]。任何任务有动静，队列都会
/// 发布一整份新列表，因此监听列表的 widget 也会因别的任务的进度而重建；`select` 把它
/// 收窄到一个任务，而 `TransferTask` 没有覆写 `==`，比较因而是同一性比较——这恰好
/// 正确，因为队列只会为真正变化了的任务铸造新实例。
final transferTaskProvider = Provider.family<TransferTask?, String>((
  ref,
  taskId,
) {
  return ref.watch(
    transferQueueProvider.select(
      (tasks) => tasks.where((t) => t.id == taskId).firstOrNull,
    ),
  );
});

/// Runs queued transfers, one at a time per host, surviving page navigation.
/// 逐个执行排队中的传输（每台主机一次一个），并且不随页面导航而消失。
class TransferQueueNotifier extends Notifier<List<TransferTask>> {
  final Map<String, _HostQueue> _hosts = {};
  final Map<String, TransferCancelSignal> _running = {};

  /// Bytes reported since the last publication, waiting for the next one.
  /// 自上次发布以来报告的字节数，等待下一次发布。
  ///
  /// This map is what keeps a fast transfer from republishing the world: the
  /// callback writes here on every chunk, and only a publication drains it.
  /// 这张表正是让高速传输不至于反复重发布整个世界的东西：回调每收到一块就往这里写，
  /// 只有一次发布才会把它排空。
  final Map<String, int> _pendingBytes = {};

  /// When progress was last published for the whole queue.
  /// 上一次为整条队列发布进度的时间。
  ///
  /// Null means "publish the next one immediately", which is what makes the first
  /// chunk of every task visible at once instead of after one interval.
  /// null 表示「下一次立即发布」，正是它让每个任务的第一块数据当场可见，而不必等满
  /// 一个间隔。
  DateTime? _lastProgressPublish;

  static const Uuid _uuid = Uuid();

  @override
  List<TransferTask> build() {
    ref.onDispose(_shutdown);
    return const <TransferTask>[];
  }

  /// Whether the provider is still alive and may be written to.
  /// 该 provider 是否仍然存活、可以写入。
  ///
  /// The queue's work is asynchronous by nature and outlives the frame that
  /// started it, so every continuation has to ask: at app shutdown the container
  /// is disposed while a transfer may still be mid-flight, and `AnyNotifier.state`
  /// throws once it is. Reading the guard is cheaper than catching that.
  /// 队列的工作本质上是异步的，会比启动它的那一帧活得更久，因此每个后续都必须问一句：
  /// 应用关闭时容器会被销毁，而传输可能仍在进行，此时 `AnyNotifier.state` 会抛出异常。
  /// 读一次这个判断比捕获那个异常便宜。
  bool get _alive => ref.mounted;

  /// Stops everything this queue is doing, for disposal.
  /// 停止本队列正在做的一切，用于销毁。
  ///
  /// Cancelling first, then closing: a pump whose signal fired unwinds and
  /// reaches its own session release, and the sweep afterwards catches the
  /// sessions of hosts whose pump had already finished queuing but not yet let
  /// go.
  /// 先取消、后关闭：收到信号的泵会自行收尾并释放它自己的会话，之后的清扫则兜住那些
  /// 泵已排完队但尚未放手的会话。
  void _shutdown() {
    for (final signal in _running.values) {
      signal.cancel();
    }
    _running.clear();
    _closeEverySession();
  }

  // ---- Commands / 命令 ----

  /// Queues a transfer and starts the host's queue if it is idle.
  /// 排队一次传输；若该主机队列空闲则启动它。
  ///
  /// Synchronous on purpose: the task is appended before this returns, so two
  /// rapid calls can never be reordered by an `await` between them. A missing
  /// [totalBytes] is filled in when the task starts — measured from the local
  /// file for an upload, asked of the server for a download — never here, where
  /// there may not be a connection yet.
  /// 刻意设计为同步：任务在返回前就已入列，因此两次快速调用绝不会因为其间的一个
  /// `await` 而被重排。[totalBytes] 缺失时在任务开始时补齐——上传量本地文件，下载问
  /// 服务器——而不在这里补，因为此刻可能还没有连接。
  TransferTask enqueue({
    required String hostId,
    required String name,
    required String remotePath,
    String? localPath,
    required TransferDirection direction,
    int? totalBytes,
  }) {
    final task = TransferTask(
      id: _uuid.v4(),
      hostId: hostId,
      name: name,
      remotePath: remotePath,
      localPath: localPath,
      direction: direction,
      totalBytes: totalBytes,
    );
    state = <TransferTask>[...state, task];
    _kick(hostId);
    return task;
  }

  /// Queues an upload of [localPath] to [remotePath].
  /// 把 [localPath] 上传到 [remotePath] 的任务加入队列。
  TransferTask enqueueUpload({
    required String hostId,
    required String localPath,
    required String remotePath,
    String? name,
    int? totalBytes,
  }) {
    return enqueue(
      hostId: hostId,
      name: name ?? p.basename(localPath),
      remotePath: remotePath,
      localPath: localPath,
      direction: TransferDirection.upload,
      totalBytes: totalBytes,
    );
  }

  /// Queues a download of [remotePath] to [localPath].
  /// 把 [remotePath] 下载到 [localPath] 的任务加入队列。
  TransferTask enqueueDownload({
    required String hostId,
    required String remotePath,
    required String localPath,
    String? name,
    int? totalBytes,
  }) {
    return enqueue(
      hostId: hostId,
      // Remote paths are POSIX whatever the phone runs, so the name is taken
      // with POSIX rules rather than the host platform's.
      // 无论手机运行什么系统，远程路径都是 POSIX，因此取名用 POSIX 规则，而不是
      // 宿主平台的规则。
      name: name ?? p.posix.basename(remotePath),
      remotePath: remotePath,
      localPath: localPath,
      direction: TransferDirection.download,
      totalBytes: totalBytes,
    );
  }

  /// Stops [id]: a queued task is dropped from its place in line, a running one
  /// has its I/O cancelled.
  /// 停止 [id]：排队中的任务从队列里被移除，运行中的任务其 I/O 被取消。
  ///
  /// A dropped queued task is skipped by the pump, which is what stops it from
  /// ever starting. A running task is *not* marked cancelled here: the status
  /// flips when the I/O has actually stopped, so a row that says "cancelled" is
  /// never describing a transfer that is still writing.
  /// 被移除的排队任务会被泵跳过，这正是它永不启动的原因。运行中的任务**不**在这里
  /// 标记为已取消：状态在 I/O 真正停止时才翻转，因此写着「已取消」的行绝不会描述一次
  /// 仍在写入的传输。
  void cancel(String id) {
    final task = _taskById(id);
    if (task == null || task.isTerminal) return;

    if (task.status == TransferStatus.queued) {
      _replaceCurrent(id, (t) => t.copyWith(status: TransferStatus.cancelled));
      return;
    }
    _running[id]?.cancel();
  }

  /// Puts a finished task back in line with its byte count and diagnosis reset.
  /// 把一个已结束的任务放回队列，并重置其字节计数与诊断信息。
  ///
  /// It goes to the back of the list rather than jumping the queue, and it is a
  /// no-op for a task that has not stopped or no longer exists.
  /// 它排到列表末尾，不插队；对尚未停止或不复存在的任务是空操作。
  ///
  /// To the back, and not back to its old index, which is what the code used to
  /// do while this sentence said otherwise. The queue's whole contract is first
  /// enqueued, first run ([_nextQueued] scans in list order), and a retry is a new
  /// attempt at a transfer, not a continuation of the old one: keeping the index
  /// let a task the user retried overtake tasks that had been waiting longer, and
  /// the row visibly moves to the end of the sheet, so the list the user is
  /// looking at is the order things will actually run in.
  /// 排到末尾，而不是回到原来的位置——代码从前做的正是后者，而这句话说的是前者。队列的
  /// 全部契约就是先入队先运行（[_nextQueued] 按列表顺序扫描），而重试是对一次传输发起的
  /// **新**尝试，不是旧尝试的延续：保留原索引会让用户刚重试的任务超过等待更久的任务，
  /// 而该行在面板中确实会移到末尾，因此用户看到的那份列表就是实际的运行顺序。
  void retry(String id) {
    final task = _taskById(id);
    if (task == null || !task.isTerminal) return;
    _pendingBytes.remove(id);
    _moveToEnd(
      id,
      (t) => t.copyWith(
        status: TransferStatus.queued,
        transferredBytes: 0,
        clearError: true,
      ),
    );
    _kick(task.hostId);
  }

  /// Removes [id] from the list, cancelling it first if it is still going.
  /// 从列表移除 [id]；若它仍在进行，先取消它。
  ///
  /// A task removed while running keeps running only long enough to stop: the
  /// queue's later updates for an id that is no longer listed are no-ops, which
  /// is deliberate — the row is gone, and resurrecting it to report "cancelled"
  /// would be a row the user already dismissed.
  /// 运行中被移除的任务只会再运行到停住为止：队列随后针对一个已不在列表中的 id 所做的
  /// 更新都是空操作，这是刻意的——行已经消失，为了报告「已取消」而让它复活，只会变成
  /// 一行用户已经关掉的东西。
  void remove(String id) {
    cancel(id);
    state = state.where((t) => t.id != id).toList();
  }

  /// Removes every task that has stopped, whatever the reason.
  /// 移除所有已停止的任务，无论原因是什么。
  void clearFinished() {
    state = state.where((t) => !t.isTerminal).toList();
  }

  // ---- Scheduling / 调度 ----

  /// Starts this host's pump if it is not already running.
  /// 若该主机的泵尚未运行，启动它。
  void _kick(String hostId) {
    final queue = _hostFor(hostId);
    if (queue.pumpActive) return;
    queue.pumpActive = true;
    unawaited(_pump(hostId, queue));
  }

  /// Walks [hostId]'s queue until nothing is left to run, then releases the
  /// connection.
  /// 走完 [hostId] 的队列直到无任务可跑，然后释放连接。
  ///
  /// One task at a time, in list order — first enqueued, first run. Concurrency
  /// per host would not make the transfers faster (they share one SSH channel
  /// and one link) and would make every one of them slower.
  /// 一次一个，按列表顺序——先入队先运行。每台主机并发不会让传输更快（它们共用一条
  /// SSH 通道和一条链路），只会让每一个都更慢。
  Future<void> _pump(String hostId, _HostQueue queue) async {
    while (true) {
      final next = _nextQueued(hostId);
      if (next == null) break;
      await _run(hostId, queue, next);
    }

    // There is no `await` between the check above and these two lines, and Dart
    // runs them on one thread, so this is atomic with respect to [enqueue]: a
    // task enqueued during the loop is seen by the loop, and a task enqueued
    // after it opens its own session instead of racing this teardown.
    // 上面的判断与这两行之间没有 `await`，而 Dart 在单线程上运行它们，因此相对于
    // [enqueue] 而言这是原子的：循环期间入队的任务会被循环看到，循环之后入队的任务
    // 会自己新开一条会话，而不会与这次拆除相争。
    queue.pumpActive = false;
    final session = queue.session;
    queue.session = null;
    if (session != null) await _closeSession(session);
  }

  /// The oldest [TransferStatus.queued] task for [hostId], or null.
  /// [hostId] 最旧的 [TransferStatus.queued] 任务，没有则为 null。
  TransferTask? _nextQueued(String hostId) {
    // Returns null once the provider is gone, which ends the pump loop — the
    // only way a loop awaiting a transfer can learn that nobody is left to
    // report to.
    // provider 消失后返回 null，从而结束泵循环——这是正在等待传输的循环得知「已经没有
    // 对象可以汇报」的唯一途径。
    if (!_alive) return null;
    for (final task in state) {
      if (task.hostId == hostId && task.status == TransferStatus.queued) {
        return task;
      }
    }
    return null;
  }

  /// Runs one task to its end, whatever that end turns out to be.
  /// 把一个任务跑到它的终点，无论终点是什么。
  ///
  /// A failure here is contained: it marks this task failed and returns, so the
  /// pump moves on to the next one. That is the whole reason the queue is worth
  /// having — one unreachable file must not hold up the thirty behind it.
  /// 此处的失败被约束在任务内：把它标记为失败后返回，泵继续跑下一个。这正是这条队列
  /// 值得存在的理由——一个取不到的文件不该挡住它后面的三十个。
  Future<void> _run(String hostId, _HostQueue queue, TransferTask task) async {
    final signal = TransferCancelSignal();
    // Registered before the status flips, so a cancel that arrives the instant
    // the row starts moving has a signal to reach.
    // 在状态翻转之前注册，因此行刚开始动就到达的取消有一个信号可以触及。
    _running[task.id] = signal;
    _lastProgressPublish = null;
    _replaceCurrent(
      task.id,
      (t) => t.copyWith(status: TransferStatus.running, clearError: true),
    );

    try {
      if (signal.isCancelled) {
        _finish(task.id, TransferStatus.cancelled);
        return;
      }

      final TransferSession session;
      try {
        session = await _sessionFor(hostId, queue);
      } catch (e) {
        // The connection itself could not be opened, so this task cannot name a
        // transfer failure — `connect` is the honest code. It fails alone: the
        // next task tries again, because a queue that gave up on one refused
        // connection would turn a blip into a lost batch.
        // 连接本身打不开，因此本任务无法指认传输失败——`connect` 才是诚实的编码。
        // 它独自失败：下一个任务会再试一次，因为一次连接被拒就让整条队列放弃，会
        // 把一次抖动变成一批丢失。
        if (signal.isCancelled) {
          _finish(task.id, TransferStatus.cancelled);
        } else {
          _fail(task.id, e, SftpFailure.connect.name);
        }
        return;
      }

      final runner = TransferRunner(session);

      if (task.totalBytes == null) {
        final total = await runner.measure(_taskById(task.id) ?? task);
        if (total != null) {
          _replaceCurrent(
            task.id,
            (t) => t.totalBytes == null ? t.copyWith(totalBytes: total) : t,
          );
        }
      }

      if (signal.isCancelled) {
        _finish(task.id, TransferStatus.cancelled);
        return;
      }

      final outcome = await runner.move(
        _taskById(task.id) ?? task,
        signal,
        (bytes) => _reportProgress(task.id, bytes),
      );
      // From what the I/O did, not from the flag that asked it to stop. `_run`
      // holds `running` across the runner's `finally`, which is real file I/O —
      // cancelling the subscription, closing the sink — so a cancel that lands in
      // that window after the last byte arrived used to report a *complete* file
      // as cancelled, and the row's Save action is gated on `done`: the user lost
      // the only way to publish bytes that had all arrived.
      // 依据是 I/O 实际做了什么，而不是那个要求它停止的标志。`_run` 会在 runner 的
      // `finally` 期间保持 `running`，而那是真实的文件 I/O——取消订阅、关闭接收端——因此
      // 在最后一个字节到达之后落在这个窗口里的取消，此前会把一份**完整**的文件报成已取消，
      // 而该行的「保存」操作以 `done` 为前提：用户就此失去了交付全部已到达字节的唯一途径。
      _finish(
        task.id,
        outcome == TransferOutcome.completed
            ? TransferStatus.done
            : TransferStatus.cancelled,
      );
    } catch (e) {
      if (signal.isCancelled) {
        _finish(task.id, TransferStatus.cancelled);
      } else {
        _fail(task.id, e, _fallbackCode(task.direction));
      }
    } finally {
      signal.detach();
      _running.remove(task.id);
    }
  }

  /// The connection for [hostId], opening one if the queue has none.
  /// [hostId] 的连接；队列没有则打开一条。
  ///
  /// Lazily, on the first task that needs it: a queue that opened a connection
  /// when it was created would open one for every host the user ever queued
  /// something for, whether or not the transfer ever ran.
  /// 惰性打开，在第一个需要它的任务上：若在队列创建时就打开连接，用户曾为任何一台主机
  /// 排过任务就会为它开一条，无论那次传输是否真的跑过。
  Future<TransferSession> _sessionFor(String hostId, _HostQueue queue) async {
    final existing = queue.session;
    if (existing != null) return existing;
    final opened = await ref.read(transferSessionFactoryProvider)(hostId);
    queue.session = opened;
    return opened;
  }

  /// Records [bytes] for [id], publishing only when the last publication is old
  /// enough.
  /// 记录 [id] 的 [bytes]，且仅在距上次发布足够久时才发布。
  ///
  /// This is the answer to "progress must not rebuild the world": the callback
  /// runs per chunk, but it writes to [_pendingBytes] and returns, and only a
  /// publication builds a new list. Between publications nothing is allocated
  /// for the UI and no listener is notified. Both terminal transitions — [_finish]
  /// and [_fail] — carry whatever is still pending, so a coalesced-away value can
  /// never leave a stopped row showing less than it moved.
  /// 这就是「进度不得反复重建整个世界」的答案：回调按块运行，但它只写入
  /// [_pendingBytes] 就返回，只有发布才会构建新列表。两次发布之间不为界面分配任何东西，
  /// 也不通知任何监听者。终止跃迁会把仍然待发的值刷出去，因此被合并掉的值绝不会让一行
  /// 已结束的记录显示得比它实际搬运的少。
  void _reportProgress(String id, int bytes) {
    final task = _taskById(id);
    if (task == null || task.isTerminal) return;

    _pendingBytes[id] = bytes;

    final now = DateTime.now();
    final last = _lastProgressPublish;
    if (last != null &&
        now.difference(last) < ref.read(transferProgressIntervalProvider)) {
      return;
    }
    _lastProgressPublish = now;
    _flushProgress();
  }

  /// Publishes every pending byte count in one state write.
  /// 用一次状态写入发布所有待发的字节数。
  void _flushProgress() {
    if (_pendingBytes.isEmpty || !_alive) return;
    final updates = Map<String, int>.of(_pendingBytes);
    _pendingBytes.clear();

    final current = state;
    var changed = false;
    final next = List<TransferTask>.of(current);
    for (var i = 0; i < next.length; i++) {
      final bytes = updates[next[i].id];
      if (bytes == null || next[i].transferredBytes == bytes) continue;
      next[i] = next[i].copyWith(transferredBytes: bytes);
      changed = true;
    }
    if (changed) state = next;
  }

  /// Moves [id] to a terminal [status], carrying over its last byte count.
  /// 把 [id] 移到终止状态 [status]，并带上它最后的字节计数。
  void _finish(String id, TransferStatus status) {
    _lastProgressPublish = null;
    final pending = _pendingBytes.remove(id);
    _replaceCurrent(
      id,
      (t) => t.copyWith(
        status: status,
        transferredBytes: pending ?? t.transferredBytes,
      ),
    );
  }

  /// Moves [id] to [TransferStatus.failed] with a code and its raw detail.
  /// 把 [id] 移到 [TransferStatus.failed]，并附上编码与原始细节。
  ///
  /// The classification is by *where* the failure happened, which is the only
  /// distinction a user can act on: a server that refused is a `SftpFailure`
  /// with words already written for it, while a phone that could not read the
  /// file or write the destination is [TransferErrorCode.localIo] and nothing
  /// about the server is at fault. [fallback] covers only the unexpected, and
  /// names the operation that was being attempted.
  /// 分类依据是失败**发生在哪一侧**，这是用户唯一能据以行动的区别：服务器拒绝是
  /// `SftpFailure`，已经有现成的文字；而手机读不了文件或写不进目标是
  /// [TransferErrorCode.localIo]，服务器没有任何过错。[fallback] 只覆盖意外情形，
  /// 说出当时正在尝试的操作。
  void _fail(String id, Object error, String fallback) {
    _lastProgressPublish = null;
    // Carried over exactly as in [_finish], and for the same reason: the last
    // *published* count lags by up to one progress interval, so a transfer that
    // fails inside its last 120 ms used to be reported as having moved less than
    // it did — a row that failed while displaying a byte count it had already
    // passed. The bytes are real whether the transfer ended well or badly.
    // 与 [_finish] 完全相同的结转方式，理由也相同：最后一次**发布**的计数最多滞后一个
    // 进度间隔，因此在最后 120 ms 内失败的传输，此前会被报告为搬运得比实际少——一行失败
    // 的记录会显示一个它早已越过的字节数。无论传输结束得好还是坏，这些字节都是真实的。
    final pending = _pendingBytes.remove(id);

    final classified = error is SftpException
        ? error.kind.name
        : (error is TransferLocalIoException || error is FileSystemException)
        ? TransferErrorCode.localIo
        : fallback;
    final detail = error is SftpException ? error.detail : error.toString();
    _replaceCurrent(
      id,
      (t) => t
          .copyWith(transferredBytes: pending ?? t.transferredBytes)
          .withError(classified, detail),
    );
  }

  /// The code to fall back on for an unexpected failure moving bytes in
  /// [direction]: the operation that was actually attempted.
  /// [direction] 方向搬运字节时意外失败的兜底编码：实际尝试过的那个操作。
  String _fallbackCode(TransferDirection direction) =>
      direction == TransferDirection.upload
      ? SftpFailure.write.name
      : SftpFailure.read.name;

  // ---- State helpers / 状态辅助方法 ----

  TransferTask? _taskById(String id) {
    if (!_alive) return null;
    for (final task in state) {
      if (task.id == id) return task;
    }
    return null;
  }

  _HostQueue _hostFor(String hostId) =>
      _hosts.putIfAbsent(hostId, _HostQueue.new);

  void _replaceCurrent(String id, TransferTask Function(TransferTask) update) {
    if (!_alive) return;
    final current = state;
    final index = current.indexWhere((t) => t.id == id);
    if (index < 0) return;
    final next = List<TransferTask>.of(current);
    next[index] = update(current[index]);
    state = next;
  }

  /// Replaces [id] and moves it to the end of the list in one publication.
  /// 替换 [id] 并在同一次发布中把它移到列表末尾。
  ///
  /// One publication rather than two, so no listener ever sees the task gone from
  /// its old place before it exists in its new one — the sheet would drop the row
  /// for a frame.
  /// 一次发布而不是两次，因此任何监听者都不会看到「任务已离开原位但尚未出现在新位置」
  /// 的中间状态——面板会因此丢帧少画一行。
  void _moveToEnd(String id, TransferTask Function(TransferTask) update) {
    if (!_alive) return;
    final current = state;
    final index = current.indexWhere((t) => t.id == id);
    if (index < 0) return;
    final next = List<TransferTask>.of(current)
      ..removeAt(index)
      ..add(update(current[index]));
    state = next;
  }

  void _closeEverySession() {
    for (final queue in _hosts.values) {
      final session = queue.session;
      queue.session = null;
      if (session != null) unawaited(_closeSession(session));
    }
  }
}

// ---- Free helpers / 自由辅助方法 ----

/// Closes [session], swallowing whatever the teardown throws.
/// 关闭 [session]，忽略拆除过程中抛出的一切。
///
/// A close that throws must not become the reason a pump loop dies: the
/// connection is going away either way, and the tasks that already ran have
/// already reported their own outcomes.
/// 关闭时抛出的异常绝不能成为泵循环死掉的原因：连接反正都要消失，而已经跑过的任务
/// 早已各自上报了结果。
Future<void> _closeSession(TransferSession session) async {
  try {
    await session.close();
  } catch (_) {
    // Already gone / 已消失。
  }
}
