/// Category of a [FileItem], derived from its name and kind.
/// [FileItem] 的类别，由其名称与种类推导。
///
/// A category, not a label: the words a user reads are chosen by the
/// presentation layer from the i18n table, so this enum carries no language at
/// all. That is what the model used to get wrong — `fileType` returned Chinese
/// words, which reached an English user verbatim in the file list and in every
/// file actions sheet.
/// 这是类别而非标签：用户读到的文字由展示层从 i18n 表中选择，因此本枚举不携带任何
/// 语言。这正是模型此前做错的地方——`fileType` 返回中文词，会原样出现在英文用户的
/// 文件列表和每一个文件操作面板里。
enum FileCategory {
  /// A directory.
  /// 目录。
  folder,

  /// `.html` / `.htm`.
  /// `.html` / `.htm`。
  html,

  /// `.php`.
  /// `.php`。
  php,

  /// `.py`.
  /// `.py`。
  python,

  /// `.js`.
  /// `.js`。
  js,

  /// `.css`.
  /// `.css`。
  css,

  /// `.tar` / `.gz` / `.zip` / `.rar`.
  /// `.tar` / `.gz` / `.zip` / `.rar`。
  archive,

  /// `.png` / `.jpg` / `.jpeg` / `.gif`.
  /// `.png` / `.jpg` / `.jpeg` / `.gif`。
  image,

  /// `.log`.
  /// `.log`。
  log,

  /// `.conf` / `.cfg`.
  /// `.conf` / `.cfg`。
  config,

  /// Any extension the table above does not recognise.
  /// 上表未识别的任何扩展名。
  other,
}

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

  /// Category this item belongs to.
  /// 此项所属的类别。
  ///
  /// Deliberately exposes a category rather than a label: turning
  /// [FileCategory.other] into the upper-cased extension, and every other value
  /// into a translated word, is a display decision and lives in
  /// `pages/sftp/sftp_file_visuals.dart`. A model that named those words itself
  /// could only ever name them in one language.
  /// 有意只暴露类别而非标签：把 [FileCategory.other] 变成大写的扩展名、把其余取值
  /// 变成翻译后的词，都是展示层的决定，位于 `pages/sftp/sftp_file_visuals.dart`。
  /// 模型若自己命名这些词，就只能命名一种语言。
  FileCategory get category {
    if (isDirectory) return FileCategory.folder;
    switch (_extension) {
      case 'html':
      case 'htm':
        return FileCategory.html;
      case 'php':
        return FileCategory.php;
      case 'py':
        return FileCategory.python;
      case 'js':
        return FileCategory.js;
      case 'css':
        return FileCategory.css;
      case 'tar':
      case 'gz':
      case 'zip':
      case 'rar':
        return FileCategory.archive;
      case 'png':
      case 'jpg':
      case 'jpeg':
      case 'gif':
        return FileCategory.image;
      case 'log':
        return FileCategory.log;
      case 'conf':
      case 'cfg':
        return FileCategory.config;
      default:
        return FileCategory.other;
    }
  }

  /// Lower-cased extension of [name]: the text after its last dot, or the whole
  /// name when there is none, so a file literally named `log` is a log file.
  /// [name] 的小写扩展名：最后一个点之后的部分，没有点则取整个名字，因此一个名叫
  /// `log` 的文件属于日志类。
  ///
  /// The same rule [FileCategory] is built on, and the same one
  /// `pages/sftp/sftp_path.dart`'s `sftpExtension` applies to render the
  /// unrecognised-extension fallback. The two must agree; this one cannot import
  /// that one, because a model may not depend on a page.
  /// 它与 [FileCategory] 基于同一条规则，也与 `pages/sftp/sftp_path.dart` 中
  /// `sftpExtension` 所采用的规则一致（后者用于渲染未识别扩展名的兜底显示）。两者
  /// 必须一致；但本方法不能引用后者，因为模型不得依赖页面。
  String get _extension {
    final dot = name.lastIndexOf('.');
    return (dot < 0 ? name : name.substring(dot + 1)).toLowerCase();
  }
}
