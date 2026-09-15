// Remote path arithmetic and breadcrumb construction for the SFTP page.
// SFTP 页面的远程路径运算与面包屑构造。
//
// Everything here is a pure function of its arguments, so the rules that decide
// which directory the user is looking at can be tested without a widget, a
// connection, or a remote server.
// 这里的每个函数都只依赖入参，因此「用户当前在哪个目录」这类规则无需 widget、
// 连接或远端服务器即可测试。

import '../../core/i18n/strings.dart';

/// Extensions the file manager offers to preview as text.
/// 文件管理器允许按文本预览的扩展名。
///
/// The rule is "likely to be a text file", not "decodes as UTF-8". Remote
/// `log`, `conf`, `ini` and `sh` files on a Chinese-locale server are routinely
/// GBK or Latin-1, so the decision must not depend on the file's bytes — those
/// are handled when the content is decoded.
/// 判据是「多半是文本文件」，而非「能以 UTF-8 解码」。中文环境下服务器上的
/// `log`、`conf`、`ini`、`sh` 常常是 GBK 或 Latin-1，因此判断不能依赖文件字节；
/// 编码问题在解码内容时处理。
const Set<String> sftpTextExtensions = {
  'txt',
  'json',
  'conf',
  'log',
  'yml',
  'yaml',
  'xml',
  'ini',
  'sh',
  'py',
  'js',
  'css',
  'html',
  'php',
  'md',
};

/// Lower-cased extension of [name] for extension-based decisions.
/// 取 [name] 的小写扩展名，用于按扩展名做判断。
///
/// Deliberately keeps the file manager's long-standing rule: the text after the
/// last dot, or the whole name when there is none — so a file literally named
/// `log` is still treated as a log file, exactly as before this was extracted.
/// 有意沿用文件管理器一直以来的规则：取最后一个点之后的部分，没有点则取整个名字——
/// 因此一个名叫 `log` 的文件仍被当作日志文件，与抽取之前完全一致。
String sftpExtension(String name) {
  final dot = name.lastIndexOf('.');
  return (dot < 0 ? name : name.substring(dot + 1)).toLowerCase();
}

/// Whether [name] should open in the text preview rather than the file actions.
/// [name] 是否应直接用文本预览打开，而不是弹出文件操作菜单。
bool isSftpTextFile(String name) =>
    sftpTextExtensions.contains(sftpExtension(name));

/// Last segment of [path], used as the display name of a selected entry.
/// [path] 的最后一段，用作已选条目的显示名。
String sftpBaseName(String path) {
  final slash = path.lastIndexOf('/');
  return slash < 0 ? path : path.substring(slash + 1);
}

/// Joins [name] onto [parent] without doubling the separator.
/// 将 [name] 拼接到 [parent] 下，且不重复分隔符。
String sftpChildPath(String parent, String name) =>
    parent.endsWith('/') ? '$parent$name' : '$parent/$name';

/// One tappable segment of the path bar.
/// 路径栏上一个可点击的片段。
class SftpCrumb {
  /// Text rendered for this segment (already stripped of decoration).
  /// 该片段显示的文本（已去掉装饰性字符）。
  final String label;

  /// Absolute remote path this segment navigates to.
  /// 该片段导航到的远程绝对路径。
  final String path;

  const SftpCrumb({required this.label, required this.path});

  @override
  bool operator ==(Object other) =>
      other is SftpCrumb && other.label == label && other.path == path;

  @override
  int get hashCode => Object.hash(label, path);

  @override
  String toString() => 'SftpCrumb($label -> $path)';
}

/// Builds the breadcrumb trail for [path]: the root first, [path] last.
/// 构造 [path] 的面包屑路径：根目录在前，[path] 在最后。
///
/// The trail is derived from the path on every build instead of being appended
/// to while navigating. That is what keeps the path bar and the listing from
/// being able to disagree: there is only one source of truth, and the bar cannot
/// show a segment the page no longer has a directory for.
/// 面包屑每次构建时都由路径推导，而不是在导航过程中追加。这正是路径栏与列表
/// 无法互相矛盾的原因：只有一份事实来源，路径栏也不可能显示出页面并不存在的目录。
List<SftpCrumb> sftpBreadcrumbs(String path) {
  final crumbs = <SftpCrumb>[
    // The stored label carries a house emoji that the path bar never showed;
    // strip it here so the widget stays free of display fix-ups.
    // 存储的文案带有房屋 emoji，而路径栏从不显示它；在此去掉，
    // 让 widget 不再需要做显示层的修补。
    SftpCrumb(label: t('root_dir').replaceFirst('🏠 ', ''), path: '/'),
  ];

  final buffer = StringBuffer();
  for (final segment in path.split('/')) {
    if (segment.isEmpty) continue;
    buffer.write('/$segment');
    crumbs.add(SftpCrumb(label: segment, path: buffer.toString()));
  }
  return crumbs;
}
