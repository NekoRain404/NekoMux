import 'package:flutter/material.dart';

import '../../core/i18n/strings.dart';
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

/// Localised type label for [file], for the list badge and the actions sheet.
/// [file] 的本地化类型标签，用于列表徽标与操作面板。
///
/// This is where a [FileCategory] becomes a word. The model exposes only the
/// category, so the same build reads as "文件夹" in Chinese and "Folder" in
/// English without the model knowing that either language exists — which is the
/// bug this replaced: the label used to be composed inside the model, in
/// Chinese, for all eight shipped languages.
/// 这里是 [FileCategory] 变成文字的地方。模型只暴露类别，因此同一份构建在中文下读作
/// 「文件夹」、英文下读作 "Folder"，而模型并不知道存在这两种语言——这正是被修复的
/// 缺陷：标签此前在模型内部以中文组装，对全部八种语言一视同仁。
String sftpFileTypeLabel(FileItem file) {
  switch (file.category) {
    case FileCategory.folder:
      return t('file_type_folder');
    case FileCategory.html:
      return t('file_type_html');
    case FileCategory.php:
      return t('file_type_php');
    case FileCategory.python:
      return t('file_type_python');
    case FileCategory.js:
      return t('file_type_js');
    case FileCategory.css:
      return t('file_type_css');
    case FileCategory.archive:
      return t('file_type_archive');
    case FileCategory.image:
      return t('file_type_image');
    case FileCategory.log:
      return t('file_type_log');
    case FileCategory.config:
      return t('file_type_config');
    case FileCategory.other:
      // An extension this app has no word for is shown as itself, upper-cased —
      // `.rs` reads `RS` in every language. That is a legitimate un-translated
      // display, not a missing translation, and it is why the model still
      // cannot supply this: only the view knows which file names it was given.
      // 本应用没有对应词条的扩展名按其自身大写显示——`.rs` 在每种语言下都是 `RS`。
      // 这是合理的非翻译展示，而不是翻译缺失；也正因如此模型仍然提供不了它：只有
      // 视图知道自己收到了哪些文件名。
      return sftpExtension(file.name).toUpperCase();
  }
}

/// One-line summary of [file] for the actions sheet header.
/// 操作面板标题中 [file] 的一行摘要。
String sftpFileSubtitle(FileItem file) {
  if (file.isDirectory) return file.permissions;
  return '${file.displaySize} · ${sftpFileTypeLabel(file)} · ${file.permissions}';
}
