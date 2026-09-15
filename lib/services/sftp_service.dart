import 'dart:typed_data';
import 'package:dartssh2/dartssh2.dart';
import '../models/host.dart';
import '../models/credential.dart';
import '../models/file_item.dart';
import 'host_key_verifier.dart';
import 'ssh_service.dart';

/// SFTP file browser backed by dartssh2's SSH/SFTP protocol implementation.
/// 基于 dartssh2 的 SSH/SFTP 协议实现的 SFTP 文件浏览器。
///
/// Provides list, read, write, delete, rename, and mkdir operations
/// over an authenticated SSH transport.
/// 在已认证的 SSH 传输层上提供列表、读取、写入、删除、重命名和创建目录操作。
class SftpService {
  /// Target host configuration.
  /// 目标主机配置。
  final Host host;

  /// Credential used for SSH authentication.
  /// 用于 SSH 认证的凭据。
  final Credential credential;

  /// Underlying dartssh2 client.
  /// 底层 dartssh2 客户端。
  SSHClient? _client;

  /// Active SFTP client session.
  /// 当前活动的 SFTP 客户端会话。
  SftpClient? _sftp;

  /// Epoch of the current connect attempt.
  /// Bumped when an attempt starts, and by [disconnect] to invalidate an
  /// attempt that is still suspended on an `await`. Its continuation re-checks
  /// the epoch and, when it no longer matches, closes whatever it just created
  /// instead of publishing it.
  /// 当前连接尝试的世代号。
  /// 新尝试开始时自增，[disconnect] 也会自增，用于作废仍挂起在 `await` 上的
  /// 尝试；其后续代码会发现世代号不再匹配，从而关闭刚创建的资源，而不是把它
  /// 发布出去。
  int _connectEpoch = 0;

  /// Optional host key verification callback.
  final Future<bool> Function(String fingerprint)? onHostKeyVerify;

  /// Connect timeout applied when a caller does not pass one.
  /// 调用方未传入时采用的连接超时。
  ///
  /// This is a *fallback*, not the user's setting. Settings → connect timeout is
  /// read where the connection is built (see `connectTimeoutProvider` in
  /// `providers/ssh_provider.dart`) and passed in explicitly, so the SFTP page
  /// honours the number the user chose while anything not wired behaves exactly
  /// as it did before that provider existed. It is [SshConnection]'s own
  /// fallback rather than a second copy of the number, so the two connection
  /// paths cannot drift apart.
  /// 这是**兜底值**，不是用户的设置。「设置 → 连接超时」在构造连接处读取
  /// （见 `providers/ssh_provider.dart` 中的 `connectTimeoutProvider`）并显式传入，
  /// 因此 SFTP 页面遵循用户选定的数字，而未接线的路径与该 provider 出现之前完全一致。
  /// 它直接引用 [SshConnection] 的兜底值，而不是再抄一遍这个数字，两条连接路径因此
  /// 不可能漂移。
  ///
  /// Before this was honoured, SFTP was the one connection path that ignored the
  /// setting outright: a 3s preference still stalled the file manager for 10s,
  /// and a 30s one let the terminal connect at 25s while the file manager had
  /// already reported failure.
  /// 在本设置被遵循之前，SFTP 是唯一完全无视它的连接路径：设成 3 秒，文件管理器仍会
  /// 卡满 10 秒；设成 30 秒，终端在 25 秒才连上，而文件管理器早已报错。
  static const Duration defaultConnectTimeout =
      SshConnection.defaultConnectTimeout;

  /// Timeout for establishing the TCP/SSH session.
  /// 建立 TCP/SSH 会话的超时时间。
  final Duration connectTimeout;

  /// Creates a new SFTP service for the given [host] and [credential].
  /// 使用给定的 [host] 和 [credential] 创建新的 SFTP 服务。
  SftpService({
    required this.host,
    required this.credential,
    this.connectTimeout = defaultConnectTimeout,
    this.onHostKeyVerify,
  });

  /// Open SSH connection, authenticate, then open SFTP session.
  /// 打开 SSH 连接、认证，然后打开 SFTP 会话。
  ///
  /// Abortable: [disconnect] invalidates a connect that is still in flight, and
  /// every continuation below re-checks that after each `await`, so a teardown
  /// that lands mid-flight can never be outraced into publishing a live client
  /// or SFTP session.
  /// 可中止：[disconnect] 会作废仍在进行中的连接；下面每个 `await` 之后都会
  /// 重新检查，因此中途发生的清理操作不可能被反超而留下存活的客户端或 SFTP 会话。
  Future<void> connect() async {
    final epoch = ++_connectEpoch;

    // The resources this attempt creates are tracked in locals as well:
    // a concurrent [disconnect] clears the fields, and a newer attempt may own
    // them by now, so cleanup here must never go through the fields.
    // 本次尝试创建的资源同时用局部变量跟踪：并发的 [disconnect] 会清空字段，
    // 更新的尝试此刻也可能已占用它们，因此这里的清理绝不能经由字段进行。
    SSHSocket? socket;
    SSHClient? client;
    SftpClient? sftp;

    try {
      // [connectTimeout] is the caller's — the page passes the user's setting —
      // and defaults to [defaultConnectTimeout] only for a construction that
      // passes nothing.
      // [connectTimeout] 来自调用方——页面传入的是用户的设置；只有什么都没传的构造
      // 才使用 [defaultConnectTimeout]。
      socket = await SSHSocket.connect(
        host.ipAddress,
        host.port,
        timeout: connectTimeout,
      );

      // Torn down while the TCP handshake was pending. This socket is all the
      // attempt owns and nothing else holds a reference to it, so it must be
      // destroyed here or it stays connected forever.
      // TCP 握手期间被清理。这个套接字是本次尝试唯一的产物，没有其他引用持有它，
      // 不在这里销毁就会一直保持连接。
      if (_isAbandoned(epoch)) {
        _abandonConnecting(socket: socket);
        return;
      }

      client = SSHClient(
        socket,
        username: credential.username,
        onPasswordRequest: credential.authType == 0
            ? () => credential.secretData
            : null,
        identities: credential.authType == 1
            ? SSHKeyPair.fromPem(credential.secretData)
            : null,
        onVerifyHostKey: onHostKeyVerify != null
            ? (type, rawFingerprint) async {
                final fingerprint = HostKeyVerifier.formatMd5(rawFingerprint);
                return onHostKeyVerify!(fingerprint);
              }
            : null,
      );

      // Publish the client before awaiting so that [disconnect] can reach it and
      // abort the handshake, instead of walking past it and leaving a live,
      // authenticated client behind.
      // 在等待前先发布客户端，好让 [disconnect] 能拿到它并中止握手，
      // 而不是错过它、留下一个仍然存活且已完成认证的客户端。
      _client = client;

      await client.authenticated;

      // Torn down during authentication — possibly while a host-key dialog was
      // still on screen. [disconnect] has already closed `client`; closing it
      // again here is a backstop, and the guards below tolerate that.
      // 认证期间被清理——当时可能还开着主机密钥对话框。[disconnect] 已经关闭过
      // `client`；这里再关一次作为兜底，由下面的守护语句容忍重复关闭。
      if (_isAbandoned(epoch)) {
        _abandonConnecting(client: client);
        return;
      }

      sftp = await client.sftp();

      // Torn down while the SFTP subsystem was being opened. The subsystem
      // already exists on the server by now and `sftp` is the only reference to
      // it — the invalidating call could not have closed it, because the field
      // was still null at the time.
      // 打开 SFTP 子系统期间被清理。此时服务器上的子系统已经存在，而 `sftp` 是
      // 它唯一的引用——作废调用当时看到字段仍为 null，无法关闭它。
      if (_isAbandoned(epoch)) {
        _abandonConnecting(sftp: sftp, client: client);
        return;
      }

      // There is no `await` between the check above and this line, so a
      // teardown cannot slip in between: either we reach this point first (and
      // the teardown finds a published session it can close), or the check
      // above already returned.
      // 上面的检查与本行之间没有 `await`，清理操作不可能插进来：
      // 要么我们先到达（清理操作会看到一个已发布、可被关闭的会话），
      // 要么上面的检查已经返回。
      _sftp = sftp;
    } catch (e) {
      // A failure caused by our own teardown is not a connection error: close
      // whatever this attempt created and stay silent, rather than reporting an
      // error to a caller that has already moved on.
      // 由我们自己的清理动作引发的失败不是连接错误：关闭本次尝试创建的资源并保持
      // 安静，而不是向一个已经走开的调用方上报错误。
      if (_isAbandoned(epoch)) {
        _abandonConnecting(socket: socket, client: client, sftp: sftp);
        return;
      }
      await _cleanup();
      final detail = e.toString();
      throw SftpException(_classifyConnectFailure(detail), detail);
    }
  }

  /// List directory contents at [path].
  /// 列出 [path] 路径下的目录内容。
  ///
  /// Sorted: directories first, then files; each group alphabetically.
  /// 排序规则：目录在前，文件在后；各自按字母排序。
  Future<List<FileItem>> listDirectory(String path) async {
    _ensureConnected();
    try {
      final entries = await _sftp!.listdir(path);
      final items = entries
          .where((e) => e.filename != '.' && e.filename != '..')
          .map((e) => _toFileItem(e, path))
          .toList();
      items.sort((a, b) {
        if (a.isDirectory && !b.isDirectory) return -1;
        if (!a.isDirectory && b.isDirectory) return 1;
        return a.name.compareTo(b.name);
      });
      return items;
    } catch (e) {
      throw SftpException(SftpFailure.list, e.toString());
    }
  }

  /// Read full contents of a remote file at [path].
  /// 读取 [path] 路径下远程文件的全部内容。
  Future<Uint8List> readFile(String path) async {
    _ensureConnected();
    try {
      final file = await _sftp!.open(path, mode: SftpFileOpenMode.read);
      try {
        final chunks = await file.read().toList();
        final total = chunks.fold<int>(0, (s, c) => s + c.length);
        final buf = Uint8List(total);
        var offset = 0;
        for (final chunk in chunks) {
          buf.setRange(offset, offset + chunk.length, chunk);
          offset += chunk.length;
        }
        return buf;
      } finally {
        await file.close();
      }
    } catch (e) {
      throw SftpException(SftpFailure.read, e.toString());
    }
  }

  /// Overwrite a remote file at [path] with [data].
  /// 用 [data] 覆盖写入 [path] 路径下的远程文件。
  Future<void> writeFile(String path, Uint8List data) async {
    _ensureConnected();
    try {
      final file = await _sftp!.open(
        path,
        mode:
            SftpFileOpenMode.write |
            SftpFileOpenMode.create |
            SftpFileOpenMode.truncate,
      );
      try {
        await file.writeBytes(data);
      } finally {
        await file.close();
      }
    } catch (e) {
      throw SftpException(SftpFailure.write, e.toString());
    }
  }

  /// Size of the remote file at [path] in bytes, or null when the server does
  /// not report one.
  /// [path] 路径下远程文件的大小（字节）；服务器未报告时为 null。
  ///
  /// Exists so the transfer queue can show how far a download has come: without
  /// a total there is no progress bar, only a spinner, and a 500 MB package that
  /// shows a spinner for four minutes is indistinguishable from a hang.
  /// 它存在的理由是让传输队列能显示下载进度：没有总数就没有进度条，只有转圈；而一个
  /// 转圈四分钟的 500 MB 安装包，与卡死无法区分。
  ///
  /// Reported as [SftpFailure.read] when it fails. A stat is a read of the file's
  /// metadata, and the alternative — a `stat` code of its own — would be a
  /// near-duplicate that every caller had to handle separately for no gain.
  /// 失败时上报 [SftpFailure.read]。stat 读取的是文件的元数据；另一种做法是给它一个
  /// 独立的 `stat` 编码，但那只是近似重复，会让每个调用方为此单独分支而无任何收益。
  ///
  /// Null is a normal answer, not an error: SFTP servers are not obliged to
  /// report a size, and a size of 0 is not the same thing as no size at all.
  /// Callers that only want a progress denominator should treat null as "unknown"
  /// and carry on.
  /// null 是正常答案而非错误：SFTP 服务器没有义务报告大小，而大小为 0 与没有大小
  /// 也不是一回事。只把大小当作进度分母的调用方应把 null 视为「未知」并继续。
  Future<int?> fileSize(String path) async {
    _ensureConnected();
    try {
      final attrs = await _sftp!.stat(path);
      return attrs.size;
    } catch (e) {
      throw SftpException(SftpFailure.read, e.toString());
    }
  }

  /// Stream the contents of the remote file at [path], in chunks, reporting the
  /// number of bytes read so far to [onProgress].
  /// 以分块方式流式读取 [path] 路径下远程文件的内容，并通过 [onProgress] 报告已读取
  /// 的字节数。
  ///
  /// Unlike [readFile], the file is never held in memory as a whole: chunks are
  /// yielded as the server sends them, so a 500 MB file costs a chunk, not
  /// 500 MB. [readFile] stays for the previews that genuinely want the bytes.
  /// 与 [readFile] 不同，本方法从不把整个文件放进内存：服务器发来一块就产出一块，因此
  /// 500 MB 的文件只占用一块的开销，而不是 500 MB。[readFile] 继续服务于那些确实需要
  /// 完整字节的预览场景。
  ///
  /// Cancelling the subscription stops the transfer. That is a real stop, not a
  /// cosmetic one: this is an `async*` generator, so cancelling runs the
  /// `finally` below, which closes the server-side file handle — no further
  /// READ is ever issued and the handle is not left open. The chunking, the
  /// pipelining and the progress accounting are dartssh2's `SftpFile.read`; none
  /// of it is reimplemented here.
  /// 取消订阅即停止传输。这是真正的停止，不是表面功夫：本方法是一个 `async*` 生成器，
  /// 取消会让下面的 `finally` 执行并关闭服务器端文件句柄——此后不会再发出任何 READ，
  /// 句柄也不会被留在打开状态。分块、流水线与进度统计都由 dartssh2 的 `SftpFile.read`
  /// 完成，这里没有重新实现其中任何一部分。
  ///
  /// It is not instantaneous, and the bound is worth stating because it is what a
  /// caller waits on: an `async*` generator only unwinds at a suspension point, so
  /// a cancel lands when control next reaches the `yield*` — in practice after the
  /// reads already in flight (dartssh2 pipelines them) have been answered. No new
  /// READ is issued after that. Measured against a real server on loopback:
  /// `cancel()` returned in 130-175 ms with about a megabyte in flight, and the
  /// bytes delivered after it returned were zero.
  /// 它不是瞬时的，而这个上界值得写明，因为调用方要等它：`async*` 生成器只在挂起点
  /// 展开，因此取消会在控制流下一次到达 `yield*` 时生效——实际就是已经发出的读（
  /// dartssh2 会流水线化它们）得到应答之后。此后不会再发出新的 READ。在回环地址上对
  /// 真实服务器实测：约 1 MB 在途时 `cancel()` 在 130–175 ms 内返回，返回之后送达的
  /// 字节数为 0。
  Stream<Uint8List> downloadStream(
    String path, {
    void Function(int bytesRead)? onProgress,
  }) async* {
    _ensureConnected();
    SftpFile? file;
    try {
      file = await _sftp!.open(path, mode: SftpFileOpenMode.read);
      yield* file.read(onProgress: onProgress);
    } catch (e) {
      throw SftpException(SftpFailure.read, e.toString());
    } finally {
      // Runs on normal completion, on error *and* on cancellation. Guarded
      // because closing can throw once the transport is gone, and a throw here
      // would replace the real failure (or, on cancellation, surface as an
      // unhandled error on a stream nobody is listening to any more).
      // 正常结束、出错**以及**被取消时都会执行。做了守护，因为传输层消失后关闭会抛
      // 异常，而在这里抛出会顶掉真正的失败（被取消时则会在一个已无人监听的流上变成
      // 未处理错误）。
      try {
        await file?.close();
      } catch (_) {
        // Handle already released / 句柄已释放。
      }
    }
  }

  /// Upload [data] to the remote file at [path], reporting the number of bytes
  /// written so far to [onProgress].
  /// 将 [data] 上传到 [path] 路径下的远程文件，并通过 [onProgress] 报告已写入的字节数。
  ///
  /// The file is created if missing and truncated if present — the same mode
  /// [writeFile] uses, so an upload that fails half way does not leave the old
  /// contents hiding behind a new name.
  /// 文件不存在则创建，存在则截断——与 [writeFile] 相同的模式，因此中途失败的上传
  /// 不会让旧内容藏在新名字后面。
  ///
  /// [data] is consumed as a stream and written as it arrives, so the peak memory
  /// cost is one write window, not the file. Backpressure is end to end: when
  /// dartssh2's writer has a megabyte unacknowledged it pauses its subscription,
  /// which pauses whoever feeds this stream.
  /// [data] 按流消费、边到边写，因此内存峰值是一个写入窗口，而不是整个文件。背压是
  /// 端到端的：当 dartssh2 的写入器有 1 MB 未被确认时，它会暂停自己的订阅，进而暂停
  /// 向本方法供流的一方。
  ///
  /// [data] must not emit an error. dartssh2's writer installs no error handler on
  /// the stream it is given, so an error would be reported as an unhandled async
  /// error *and* leave its `done` pending forever — a hung upload that blocks its
  /// whole host queue. The queue therefore never errors the stream it hands over;
  /// it closes it and reports the cause separately. See [_guardedSource] for the
  /// backstop when a caller does not.
  /// [data] 不得发出错误。dartssh2 的写入器没有为它收到的流安装错误处理，因此错误会
  /// 变成未处理的异步错误，**并且**让它的 `done` 永远悬着——一次挂死的上传会阻塞整条
  /// 该主机的队列。因此队列交给它的流从不报错，而是关闭它并另行报告原因。调用方若不
  /// 遵守，由 [_guardedSource] 兜底。
  ///
  /// Cancellation is the caller's to arrange, and the shape is deliberate: the
  /// caller owns the stream it passes in, so closing that stream is what stops
  /// the transfer. Closing it ends dartssh2's `done`, which closes the handle
  /// below — there is no second, half-open way out of this method.
  /// 取消由调用方安排，其形式是刻意的：调用方拥有自己传入的流，因此关闭该流就是停止
  /// 传输的手段。关闭它会结束 dartssh2 的 `done`，从而执行下面的句柄关闭——本方法
  /// 不存在第二条留下半开句柄的退出路径。
  Future<void> uploadStream(
    String path,
    Stream<Uint8List> data, {
    void Function(int bytesWritten)? onProgress,
  }) async {
    _ensureConnected();
    SftpFile? file;
    Object? sourceError;
    try {
      file = await _sftp!.open(
        path,
        mode:
            SftpFileOpenMode.write |
            SftpFileOpenMode.create |
            SftpFileOpenMode.truncate,
      );
      // `done` completes when the last chunk has been acknowledged, so awaiting
      // it — rather than returning as soon as the last local byte was handed
      // over — is what makes "the upload finished" true when this returns.
      // `done` 在最后一块被确认时才完成，因此等待它（而不是在交出最后一个本地字节时
      // 就返回）正是「上传已完成」在本方法返回时为真的原因。
      await file
          .write(
            _guardedSource(data, (e) => sourceError = e),
            onProgress: onProgress,
          )
          .done;
    } catch (e) {
      throw SftpException(SftpFailure.write, e.toString());
    } finally {
      // Guarded for the same reason as in [downloadStream]: a throw from the
      // close must not replace the failure that caused it, and must never leave
      // the handle open.
      // 守护理由同 [downloadStream]：关闭抛出的异常不得顶掉引发它的失败，也绝不能把
      // 句柄留在打开状态。
      try {
        await file?.close();
      } catch (_) {
        // Handle already released / 句柄已释放。
      }
    }
    if (sourceError != null) {
      throw SftpException(SftpFailure.write, sourceError.toString());
    }
  }

  /// Delete a file or empty directory at [path].
  /// 删除 [path] 路径下的文件或空目录。
  ///
  /// Tries rmdir first (for directories), then falls back to remove (for files).
  /// 先尝试 rmdir（目录），失败则回退到 remove（文件）。
  Future<void> deleteFile(String path) async {
    _ensureConnected();
    try {
      try {
        await _sftp!.rmdir(path);
      } catch (_) {
        await _sftp!.remove(path);
      }
    } catch (e) {
      throw SftpException(SftpFailure.delete, e.toString());
    }
  }

  /// Rename / move a remote entry from [oldPath] to [newPath].
  /// 将远程条目从 [oldPath] 重命名或移动到 [newPath]。
  Future<void> rename(String oldPath, String newPath) async {
    _ensureConnected();
    try {
      await _sftp!.rename(oldPath, newPath);
    } catch (e) {
      throw SftpException(SftpFailure.rename, e.toString());
    }
  }

  /// Create a directory at [path].
  /// 在 [path] 路径下创建目录。
  Future<void> createDirectory(String path) async {
    _ensureConnected();
    try {
      await _sftp!.mkdir(path);
    } catch (e) {
      throw SftpException(SftpFailure.mkdir, e.toString());
    }
  }

  /// Gracefully close the SFTP session and underlying SSH connection.
  /// 优雅地关闭 SFTP 会话和底层 SSH 连接。
  ///
  /// Also aborts a [connect] that is still in flight: without the epoch bump a
  /// teardown landing mid-connect would walk past fields that are still null,
  /// and the connect continuation would then publish an authenticated client
  /// and an SFTP subsystem that no one is left to close.
  /// 同时中止仍在进行中的 [connect]：若不递增世代号，中途发生的清理只会看到仍为
  /// null 的字段，随后连接流程就会发布一个已认证的客户端和 SFTP 子系统，
  /// 而再没有对象负责关闭它们。
  Future<void> disconnect() async {
    _connectEpoch++;
    await _cleanup();
  }

  // ---- private helpers / 私有辅助方法 ----

  /// Throws if the SFTP session is not connected.
  /// 若 SFTP 会话未连接则抛出异常。
  void _ensureConnected() {
    if (_sftp == null || _client == null) {
      throw const SftpException(SftpFailure.notConnected);
    }
  }

  /// [source] with any error reported to [onError] and then turned into an
  /// ordinary end of stream.
  /// 把 [source] 的错误报告给 [onError] 后，转成一次普通的流结束。
  ///
  /// An `async*` body wrapping `await for` is the only shape that both keeps
  /// backpressure (a paused consumer pauses [source], which is what a plain
  /// `handleError` would give up) and guarantees the output stream *ends* rather
  /// than erroring — and ending is the point: see [uploadStream] for why an
  /// error on this stream hangs the writer instead of failing it.
  /// 用 `async*` 包住 `await for` 是唯一同时满足两件事的写法：既保住背压（消费者暂停
  /// 会暂停 [source]，而朴素地用 `handleError` 会丢掉这一点），又保证输出流*结束*而
  /// 不是报错——而「结束」正是关键：[uploadStream] 的注释解释了为什么这条流上的错误
  /// 会让写入器挂死而不是失败。
  Stream<Uint8List> _guardedSource(
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

  /// Whether the connect attempt identified by [epoch] was invalidated by a
  /// [disconnect] that landed while it was suspended on an `await`.
  /// 由 [epoch] 标识的连接尝试是否在其挂起期间被 [disconnect] 作废。
  bool _isAbandoned(int epoch) => epoch != _connectEpoch;

  /// Tears down the resources created by a connect attempt that was invalidated
  /// while suspended on an `await` (see [_isAbandoned]).
  /// 清理在 `await` 挂起期间被作废的连接尝试所创建的资源（见 [_isAbandoned]）。
  ///
  /// Only the references passed in are touched: `_sftp` / `_client` are
  /// deliberately left alone, because [disconnect] has already cleared them and
  /// a newer attempt may own them by now.
  /// 只关闭传入的引用；刻意不碰 `_sftp` / `_client`，因为 [disconnect] 已经清空了
  /// 它们，此刻也可能已被更新的尝试占用。
  ///
  /// Each step is guarded on its own: once the transport is closed, closing an
  /// SFTP channel or a client throws (SftpClient.close() completes an
  /// already-completed completer, SSHClient.close() can raise
  /// `SSHStateError('Transport is closed')`), and that must not keep the
  /// remaining resources open.
  /// 每一步单独守护：传输层关闭后再关闭 SFTP 通道或客户端会抛出异常
  /// （SftpClient.close() 会去完成一个已经完成的 completer，SSHClient.close()
  /// 可能抛出 `SSHStateError('Transport is closed')`），不能因此让其余资源继续
  /// 泄漏。
  void _abandonConnecting({
    SSHSocket? socket,
    SSHClient? client,
    SftpClient? sftp,
  }) {
    try {
      sftp?.close();
    } catch (_) {
      // Channel already gone / 通道已不存在。
    }
    try {
      client?.close();
    } catch (_) {
      // Transport already gone / 传输层已不存在。
    }
    // Unlike `close()`, `destroy()` is synchronous, idempotent and does not
    // throw, so it leaves no future behind. Destroying a socket whose transport
    // is already gone is a no-op.
    // 与 `close()` 不同，`destroy()` 是同步、幂等且不抛异常的，不会留下 future。
    // 对传输层已经消失的套接字调用它不会有任何副作用。
    socket?.destroy();
  }

  /// Close SFTP and SSH clients, swallowing exceptions.
  /// 关闭 SFTP 和 SSH 客户端，忽略异常。
  ///
  /// The two closes are guarded separately on purpose: a throw from the SFTP
  /// close must not skip the client close. Both are attempted even when one
  /// objects that its channel is already gone.
  /// 两次关闭刻意各自守护：关闭 SFTP 时抛出的异常不能让客户端的关闭被跳过。
  /// 即使其中一方抱怨通道已不存在，另一方仍会被关闭。
  ///
  /// The fields are cleared before this method returns (it contains no `await`,
  /// so the whole body runs synchronously), which makes repeated calls — one
  /// from [disconnect] and one from a failed [connect] — harmless no-ops.
  /// 本方法返回前会清空字段（方法体中没有 `await`，整体同步执行），因此重复调用
  /// （一次来自 [disconnect]，一次来自失败的 [connect]）是无副作用的空操作。
  Future<void> _cleanup() async {
    try {
      _sftp?.close();
    } catch (_) {
      // SFTP channel already gone / SFTP 通道已不存在。
    }
    try {
      _client?.close();
    } catch (_) {
      // Transport already gone / 传输层已不存在。
    }
    _sftp = null;
    _client = null;
  }

  /// Convert an [SftpName] entry to a [FileItem] for the UI.
  /// 将 [SftpName] 条目转换为供 UI 使用的 [FileItem]。
  FileItem _toFileItem(SftpName entry, String parentPath) {
    final a = entry.attr;
    final fullPath = parentPath.endsWith('/')
        ? '$parentPath${entry.filename}'
        : '$parentPath/${entry.filename}';

    return FileItem(
      name: entry.filename,
      path: fullPath,
      isDirectory: a.isDirectory,
      size: a.size ?? 0,
      permissions: _formatMode(a.mode),
      modifiedDate: a.modifyTime != null
          ? DateTime.fromMillisecondsSinceEpoch(a.modifyTime! * 1000)
          : DateTime.now(),
    );
  }

  /// Format an [SftpFileMode] into a Unix-like permission string (e.g. "rwxr-xr--").
  /// 将 [SftpFileMode] 格式化为类 Unix 权限字符串（如 "rwxr-xr--"）。
  String _formatMode(SftpFileMode? mode) {
    if (mode == null) return '---------';
    return '${mode.userRead ? 'r' : '-'}${mode.userWrite ? 'w' : '-'}${mode.userExecute ? 'x' : '-'}'
        '${mode.groupRead ? 'r' : '-'}${mode.groupWrite ? 'w' : '-'}${mode.groupExecute ? 'x' : '-'}'
        '${mode.otherRead ? 'r' : '-'}${mode.otherWrite ? 'w' : '-'}${mode.otherExecute ? 'x' : '-'}';
  }

  /// Classify a raw connect failure into a code the presentation layer can turn
  /// into a sentence in the user's own language.
  /// 将原始连接失败归类为展示层可据此生成用户语言句子的编码。
  ///
  /// Reading a transport error is protocol knowledge and stays here; wording it
  /// is not, and moved to the i18n table. The predicates and their order are the
  /// ones the message-based translation used, so which code a given failure
  /// yields is unchanged — only the words are.
  /// 解读传输层错误属于协议知识，留在这里；措辞不属于，已移到 i18n 表。判断条件及其
  /// 顺序与基于消息的翻译完全一致，因此某种失败得到哪个编码保持不变——变的只是文字。
  SftpFailure _classifyConnectFailure(String error) {
    final lower = error.toLowerCase();
    if (lower.contains('timeout')) return SftpFailure.connTimeout;
    if (lower.contains('auth') ||
        lower.contains('password') ||
        lower.contains('key')) {
      return SftpFailure.authFailed;
    }
    if (lower.contains('refused')) return SftpFailure.connRefused;
    if (lower.contains('resolve') || lower.contains('unknown host')) {
      return SftpFailure.hostUnreachable;
    }
    return SftpFailure.connect;
  }
}

/// What went wrong in an [SftpService] operation.
/// [SftpService] 的某次操作出了什么问题。
///
/// A machine-readable code, not a sentence. The words a user reads come from the
/// i18n table, via `pages/sftp/sftp_error_text.dart`; this service used to write
/// those words itself, in Chinese, on every failed operation — which is why an
/// English user got a Chinese diagnosis for a failed listing, read or delete.
/// 机器可读的编码，而非句子。用户读到的文字来自 i18n 表，经由
/// `pages/sftp/sftp_error_text.dart`；本服务此前自己书写这些文字，且写的是中文，
/// 因此英文用户在列举、读取或删除失败时得到的都是中文诊断。
enum SftpFailure {
  /// No live SFTP session to run the operation on.
  /// 没有可执行操作的 SFTP 会话。
  notConnected,

  /// The connection attempt timed out.
  /// 连接尝试超时。
  connTimeout,

  /// Authentication was rejected.
  /// 认证被拒绝。
  authFailed,

  /// The server refused the connection.
  /// 服务器拒绝连接。
  connRefused,

  /// The host address could not be resolved.
  /// 主机地址无法解析。
  hostUnreachable,

  /// The connection failed for a reason none of the above covers.
  /// 连接失败，原因不属于以上任何一类。
  connect,

  /// Listing a directory failed.
  /// 列举目录失败。
  list,

  /// Reading a file failed.
  /// 读取文件失败。
  read,

  /// Writing a file failed.
  /// 写入文件失败。
  write,

  /// Deleting an entry failed.
  /// 删除条目失败。
  delete,

  /// Renaming an entry failed.
  /// 重命名条目失败。
  rename,

  /// Creating a directory failed.
  /// 创建目录失败。
  mkdir,
}

/// Exception thrown by [SftpService] operations.
/// [SftpService] 操作抛出的异常。
///
/// Carries a code and the raw detail instead of a message: prose belongs to the
/// i18n table, and a service that composes it can only compose it in one
/// language. Pair it with `sftpErrorText` to get something a user can read.
/// 携带编码与原始细节，而不是消息：文案属于 i18n 表，而自行组装文案的服务只能组装
/// 出一种语言。需要给用户读的文字时，请配合 `sftpErrorText` 使用。
class SftpException implements Exception {
  /// What went wrong.
  /// 出了什么问题。
  final SftpFailure kind;

  /// The underlying error's own rendering — a socket error, a protocol status —
  /// never a sentence this app wrote. Null when there is nothing to add, as with
  /// [SftpFailure.notConnected].
  /// 底层错误自身的呈现——套接字错误、协议状态——绝不是本应用写下的句子。
  /// 无可补充时为 null，例如 [SftpFailure.notConnected]。
  final String? detail;

  const SftpException(this.kind, [this.detail]);

  /// Technical rendering of the failure: printable, never displayable.
  /// 失败的技术呈现：可以打印，不能直接展示。
  ///
  /// Kept so callers that read `.message` still compile and still have something
  /// to print. It is deliberately not translated — anything a user reads must go
  /// through `sftpErrorText`, which is what actually respects the language
  /// setting.
  /// 保留它，是为了让读取 `.message` 的调用方仍能编译、仍能拿到可打印的内容。它有
  /// 意不做翻译——任何给用户读的文字都必须经由 `sftpErrorText`，那才是真正遵循语言
  /// 设置的路径。
  String get message => detail ?? kind.name;

  @override
  String toString() => detail == null ? kind.name : '${kind.name}: $detail';
}
