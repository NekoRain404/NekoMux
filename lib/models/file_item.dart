/// Data model representing a file or directory item in the SFTP file browser.
/// 表示 SFTP 文件浏览器中文件或目录项的数据模型。
class FileItem {
  /// Display name of the file or directory.
  /// 文件或目录的显示名称。
  final String name;

  /// Full remote path of the file or directory.
  /// 文件或目录的完整远程路径。
  final String path;

  /// Whether this item is a directory (true) or a regular file (false).
  /// 此项是否为目录（true）或普通文件（false）。
  final bool isDirectory;

  /// File size in bytes (ignored for directories).
  /// 文件大小（字节），目录忽略此值。
  final int size;

  /// Unix-style permission string (e.g., "rw-r--r--").
  /// Unix 风格的权限字符串（如 "rw-r--r--"）。
  final String permissions;

  /// Last modification timestamp of the file or directory.
  /// 文件或目录的最后修改时间戳。
  final DateTime modifiedDate;

  const FileItem({
    required this.name,
    required this.path,
    this.isDirectory = false,
    this.size = 0,
    this.permissions = 'rw-r--r--',
    required this.modifiedDate,
  });

  /// Returns a human-readable file size string (B / KB / MB / GB).
  /// Returns "--" for directories.
  /// 返回可读的文件大小字符串（B / KB / MB / GB）。
  /// 目录返回 "--"。
  String get displaySize {
    if (isDirectory) return '--';
    if (size < 1024) return '$size B';
    if (size < 1024 * 1024) return '${(size / 1024).toStringAsFixed(1)} KB';
    if (size < 1024 * 1024 * 1024) {
      return '${(size / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(size / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }

  /// Returns a localized file type label based on the file extension.
  /// 根据文件扩展名返回本地化的文件类型标签。
  String get fileType {
    if (isDirectory) return '文件夹';
    final ext = name.split('.').last.toLowerCase();
    switch (ext) {
      case 'html':
      case 'htm':
        return 'HTML 文档';
      case 'php':
        return 'PHP 脚本';
      case 'py':
        return 'Python 脚本';
      case 'js':
        return 'JavaScript';
      case 'css':
        return 'CSS 样式';
      case 'tar':
      case 'gz':
      case 'zip':
      case 'rar':
        return '压缩包';
      case 'png':
      case 'jpg':
      case 'jpeg':
      case 'gif':
        return '图片';
      case 'log':
        return '日志文件';
      case 'conf':
      case 'cfg':
        return '配置文件';
      default:
        return ext.toUpperCase();
    }
  }
}
