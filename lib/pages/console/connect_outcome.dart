import '../../models/host.dart';

/// The honest [HostStatus] for a console connection that failed to come up.
/// 控制台连接未能建立时，如实对应的 [HostStatus]。
///
/// This is the one place that decides what a failed console connection means
/// about the *machine*, and it is a pure function so the rule can be tested
/// without a server — the same shape as `remote_action_outcome.dart` next door.
/// 这是唯一决定「控制台连接失败对**机器**意味着什么」的地方。它是纯函数，因此无需
/// 服务器即可测试——与隔壁的 `remote_action_outcome.dart` 是同一形态。
///
/// A **refused host key proves nothing about availability.** The transport is
/// torn down at the verification step, before the machine has answered for
/// itself, so the only truthful report is [HostStatus.unverified] — "we could
/// not confirm this host", not "this host is down". Every other failure is an
/// answer: a timeout is a machine that did not reply, a refused connection is
/// one that actively said no, and a rejected credential is one that answered
/// and then turned us away. Those are observed outages.
/// **主机密钥被拒无法证明任何可用性。** 传输层在校验这一步就被拆掉，机器还没来得及
/// 自证身份，因此唯一诚实的报告是 [HostStatus.unverified]——「我们无法确认这台主机」，
/// 而不是「这台主机下线了」。其余失败都是回答：超时是机器没有回应，连接被拒是机器明确
/// 说了不，凭据被拒是机器回应了但把我们挡在门外。这些都是观察到的宕机。
///
/// ## Why the parameter is a flag and not the failure code
/// 参数为何是标志位而不是失败码
///
/// The obvious signal — `SshConnection.failure == SshFailure.hostKeyVerify` —
/// **does not work**, and the device showed it. `dartssh2` reports a rejected
/// key by closing the transport (`ssh_transport.dart`:
/// `closeWithError(SSHHostkeyError('Hostkey verification failed'))`), and a
/// transport that closes before authentication completes the pending
/// `authenticated` future with a *different* error
/// (`ssh_client.dart:702`: `SSHAuthAbortError('Connection closed before
/// authentication', error)`). What surfaces is an auth-abort, so the code says
/// "authentication failed" and the console told the user to check credentials
/// that were never the problem.
/// 最显然的信号——`SshConnection.failure == SshFailure.hostKeyVerify`——**行不通**，
/// 真机已经证明。`dartssh2` 报告密钥被拒的方式是关闭传输层，而在认证完成之前关闭的
/// 传输层会用**另一个**错误来完成挂起的 `authenticated` future。真正浮上来的是认证
/// 中止，于是编码说「认证失败」，控制台便让用户去检查一个根本不是问题所在的凭据。
///
/// The only component that reliably knows a key was refused is the verifier
/// itself, so the caller records that where it happens and passes it here. The
/// background probe on the home page uses the same signal for the same reason.
/// 唯一可靠知道密钥被拒的组件是验证器本身，因此调用方在发生处记录下来并传进来。首页的
/// 后台探测出于同样理由使用同一个信号。
HostStatus statusForConnectFailure({required bool trustRefused}) {
  return trustRefused ? HostStatus.unverified : HostStatus.offline;
}
