/// Identity of one directory-listing request.
/// 一次目录列举请求的身份标识。
class DirectoryRequest {
  /// Monotonic token; only the newest one may commit its result.
  /// 单调递增的令牌；只有最新的那个可以提交结果。
  final int token;

  /// Absolute remote path this request listed.
  /// 本次请求列举的远程绝对路径。
  final String path;

  const DirectoryRequest({required this.token, required this.path});

  @override
  String toString() => 'DirectoryRequest($token, $path)';
}

/// Tracks the requested path, the shown path, and the in-flight request for one
/// SFTP page.
/// 跟踪一个 SFTP 页面的请求路径、显示路径与在途请求。
///
/// Why this exists / 存在的理由:
/// Directory loads overlap in practice — a breadcrumb stays tappable while a
/// listing is in flight, so two responses can be outstanding at once. Without an
/// identity per request, the slower response silently replaces the newer one,
/// the spinner clears while a load is still running, and the path shown in the
/// path bar can describe a different directory than the entries below it. Since
/// create and rename build their target path from the directory the page thinks
/// it is in, that mismatch writes files somewhere the user is not looking.
/// 目录加载在实践中会重叠——列举进行中面包屑仍可点击，因此同时可能有两个响应在途。
/// 若每次请求没有身份标识，较慢的响应会静默覆盖较新的结果，加载尚未结束转圈就消失，
/// 而且路径栏显示的目录可能与下方列表不是同一个。由于新建与重命名都以页面认为
/// 自己所在的目录拼接目标路径，这种不一致会把文件写到用户没在看的地方。
///
/// Two rules implement the fix / 两条规则实现该修复:
/// 1. Only the newest request may commit ([isCurrent]) — a stale response is
///    dropped whole, including its error.
///    只有最新的请求可以提交（[isCurrent]）——过期响应被整体丢弃，错误也一样。
/// 2. The requested path never survives a failure that left no listing on
///    screen: [commitFailed] puts it back to the directory that is still shown.
///    请求路径不会在一次「屏幕上没有对应列表」的失败后保留：[commitFailed] 会把它
///    回退到仍然显示着的目录。
class DirectoryLoadState {
  /// Creates the state for a page that starts in [initialPath].
  /// 为起始于 [initialPath] 的页面创建状态。
  DirectoryLoadState(this._requestedPath) : _shownPath = _requestedPath;

  /// The directory the user has asked for; this is what the path bar shows.
  /// 用户请求的目录；路径栏显示的就是它。
  String _requestedPath;

  /// The directory the entries currently in the list were listed from.
  /// 当前列表中的条目录自哪个目录。
  String _shownPath;

  int _issuedTokens = 0;
  bool _loading = false;

  /// The directory the path bar must display.
  /// 路径栏必须显示的目录。
  String get requestedPath => _requestedPath;

  /// The directory the current entries belong to.
  /// 当前条目所属的目录。
  String get shownPath => _shownPath;

  /// Whether a listing is in flight for the newest request.
  /// 最新请求是否仍在加载中。
  bool get isLoading => _loading;

  /// Registers a new load of [path] and returns the request to answer with.
  /// 登记一次对 [path] 的新加载，并返回应答时使用的请求对象。
  DirectoryRequest begin(String path) {
    _requestedPath = path;
    _loading = true;
    return DirectoryRequest(token: ++_issuedTokens, path: path);
  }

  /// Whether [request] is still the newest one. A stale request must not touch
  /// the view at all — not its entries, not its spinner, not its error.
  /// [request] 是否仍是最新的请求。过期请求不得以任何方式影响界面——条目、转圈、错误都不行。
  bool isCurrent(DirectoryRequest request) => request.token == _issuedTokens;

  /// Commits a listing that arrived. Returns false when [request] is stale, in
  /// which case the caller must drop the entries it just received.
  /// 提交已到达的列举结果。若 [request] 已过期则返回 false，调用方必须丢弃刚收到的条目。
  bool commitLoaded(DirectoryRequest request) {
    if (!isCurrent(request)) return false;
    _shownPath = request.path;
    _requestedPath = request.path;
    _loading = false;
    return true;
  }

  /// Commits a failed listing. Returns false when [request] is stale.
  /// 提交失败的列举结果。若 [request] 已过期则返回 false。
  ///
  /// The requested path goes back to the directory that is still listed, so the
  /// path bar never claims a directory whose contents were never loaded — the
  /// state that used to make browsing into a permission-denied directory look
  /// like a success until the user acted on the wrong path.
  /// 请求路径回退到仍然有列表在显示的目录，路径栏因此不会声称自己在一个内容从未加载
  /// 成功的目录里——正是这个状态让「进入无权限目录」看起来像成功了，直到用户对错误的
  /// 路径执行了操作。
  bool commitFailed(DirectoryRequest request) {
    if (!isCurrent(request)) return false;
    _requestedPath = _shownPath;
    _loading = false;
    return true;
  }

  @override
  String toString() =>
      'DirectoryLoadState(requested: $_requestedPath, shown: $_shownPath, '
      'loading: $_loading)';
}
