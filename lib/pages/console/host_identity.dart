import 'probe_command.dart';

/// What the remote machine says about itself, for the console header.
/// 远端机器对自己的描述，用于控制台页头。
///
/// Held apart from the page so the parsing rules can be tested without an SSH
/// connection. The defect that motivated the split is purely a parsing
/// property: `uname.split(' ').sublist(0, 3)` threw `RangeError` whenever the
/// output held fewer than three tokens — exactly what an error string or an
/// empty read looks like — and the empty `catch` around it left the header
/// showing the IP instead of the host name, with nothing said about why.
/// 与页面分离，好让解析规则无需 SSH 连接即可测试。促成这次拆分的缺陷完全是一条
/// 解析规则：只要输出少于三个 token（错误串或空读取正是如此），
/// `uname.split(' ').sublist(0, 3)` 就抛 `RangeError`，而包住它的空 `catch`
/// 让页头显示 IP 而不是主机名，且对原因只字不提。
class HostIdentity {
  /// `hostname` output, or `''` when it could not be read.
  /// `hostname` 的输出；读不到时为 `''`。
  final String hostname;

  /// `PRETTY_NAME` from `/etc/os-release`, or `''`.
  /// `/etc/os-release` 中的 `PRETTY_NAME`；读不到时为 `''`。
  final String prettyName;

  /// The first three `uname -a` tokens, or `''`.
  /// `uname -a` 的前三个 token；读不到时为 `''`。
  final String kernel;

  const HostIdentity({
    this.hostname = '',
    this.prettyName = '',
    this.kernel = '',
  });

  /// Nothing was read.
  /// 什么都没读到。
  static const HostIdentity unknown = HostIdentity();

  /// Whether no field could be filled.
  /// 是否没有任何字段被填上。
  bool get isEmpty => hostname.isEmpty && prettyName.isEmpty && kernel.isEmpty;

  /// The line under the host name: the distro above the kernel.
  /// 主机名下方的一行：发行版在上，内核在下。
  ///
  /// Empty parts are dropped rather than leaving a blank line, so a host that
  /// reports only one of the two still gets a clean header.
  /// 空的部分直接省略而不留空行，因此只上报其中一项的主机也能得到干净的页头。
  String get osInfo {
    final parts = [prettyName, kernel].where((p) => p.isNotEmpty);
    return parts.join('\n');
  }

  @override
  String toString() =>
      'HostIdentity(hostname: $hostname, prettyName: $prettyName, '
      'kernel: $kernel)';
}

/// Extracts the kernel triple from `uname -a` output.
/// 从 `uname -a` 输出中提取内核三要素。
///
/// Returns `null` — never throws — when the output holds fewer than three
/// tokens. That is the shape of an error message, a truncated read, or a
/// connection that dropped between `connect()` and this command, and none of
/// those is a kernel name: returning a value here would print the error text
/// in the header, and throwing is what used to make the failure silent.
/// 输出不足三个 token 时返回 `null`——绝不抛异常。那正是错误信息、截断的读取、
/// 或连接在 `connect()` 与本命令之间掉线的形态，而这些都不是内核名：在这里返回
/// 一个值会把错误文本印到页头上，而抛异常正是过去让失败变得无声的原因。
String? parseKernelTriple(String unameOutput, {int tokenCount = 3}) {
  final tokens = unameOutput
      .split(RegExp(r'\s+'))
      .where((token) => token.isNotEmpty)
      .toList(growable: false);
  if (tokens.length < tokenCount) return null;
  return tokens.take(tokenCount).join(' ');
}

/// Extracts `PRETTY_NAME` from `/etc/os-release` output, or `null`.
/// 从 `/etc/os-release` 输出中提取 `PRETTY_NAME`，读不到时为 `null`。
///
/// The value is quoted in the file and may contain spaces, so the quotes are
/// stripped while the inner spacing is preserved.
/// 该值在文件中带引号且可能含空格，因此只去掉引号，保留内部空格。
String? parsePrettyName(String osReleaseOutput) {
  for (final line in osReleaseOutput.split('\n')) {
    if (!line.startsWith('PRETTY_NAME=')) continue;
    final value = line
        .replaceFirst('PRETTY_NAME=', '')
        .replaceAll('"', '')
        .trim();
    if (value.isNotEmpty) return value;
  }
  return null;
}

/// Reads the three identity commands in one go and parses what came back.
/// 一次性读取三条身份命令并解析返回内容。
///
/// A command that fails leaves its own field empty instead of ending the whole
/// fetch: a host whose `uname` is missing still deserves to be named. When
/// *nothing* could be read the first failure is thrown, so an empty header is
/// always explainable rather than silent — the exact case the old code lost.
/// 单条命令失败只让它自己的字段为空，不会终止整次读取：没有 `uname` 的主机也该
/// 有个名字。只有**什么都**读不到时才抛出首次失败，因此空页头一定有解释，不会
/// 像旧代码那样无声无息。
///
/// A non-empty `uname` output that does not parse counts as a failure of that
/// field for the same reason: it means the read did not return a kernel.
/// 非空的 `uname` 输出若解析不出来，同样记为该字段的失败：那说明这次读取并没有
/// 返回内核信息。
Future<HostIdentity> fetchHostIdentity(
  ProbeRunner run, {
  required Duration timeout,
}) async {
  ProbeException? firstFailure;

  var hostname = '';
  try {
    final result = await probeCommand(run, 'hostname', timeout: timeout);
    hostname = result.stdout.trim();
  } on ProbeException catch (e) {
    firstFailure ??= e;
  }

  var prettyName = '';
  try {
    final result = await probeCommand(
      run,
      'cat /etc/os-release 2>/dev/null | head -4',
      timeout: timeout,
    );
    prettyName = parsePrettyName(result.stdout) ?? '';
  } on ProbeException catch (e) {
    firstFailure ??= e;
  }

  var kernel = '';
  try {
    final result = await probeCommand(run, 'uname -a', timeout: timeout);
    kernel = parseKernelTriple(result.stdout) ?? '';
    if (kernel.isEmpty) {
      firstFailure ??= ProbeException(
        ProbeFailure.failed,
        'uname -a: ${describeOutput(result.stdout)}',
      );
    }
  } on ProbeException catch (e) {
    firstFailure ??= e;
  }

  if (hostname.isEmpty && prettyName.isEmpty && kernel.isEmpty) {
    throw firstFailure ??
        const ProbeException(ProbeFailure.failed, 'host identity empty');
  }

  return HostIdentity(
    hostname: hostname,
    prettyName: prettyName,
    kernel: kernel,
  );
}
