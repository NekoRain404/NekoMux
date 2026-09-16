import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/i18n/strings.dart';
import '../../models/credential.dart';
import '../../models/host.dart';
import '../../providers/providers.dart';
import '../../providers/ssh_provider.dart';
import '../../services/host_key_trust.dart';
import '../../services/sftp_service.dart';
import '../../widgets/host_key_prompt.dart';
import 'sftp_error_text.dart';

/// The connection half of the file manager's state.
///
/// A mixin rather than a controller object because everything here is the page's
/// own lifecycle: it reads the page's `ref`, shows a dialog from the page's
/// `context`, and calls back into the page's `setState`. Split out because that
/// lifecycle is a third of `sftp_page.dart`, and the 800-line limit is a rule
/// about files, not about how much one screen may do.
///
/// It owns: the service, whether it is connecting, why it failed, whether the
/// transport died under a live page, and the reconnect path.
mixin SftpConnectionState<T extends ConsumerStatefulWidget> on ConsumerState<T> {
  /// The page's connection, or null before one exists.
  SftpService? sftpService;

  /// True while the session is being established.
  bool isConnecting = true;

  /// Why there is no listing, when a failure is what put the page in that state.
  String? errorMessage;

  /// True when the transport died under this page rather than one operation
  /// failing.
  ///
  /// Separate from [errorMessage] because the two are shown in different places:
  /// a failed listing is a snackbar over a listing that is still true, while a
  /// session that is over needs the full-page reconnect view — every later
  /// operation will fail the same way, and the listing on screen is now a
  /// picture of how things were.
  bool sessionLost = false;

  /// The host this page manages.
  Host get host;

  /// The credential the page was opened with, if the caller had one to hand.
  Credential? get initialCredential;

  /// Loads the directory the session opens on. The page owns which one that is.
  Future<void> loadRootDirectory();

  Future<void> resolveAndConnect() async {
    var cred = initialCredential;
    try {
      if (cred == null) {
        final allCreds = await ref.read(credentialListProvider.future);
        if (!mounted) return;
        cred = allCreds
            .where((c) => c.id == host.credentialId)
            .firstOrNull;
      }
      if (cred == null) {
        setState(() {
          isConnecting = false;
          errorMessage = t('credential_not_found');
        });
        return;
      }

      // The accepted keys live in SQLite, so the verifier needs the database.
      // The in-memory cache this replaced could not tell a changed key from a
      // first contact and forgot every accepted key on restart, which is the
      // same as not verifying at all.
      // 已接受的密钥存放在 SQLite，因此验证器需要数据库实例。它取代的内存缓存既无法
      // 区分「密钥变更」与「首次连接」，又会在每次重启后忘掉所有已接受的密钥——
      // 那等于没有验证。
      final db = await ref.read(databaseProvider.future);
      if (!mounted) return;

      sftpService = SftpService(
        host: host,
        credential: cred,
        // Settings → connect timeout, honoured in full — deliberately not
        // clamped the way the home page's background probe clamps it. The two
        // cases are opposites: a probe runs against every host on every round
        // with nobody watching, while this page opens exactly the one session
        // the user asked for by tapping a host. Clamping here would recreate the
        // defect being fixed — a user on a slow link who chose 30s would still
        // be cut off at 4s — and the cost of obeying it is paid once per
        // attempt, not per tick: a connect happens on open and on retry, both
        // user-initiated.
        // 设置 → 连接超时，在这里被完整遵循——刻意**不**像主页后台探测那样钳制。两者
        // 恰好相反：探测每轮对每台主机执行且无人注视，而本页只打开用户点击主机所请求的
        // 那一条会话。在此钳制会重新造出正在修复的缺陷——慢链路上的用户设了 30 秒，却
        // 依然在 4 秒被切断——而遵循它的代价只按次支付，不按 tick 重复：连接只发生在
        // 打开与重试时，全部由用户发起。
        connectTimeout: ref.read(connectTimeoutProvider),
        onHostKeyVerify: buildHostKeyVerifier(
          db: db,
          address: host.ipAddress,
          port: host.port,
          onPrompt: (fingerprint, verdict) async {
            // Raised from inside connect(), so by the time a key needs judging
            // the page may already be gone.
            // 该提示由 connect() 内部触发，等到需要判定密钥时页面可能已销毁。
            if (!mounted) return false;
            return showHostKeyPrompt(
              context,
              fingerprint: fingerprint,
              verdict: verdict,
            );
          },
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        isConnecting = false;
        // Nothing here reached the service, so there is no code to map — the
        // failure is reported as a failed connection with the raw detail, which
        // is what an unexpected exception can honestly offer.
        // 这里的失败根本没有到达 service，因此没有编码可映射——按连接失败上报并附带
        // 原始细节，这也是一份意外异常能诚实提供的信息。
        errorMessage = sftpFailureText(SftpFailure.connect, '$e');
      });
      return;
    }
    connect();
  }

  /// Opens the connection and loads the root directory.
  /// 建立连接并载入根目录。
  Future<void> connect() async {
    setState(() {
      isConnecting = true;
      errorMessage = null;
      sessionLost = false;
    });
    try {
      await sftpService!.connect();
      if (!mounted) {
        // The page was popped while the session was opening. dispose() has
        // already run — and ran before the service finished connecting, so it
        // had nothing to close. Closing here is what keeps an abandoned SFTP
        // page from leaving an authenticated session on the server until the
        // app exits.
        // 连接建立期间页面被返回销毁。dispose() 已经执行过，且执行时服务尚未连接完成，
        // 因此它没有东西可关。在这里关闭，才能避免一个被放弃的 SFTP 页面在服务器上
        // 留下已认证会话直到 App 结束。
        await sftpService?.disconnect();
        return;
      }
      watchSession();
      await loadRootDirectory();
    } on SftpException catch (e) {
      if (!mounted) return;
      setState(() => errorMessage = sftpErrorText(e));
    } catch (e) {
      if (!mounted) return;
      setState(
        () => errorMessage = sftpFailureText(SftpFailure.connect, '$e'),
      );
    } finally {
      // Guarded on purpose: connect() is awaited while the user can still press
      // back, and an unguarded setState here throws on every such exit.
      // 有意加守卫：connect() 等待期间用户仍可返回，未加守卫的 setState 会在这种
      // 情况下抛异常。
      if (mounted) setState(() => isConnecting = false);
    }
  }

  /// Reacts to the transport going away under a live page.
  ///
  /// Without this the page could only fail: a dead session makes every later
  /// operation throw the same error, so browsing turned into a run of snackbars
  /// with no reconnect and no explanation — while the terminal, which has had
  /// this since it was written, put a single "disconnected" view with a retry in
  /// front of the user. A deliberate [disconnect] resets the signal, so this
  /// only fires for a session that ended on its own.
  void watchSession() {
    final closed = sftpService?.closed;
    if (closed == null) return;
    unawaited(
      closed.then((_) {
        if (!mounted || isConnecting) return;
        setState(() {
          sessionLost = true;
          // Shown by the status view, which takes over the body: the listing is
          // kept in [_files] so reconnecting brings it straight back, and
          // [errorMessage] carries the reason the user reads while it is down.
          errorMessage = t('disconnected');
        });
      }),
    );
  }

  /// Retries from the error page: drop the old session, then connect again.
  /// 从错误页重试：断开旧会话后重新连接。
  Future<void> retryConnection() async {
    await sftpService?.disconnect();
    if (!mounted) return;
    await resolveAndConnect();
  }
}
