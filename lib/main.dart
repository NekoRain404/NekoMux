import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'app.dart';

/// How long a failed provider waits before it is retried, or null to stop.
/// 失败的 provider 重试前的等待时长；返回 null 表示不再重试。
///
/// Riverpod's default retries ten times with exponential backoff — about 38
/// seconds in total — and while a retry is pending the provider reports
/// `isLoading` **and** `hasError`, so anything awaiting it sees a plain loading
/// state with no error flag. Measured on this project: six seconds in, a
/// dependent of a failing provider was `isLoading: true, hasError: false`.
/// Riverpod 默认重试十次并指数退避——合计约 38 秒——而重试等待期间 provider 同时
/// 报告 `isLoading` 与 `hasError`，因此等待它的东西看到的是不带错误标志的纯加载态。
/// 实测：6 秒时，失败 provider 的依赖者仍是 `isLoading: true, hasError: false`。
///
/// That matters because the app's data source is a local database that either
/// opens or does not. When it does not, every list screen — hosts, credentials,
/// snippets, known host keys — would spin with no explanation for the better
/// part of a minute before finally showing the error its error-state branch has
/// been ready to render all along.
/// 这在这里是要紧的：应用的数据源是一个本地数据库，它要么打开、要么打不开。打不开时，
/// 每个列表页——主机、凭据、片段、已知主机密钥——会无解释地转圈将近一分钟，之后才终于
/// 显示那个早就准备好渲染的错误分支。
///
/// Retrying is still worth doing, briefly: a database can be locked for a moment
/// by a backup or a restore. Three attempts over ~1.4 s rides that out, and then
/// the error surfaces immediately and the retry button on the screen does the
/// job properly — with the user watching, instead of behind a spinner.
/// 短暂重试仍然值得：数据库可能因备份或恢复被锁住一瞬。三次尝试约 1.4 秒足以挺过去，
/// 之后错误立刻显现，由界面上的重试按钮正经地重试——用户看得见，而不是被转圈挡住。
///
/// Note the default policy already declines to retry `Error` types; this only
/// changes the `Exception` path, which is what a failed platform call throws.
/// 注意默认策略本就不重试 `Error` 类型；这里只改变 `Exception` 路径，也就是平台调用
/// 失败时实际抛出的那一类。
Duration? _retryFailedProvider(int retryCount, Object error) {
  const maxAttempts = 3;
  if (retryCount >= maxAttempts) return null;
  return Duration(milliseconds: 200 * (1 << retryCount));
}

/// App entry point. Initializes Flutter bindings, sets a transparent status bar
/// with light icons, then runs the app wrapped in a Riverpod ProviderScope.
/// 应用入口。初始化 Flutter 绑定，设置透明状态栏和浅色图标，然后用 Riverpod
/// ProviderScope 包裹运行应用。
void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
    ),
  );
  runApp(const ProviderScope(retry: _retryFailedProvider, child: NekoMuxApp()));
}
