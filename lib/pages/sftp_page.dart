import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/i18n/strings.dart';
import '../models/credential.dart';
import '../models/file_item.dart';
import '../models/host.dart';
import '../providers/providers.dart';
import '../services/host_key_verifier.dart';
import '../services/sftp_service.dart';
import '../widgets/app_ui.dart';
import 'file_preview_page.dart';

const _textExtensions = {
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

/// SFTP file manager with directory browsing and file operations.
class SftpPage extends ConsumerStatefulWidget {
  final Host host;
  final Credential? credential;

  const SftpPage({super.key, required this.host, this.credential});

  @override
  ConsumerState<SftpPage> createState() => _SftpPageState();
}

class _SftpPageState extends ConsumerState<SftpPage> {
  SftpService? _sftpService;
  bool _isConnecting = true;
  bool _isLoadingDir = false;
  String? _errorMessage;
  String _currentPath = '/';
  List<String> _breadcrumbs = [t('root_dir')];
  List<FileItem> _files = [];
  final Set<String> _selectedPaths = {};
  bool _isSelectionMode = false;

  @override
  void initState() {
    super.initState();
    _breadcrumbs = [t('root_dir')];
    WidgetsBinding.instance.addPostFrameCallback((_) => _resolveAndConnect());
  }

  Future<void> _resolveAndConnect() async {
    var cred = widget.credential;
    if (cred == null) {
      final allCreds = await ref.read(credentialListProvider.future);
      cred = allCreds
          .where((c) => c.id == widget.host.credentialId)
          .firstOrNull;
    }
    if (cred == null) {
      setState(() {
        _isConnecting = false;
        _errorMessage = t('credential_not_found');
      });
      return;
    }
    _sftpService = SftpService(
      host: widget.host,
      credential: cred,
      onHostKeyVerify: (fingerprint) async {
        if (HostKeyVerifier.isAccepted(fingerprint)) return true;
        final accepted = await _showHostKeyDialog(fingerprint);
        if (accepted) HostKeyVerifier.accept(fingerprint);
        return accepted;
      },
    );
    _connect();
  }

  @override
  void dispose() {
    _sftpService?.disconnect();
    super.dispose();
  }

  Future<void> _connect() async {
    setState(() {
      _isConnecting = true;
      _errorMessage = null;
    });
    try {
      await _sftpService!.connect();
      await _loadFilesForPath('/');
    } on SftpException catch (e) {
      setState(() => _errorMessage = e.message);
    } catch (e) {
      setState(() => _errorMessage = '${t('connection_failed')}：$e');
    } finally {
      setState(() => _isConnecting = false);
    }
  }

  Future<void> _retry() async {
    await _sftpService?.disconnect();
    await _resolveAndConnect();
  }

  Future<bool> _showHostKeyDialog(String fingerprint) async {
    final cs = Theme.of(context).colorScheme;
    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: cs.surface,
        title: Text(
          t('host_key_verify'),
          style: TextStyle(color: cs.onSurface),
        ),
        content: SelectableText(
          fingerprint,
          style: TextStyle(color: cs.primary, fontFamily: 'monospace'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(t('reject'), style: TextStyle(color: cs.error)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(t('accept'), style: TextStyle(color: cs.primary)),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  Future<void> _loadFilesForPath(String path) async {
    setState(() {
      _isLoadingDir = true;
      _errorMessage = null;
      _currentPath = path;
    });
    try {
      final entries = await _sftpService!.listDirectory(path);
      entries.sort((a, b) {
        if (a.isDirectory && !b.isDirectory) return -1;
        if (!a.isDirectory && b.isDirectory) return 1;
        return a.name.compareTo(b.name);
      });
      setState(() => _files = entries);
    } on SftpException catch (e) {
      setState(() => _errorMessage = e.message);
    } catch (e) {
      setState(() => _errorMessage = '${t('list_failed')}：$e');
    } finally {
      setState(() => _isLoadingDir = false);
    }
  }

  void _navigateTo(String segment, String path) {
    setState(() => _breadcrumbs.add(segment));
    _loadFilesForPath(path);
  }

  void _navigateToCrumb(int index) {
    if (index == _breadcrumbs.length - 1) return;
    final parts = _breadcrumbs.sublist(1, index + 1);
    final path = '/${parts.join('/')}';
    setState(() => _breadcrumbs = _breadcrumbs.sublist(0, index + 1));
    _loadFilesForPath(path);
  }

  Future<void> _openFile(FileItem file) async {
    try {
      final bytes = await _sftpService!.readFile(file.path);
      if (!mounted) return;
      final content = utf8.decode(bytes);

      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => FilePreviewPage(
            filename: file.name,
            content: content,
            onSave: (newContent) async {
              try {
                await _sftpService!.writeFile(
                  file.path,
                  Uint8List.fromList(utf8.encode(newContent)),
                );
                if (mounted) _showSnack(t('file_saved'));
              } on SftpException catch (e) {
                if (mounted) _showSnack(e.message, isError: true);
              }
            },
          ),
        ),
      );
    } on SftpException catch (e) {
      if (mounted) _showSnack(e.message, isError: true);
    }
  }

  bool _isTextFile(FileItem file) {
    final ext = file.name.split('.').last.toLowerCase();
    return _textExtensions.contains(ext);
  }

  String _childPath(String name) =>
      _currentPath.endsWith('/') ? '$_currentPath$name' : '$_currentPath/$name';

  void _showSnack(String message, {bool isError = false}) {
    final cs = Theme.of(context).colorScheme;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isError ? cs.error : cs.primary,
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.all(16),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
    );
  }

  void _enterSelectionMode(String path) {
    setState(() {
      _isSelectionMode = true;
      _selectedPaths.add(path);
    });
  }

  void _exitSelectionMode() {
    setState(() {
      _isSelectionMode = false;
      _selectedPaths.clear();
    });
  }

  void _toggleSelection(String path) {
    setState(() {
      if (_selectedPaths.contains(path)) {
        _selectedPaths.remove(path);
        if (_selectedPaths.isEmpty) _isSelectionMode = false;
      } else {
        _selectedPaths.add(path);
      }
    });
  }

  Future<void> _showBatchDeleteConfirm() async {
    final names = _selectedPaths.map((p) => p.split('/').last).join('、');
    final confirmed = await showAppConfirmDialog(
      context,
      title: t('batch_delete'),
      message: t('batch_delete_confirm')
          .replaceAll('{0}', _selectedPaths.length.toString())
          .replaceAll('{1}', names),
      cancelLabel: t('cancel'),
      confirmLabel: t('delete'),
      destructive: true,
    );
    if (!confirmed || !mounted) return;

    final paths = List<String>.from(_selectedPaths);
    _exitSelectionMode();
    for (final path in paths) {
      try {
        await _sftpService!.deleteFile(path);
      } on SftpException catch (e) {
        if (mounted) _showSnack(e.message, isError: true);
      }
    }
    await _loadFilesForPath(_currentPath);
    if (mounted) _showSnack(t('file_deleted'));
  }

  void _showNewDialog() {
    final cs = Theme.of(context).colorScheme;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: cs.surface,
        title: Text(t('new_file'), style: TextStyle(color: cs.onSurface)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AppCard(
              margin: EdgeInsets.zero,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              onTap: () {
                Navigator.pop(ctx);
                _showCreateFileDialog();
              },
              child: Row(
                children: [
                  Icon(Icons.insert_drive_file_outlined, color: cs.secondary),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      t('new_file_item'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: cs.onSurface),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            AppCard(
              margin: EdgeInsets.zero,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              onTap: () {
                Navigator.pop(ctx);
                _showCreateFolderDialog();
              },
              child: Row(
                children: [
                  Icon(Icons.folder_outlined, color: cs.primary),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      t('new_folder'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: cs.onSurface),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  InputDecoration _dialogInputDecoration(String hint) {
    final cs = Theme.of(context).colorScheme;
    return InputDecoration(
      hintText: hint,
      hintStyle: TextStyle(color: cs.onSurface.withValues(alpha: 0.6)),
      filled: true,
      fillColor: Theme.of(context).scaffoldBackgroundColor,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide(color: Theme.of(context).dividerColor),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide(color: cs.secondary, width: 1.5),
      ),
    );
  }

  void _showCreateFileDialog() {
    final cs = Theme.of(context).colorScheme;
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: cs.surface,
        title: Text(t('new_file_item'), style: TextStyle(color: cs.onSurface)),
        content: TextField(
          controller: controller,
          autofocus: true,
          style: TextStyle(color: cs.onSurface),
          cursorColor: cs.secondary,
          decoration: _dialogInputDecoration(t('input_filename')),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(
              t('cancel'),
              style: TextStyle(color: cs.onSurface.withValues(alpha: 0.6)),
            ),
          ),
          TextButton(
            onPressed: () async {
              final name = controller.text.trim();
              if (name.isEmpty) {
                Navigator.pop(ctx);
                return;
              }
              Navigator.pop(ctx);
              final filePath = _childPath(name);
              try {
                await _sftpService!.writeFile(filePath, Uint8List(0));
                await _loadFilesForPath(_currentPath);
                if (mounted) _showSnack(t('file_created'));
              } on SftpException catch (e) {
                if (mounted) _showSnack(e.message, isError: true);
              }
            },
            child: Text(t('create'), style: TextStyle(color: cs.secondary)),
          ),
        ],
      ),
    );
  }

  void _showCreateFolderDialog() {
    final cs = Theme.of(context).colorScheme;
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: cs.surface,
        title: Text(t('new_folder'), style: TextStyle(color: cs.onSurface)),
        content: TextField(
          controller: controller,
          autofocus: true,
          style: TextStyle(color: cs.onSurface),
          cursorColor: cs.secondary,
          decoration: _dialogInputDecoration(t('input_foldername')),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(
              t('cancel'),
              style: TextStyle(color: cs.onSurface.withValues(alpha: 0.6)),
            ),
          ),
          TextButton(
            onPressed: () async {
              final name = controller.text.trim();
              if (name.isEmpty) {
                Navigator.pop(ctx);
                return;
              }
              Navigator.pop(ctx);
              final dirPath = _childPath(name);
              try {
                await _sftpService!.createDirectory(dirPath);
                await _loadFilesForPath(_currentPath);
                if (mounted) _showSnack(t('folder_created'));
              } on SftpException catch (e) {
                if (mounted) _showSnack(e.message, isError: true);
              }
            },
            child: Text(t('create'), style: TextStyle(color: cs.secondary)),
          ),
        ],
      ),
    );
  }

  void _showFileActions(FileItem file) {
    final cs = Theme.of(context).colorScheme;
    showModalBottomSheet(
      context: context,
      backgroundColor: cs.surface,
      showDragHandle: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(8)),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              AppCard(
                margin: EdgeInsets.zero,
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
                child: Row(
                  children: [
                    AppIconBox(
                      icon: _fileIcon(file),
                      color: _fileIconColor(file),
                      size: 40,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            file.name,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: cs.onSurface,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            file.isDirectory
                                ? file.permissions
                                : '${file.displaySize} · ${file.fileType} · ${file.permissions}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: cs.onSurface.withValues(alpha: 0.55),
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              if (!file.isDirectory)
                _ActionTile(
                  icon: Icons.open_in_new,
                  label: t('open_file'),
                  color: _isTextFile(file)
                      ? cs.secondary
                      : cs.onSurface.withValues(alpha: 0.38),
                  onTap: () {
                    Navigator.pop(ctx);
                    if (_isTextFile(file)) {
                      _openFile(file);
                    } else {
                      _showSnack(t('binary_file_hint'));
                    }
                  },
                ),
              _ActionTile(
                icon: Icons.drive_file_rename_outline,
                label: t('rename'),
                color: cs.primary,
                onTap: () {
                  Navigator.pop(ctx);
                  _showRenameDialog(file);
                },
              ),
              _ActionTile(
                icon: Icons.check_box_outlined,
                label: t('selected'),
                color: cs.secondary,
                onTap: () {
                  Navigator.pop(ctx);
                  _enterSelectionMode(file.path);
                },
              ),
              _ActionTile(
                icon: Icons.delete_outline,
                label: t('delete'),
                color: cs.error,
                onTap: () {
                  Navigator.pop(ctx);
                  _confirmDeleteFile(file);
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showRenameDialog(FileItem file) {
    final cs = Theme.of(context).colorScheme;
    final controller = TextEditingController(text: file.name);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: cs.surface,
        title: Text(t('rename'), style: TextStyle(color: cs.onSurface)),
        content: TextField(
          controller: controller,
          autofocus: true,
          style: TextStyle(color: cs.onSurface),
          cursorColor: cs.secondary,
          decoration: _dialogInputDecoration(file.name),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(t('cancel')),
          ),
          TextButton(
            onPressed: () async {
              final name = controller.text.trim();
              if (name.isEmpty || name == file.name) {
                Navigator.pop(ctx);
                return;
              }
              Navigator.pop(ctx);
              try {
                await _sftpService!.rename(file.path, _childPath(name));
                await _loadFilesForPath(_currentPath);
                if (mounted) _showSnack(t('file_renamed'));
              } on SftpException catch (e) {
                if (mounted) _showSnack(e.message, isError: true);
              }
            },
            child: Text(t('confirm'), style: TextStyle(color: cs.secondary)),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmDeleteFile(FileItem file) async {
    final confirmed = await showAppConfirmDialog(
      context,
      title: t('confirm_delete'),
      message: t('confirm_delete_file').replaceAll('{0}', file.name),
      cancelLabel: t('cancel'),
      confirmLabel: t('delete'),
      destructive: true,
    );
    if (!confirmed || !mounted) return;

    try {
      await _sftpService!.deleteFile(file.path);
      await _loadFilesForPath(_currentPath);
      if (mounted) _showSnack(t('file_deleted'));
    } on SftpException catch (e) {
      if (mounted) _showSnack(e.message, isError: true);
    }
  }

  IconData _fileIcon(FileItem file) {
    if (file.isDirectory) return Icons.folder_outlined;
    final ext = file.name.split('.').last.toLowerCase();
    switch (ext) {
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

  Color _fileIconColor(FileItem file) {
    final cs = Theme.of(context).colorScheme;
    if (file.isDirectory) return cs.secondary;
    final ext = file.name.split('.').last.toLowerCase();
    switch (ext) {
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

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(
        backgroundColor: cs.surface,
        leading: IconButton(
          icon: Icon(
            Icons.arrow_back,
            color: cs.onSurface.withValues(alpha: 0.7),
          ),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text(
          t('file_manager_title'),
          style: TextStyle(color: cs.onSurface),
        ),
        actions: [
          if (!_isConnecting)
            IconButton(
              icon: Icon(
                Icons.refresh,
                color: cs.onSurface.withValues(alpha: 0.72),
                size: 22,
              ),
              tooltip: t('refresh'),
              onPressed: _isLoadingDir
                  ? null
                  : () => _loadFilesForPath(_currentPath),
            ),
          if (!_isConnecting)
            IconButton(
              icon: Icon(Icons.add, color: cs.secondary, size: 22),
              tooltip: t('new_file'),
              onPressed: _showNewDialog,
            ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    final cs = Theme.of(context).colorScheme;
    if (_isConnecting) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(color: cs.secondary),
            const SizedBox(height: 16),
            Text(
              t('connecting'),
              style: TextStyle(
                color: cs.onSurface.withValues(alpha: 0.6),
                fontSize: 14,
              ),
            ),
          ],
        ),
      );
    }

    if (_errorMessage != null && _files.isEmpty) {
      return Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.cloud_off, size: 56, color: cs.error),
              const SizedBox(height: 16),
              Text(
                _errorMessage!,
                textAlign: TextAlign.center,
                maxLines: 6,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: cs.onSurface.withValues(alpha: 0.6),
                  fontSize: 14,
                ),
              ),
              const SizedBox(height: 24),
              ElevatedButton.icon(
                onPressed: _retry,
                icon: const Icon(Icons.refresh, size: 18),
                label: Text(
                  t('retry'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: cs.secondary,
                  foregroundColor: Theme.of(context).scaffoldBackgroundColor,
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Column(
      children: [
        _buildBreadcrumb(),
        Divider(height: 1, color: Theme.of(context).dividerColor),
        Expanded(child: _buildFileList()),
        if (_isSelectionMode) _buildSelectionBar() else _buildUploadBar(),
      ],
    );
  }

  Widget _buildBreadcrumb() {
    final cs = Theme.of(context).colorScheme;
    return Container(
      color: cs.surface,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            if (_isSelectionMode)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: GestureDetector(
                  onTap: _exitSelectionMode,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: cs.error.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      t('cancel'),
                      style: TextStyle(
                        color: cs.error,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              ),
            for (int i = 0; i < _breadcrumbs.length; i++) ...[
              if (i > 0)
                Icon(
                  Icons.chevron_right,
                  size: 16,
                  color: cs.onSurface.withValues(alpha: 0.3),
                ),
              GestureDetector(
                onTap: () => _navigateToCrumb(i),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: i == _breadcrumbs.length - 1
                        ? cs.secondary.withValues(alpha: 0.1)
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 180),
                    child: Text(
                      _breadcrumbs[i].replaceFirst('🏠 ', ''),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: i == _breadcrumbs.length - 1
                            ? cs.secondary
                            : cs.onSurface.withValues(alpha: 0.6),
                        fontSize: 13,
                        fontWeight: i == _breadcrumbs.length - 1
                            ? FontWeight.w600
                            : FontWeight.normal,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildFileList() {
    final cs = Theme.of(context).colorScheme;
    final dividerColor = Theme.of(context).dividerColor;
    if (_isLoadingDir) {
      return Center(child: CircularProgressIndicator(color: cs.secondary));
    }

    if (_files.isEmpty) {
      return AppEmptyState(
        icon: Icons.folder_open_outlined,
        title: t('empty_dir'),
        message: t('empty_dir_hint'),
        actionLabel: t('new_file'),
        onAction: _showNewDialog,
        color: cs.primary,
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: _files.length,
      itemBuilder: (context, index) {
        final file = _files[index];
        final isSelected = _selectedPaths.contains(file.path);

        final VoidCallback? onTap;
        if (_isSelectionMode) {
          onTap = () => _toggleSelection(file.path);
        } else if (file.isDirectory) {
          onTap = () => _navigateTo(file.name, file.path);
        } else if (_isTextFile(file)) {
          onTap = () => _openFile(file);
        } else {
          onTap = () => _showFileActions(file);
        }

        return AppCard(
          margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          color: isSelected ? cs.secondary.withValues(alpha: 0.08) : cs.surface,
          borderColor: isSelected
              ? cs.secondary.withValues(alpha: 0.28)
              : dividerColor.withValues(alpha: 0.72),
          onTap: onTap,
          onLongPress: _isSelectionMode
              ? null
              : () => _enterSelectionMode(file.path),
          child: Row(
            children: [
              if (_isSelectionMode)
                SizedBox(
                  width: 40,
                  height: 40,
                  child: Checkbox(
                    value: isSelected,
                    onChanged: (_) => _toggleSelection(file.path),
                    activeColor: cs.secondary,
                    checkColor: Theme.of(context).scaffoldBackgroundColor,
                    side: BorderSide(
                      color: cs.onSurface.withValues(alpha: 0.24),
                      width: 1.5,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(6),
                    ),
                  ),
                )
              else
                AppIconBox(icon: _fileIcon(file), color: _fileIconColor(file)),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      file.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: cs.onSurface,
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            file.isDirectory ? '--' : file.displaySize,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: cs.onSurface.withValues(alpha: 0.6),
                              fontSize: 11,
                            ),
                          ),
                        ),
                        if (!file.isDirectory) ...[
                          const SizedBox(width: 8),
                          AppBadge(
                            label: file.fileType,
                            color: cs.onSurface.withValues(alpha: 0.42),
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 72),
                child: Text(
                  file.permissions,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: cs.onSurface.withValues(alpha: 0.36),
                    fontSize: 11,
                    fontFamily: 'monospace',
                  ),
                ),
              ),
              const SizedBox(width: 8),
              if (_isSelectionMode)
                const SizedBox(width: 18)
              else
                IconButton(
                  icon: Icon(
                    file.isDirectory ? Icons.chevron_right : Icons.more_vert,
                    size: 18,
                    color: cs.onSurface.withValues(alpha: 0.34),
                  ),
                  tooltip: file.isDirectory ? t('open_file') : t('tools'),
                  onPressed: file.isDirectory
                      ? () => _navigateTo(file.name, file.path)
                      : () => _showFileActions(file),
                  visualDensity: VisualDensity.compact,
                  constraints: const BoxConstraints(
                    minWidth: 32,
                    minHeight: 32,
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildSelectionBar() {
    final cs = Theme.of(context).colorScheme;
    final dividerColor = Theme.of(context).dividerColor;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: cs.surface,
        border: Border(top: BorderSide(color: dividerColor, width: 0.5)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              t(
                'selected_count',
              ).replaceAll('{0}', _selectedPaths.length.toString()),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: cs.secondary,
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Wrap(
              alignment: WrapAlignment.end,
              spacing: 8,
              runSpacing: 4,
              children: [
                TextButton.icon(
                  onPressed: _showBatchDeleteConfirm,
                  icon: Icon(Icons.delete_outline, color: cs.error, size: 18),
                  label: Text(
                    t('batch_delete'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: cs.error, fontSize: 13),
                  ),
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                  ),
                ),
                TextButton(
                  onPressed: _exitSelectionMode,
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                  ),
                  child: Text(
                    t('cancel'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: cs.onSurface.withValues(alpha: 0.6),
                      fontSize: 13,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildUploadBar() {
    final cs = Theme.of(context).colorScheme;
    final dividerColor = Theme.of(context).dividerColor;
    return Material(
      color: cs.surface,
      child: Container(
        width: double.infinity,
        padding: EdgeInsets.fromLTRB(
          16,
          10,
          16,
          10 + MediaQuery.of(context).padding.bottom,
        ),
        decoration: BoxDecoration(
          border: Border(top: BorderSide(color: dividerColor, width: 0.5)),
        ),
        child: Row(
          children: [
            AppIconBox(
              icon: Icons.upload_file,
              color: cs.onSurface.withValues(alpha: 0.38),
              size: 36,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                t('upload'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: cs.onSurface.withValues(alpha: 0.52),
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            AppBadge(
              label: t('upload_dev'),
              color: cs.onSurface.withValues(alpha: 0.42),
            ),
          ],
        ),
      ),
    );
  }
}

class _ActionTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;

  const _ActionTile({
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return AppCard(
      margin: const EdgeInsets.symmetric(vertical: 3),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
      onTap: onTap,
      child: Row(
        children: [
          Icon(icon, color: color, size: 21),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: color, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }
}
