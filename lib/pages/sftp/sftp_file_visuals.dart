import 'package:flutter/material.dart';

import '../../models/file_item.dart';
import 'sftp_path.dart';

/// Icon and icon colour for a file-list entry.
/// 文件列表条目的图标与图标颜色。
///
/// Kept apart from the widgets that draw them because two surfaces need the very
/// same mapping: the list row and the header of the file actions sheet. Two
/// copies of this table would drift the moment either one is touched.
/// 单独成文件，是因为有两处界面需要完全相同的映射：列表行与文件操作面板的标题。
/// 两份副本只要动了一处就会开始不一致。

/// Glyph representing [file] by its extension.
/// 依据扩展名表示 [file] 的图标。
IconData sftpFileIcon(FileItem file) {
  if (file.isDirectory) return Icons.folder_outlined;
  switch (sftpExtension(file.name)) {
    case 'html':
    case 'htm':
      return Icons.code;
    case 'php':
    case 'py':
    case 'js':
      return Icons.terminal;
    case 'css':
      return Icons.style;
    case 'gz':
    case 'tar':
    case 'zip':
    case 'rar':
      return Icons.archive_outlined;
    case 'png':
    case 'jpg':
    case 'jpeg':
      return Icons.image_outlined;
    default:
      return Icons.insert_drive_file_outlined;
  }
}

/// Colour for [file]'s icon under [cs]; directories take the accent colour.
/// [file] 图标在 [cs] 下的颜色；目录使用强调色。
Color sftpFileIconColor(FileItem file, ColorScheme cs) {
  if (file.isDirectory) return cs.secondary;
  switch (sftpExtension(file.name)) {
    case 'html':
      return const Color(0xFFE34F26);
    case 'php':
      return const Color(0xFF777BB4);
    case 'css':
      return const Color(0xFF1572B6);
    case 'gz':
    case 'tar':
    case 'zip':
      return cs.primary;
    case 'png':
    case 'jpg':
      return const Color(0xFFD2A8FF);
    default:
      return cs.onSurface.withValues(alpha: 0.6);
  }
}

/// One-line summary of [file] for the actions sheet header.
/// 操作面板标题中 [file] 的一行摘要。
String sftpFileSubtitle(FileItem file) {
  if (file.isDirectory) return file.permissions;
  return '${file.displaySize} · ${file.fileType} · ${file.permissions}';
}
