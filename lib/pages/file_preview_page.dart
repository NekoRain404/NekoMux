import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../core/i18n/strings.dart';
import '../widgets/app_ui.dart';

/// Page for previewing and optionally editing the content of a text file.
class FilePreviewPage extends StatefulWidget {
  /// The display name of the file (shown in the app bar).
  final String filename;

  /// The full text content of the file.
  final String content;

  /// Optional callback invoked when the user saves edits.
  final void Function(String newContent)? onSave;

  const FilePreviewPage({
    super.key,
    required this.filename,
    required this.content,
    this.onSave,
  });

  @override
  State<FilePreviewPage> createState() => _FilePreviewPageState();
}

class _FilePreviewPageState extends State<FilePreviewPage> {
  /// Whether the page is currently in edit mode.
  bool _isEditing = false;
  bool _isSaving = false;
  bool _isHandlingBack = false;

  /// Controller for the editable text field.
  late TextEditingController _controller;
  late String _savedContent;

  @override
  void initState() {
    super.initState();
    _savedContent = widget.content;
    _controller = TextEditingController(text: widget.content);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  bool get _hasUnsavedChanges => _controller.text != _savedContent;

  Future<void> _toggleEdit() async {
    if (_isEditing && _hasUnsavedChanges) {
      final discard = await _confirmDiscardChanges();
      if (!discard) return;
    }
    setState(() {
      if (_isEditing) {
        _controller.text = _savedContent;
      }
      _isEditing = !_isEditing;
    });
  }

  /// Invokes the onSave callback with the current editor content and returns to view mode.
  Future<void> _save() async {
    if (widget.onSave == null || _isSaving) return;
    setState(() => _isSaving = true);
    try {
      await Future.sync(() => widget.onSave!(_controller.text));
      if (mounted) {
        setState(() {
          _savedContent = _controller.text;
          _isEditing = false;
        });
      }
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  Future<bool> _confirmDiscardChanges() async {
    return showAppConfirmDialog(
      context,
      title: t('discard_changes_title'),
      message: t('discard_changes_body'),
      cancelLabel: t('cancel'),
      confirmLabel: t('discard'),
      destructive: true,
    );
  }

  Future<void> _handleBack() async {
    if (_isHandlingBack) return;
    _isHandlingBack = true;
    if (_isEditing && _hasUnsavedChanges) {
      final discard = await _confirmDiscardChanges();
      if (!discard) {
        _isHandlingBack = false;
        return;
      }
    }
    if (mounted) Navigator.pop(context);
    _isHandlingBack = false;
  }

  void _copyContent() {
    Clipboard.setData(ClipboardData(text: _controller.text));
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(t('copied'))));
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _handleBack();
      },
      child: Scaffold(
        backgroundColor: Theme.of(context).scaffoldBackgroundColor,
        appBar: AppBar(
          leading: IconButton(
            icon: Icon(Icons.arrow_back, color: cs.onSurface),
            onPressed: _handleBack,
          ),
          title: Text(
            widget.filename,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: cs.onSurface),
          ),
          actions: [
            if (_isEditing && widget.onSave != null)
              IconButton(
                icon: _isSaving
                    ? SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: cs.secondary,
                        ),
                      )
                    : Icon(Icons.save_outlined, color: cs.secondary),
                tooltip: t('save'),
                onPressed: _isSaving ? null : _save,
              ),
            IconButton(
              icon: Icon(
                Icons.copy_outlined,
                color: cs.onSurface.withValues(alpha: 0.64),
              ),
              tooltip: t('copy'),
              onPressed: _copyContent,
            ),
            if (widget.onSave != null)
              IconButton(
                icon: Icon(
                  _isEditing ? Icons.close : Icons.edit_outlined,
                  color: _isEditing ? cs.error : cs.secondary,
                ),
                tooltip: _isEditing ? t('cancel') : t('edit'),
                onPressed: _toggleEdit,
              )
            else
              const SizedBox(width: 4),
          ],
        ),
        body: Column(
          children: [
            _buildMetaBar(),
            Expanded(child: _isEditing ? _buildEditor() : _buildViewer()),
          ],
        ),
      ),
    );
  }

  Widget _buildMetaBar() {
    final cs = Theme.of(context).colorScheme;
    final lineCount = _controller.text.isEmpty
        ? 0
        : '\n'.allMatches(_controller.text).length + 1;
    final chars = _controller.text.characters.length;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: cs.surface,
        border: Border(
          bottom: BorderSide(color: Theme.of(context).dividerColor),
        ),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            AppBadge(
              icon: Icons.notes_outlined,
              label: t('file_lines').replaceAll('{0}', '$lineCount'),
              color: cs.onSurface.withValues(alpha: 0.56),
            ),
            const SizedBox(width: 8),
            AppBadge(
              icon: Icons.text_fields,
              label: t('file_chars').replaceAll('{0}', '$chars'),
              color: cs.onSurface.withValues(alpha: 0.56),
            ),
            if (_isEditing && _hasUnsavedChanges) ...[
              const SizedBox(width: 8),
              AppBadge(
                icon: Icons.circle,
                label: t('edit'),
                color: cs.secondary,
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// Builds a read-only, scrollable, selectable text viewer.
  Widget _buildViewer() {
    final cs = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      color: cs.surface.withValues(alpha: 0.48),
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        scrollDirection: Axis.vertical,
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: SelectableText(
            _controller.text,
            style: TextStyle(
              color: cs.onSurface,
              fontFamily: 'monospace',
              fontSize: 14,
              height: 1.6,
            ),
          ),
        ),
      ),
    );
  }

  /// Builds a full-screen monospace text editor.
  Widget _buildEditor() {
    final cs = Theme.of(context).colorScheme;
    return Container(
      color: cs.surface.withValues(alpha: 0.48),
      child: TextField(
        controller: _controller,
        autofocus: true,
        maxLines: null,
        expands: true,
        textAlignVertical: TextAlignVertical.top,
        style: TextStyle(
          color: cs.onSurface,
          fontFamily: 'monospace',
          fontSize: 14,
          height: 1.6,
        ),
        decoration: const InputDecoration(
          border: InputBorder.none,
          contentPadding: EdgeInsets.all(16),
        ),
        cursorColor: cs.secondary,
        onChanged: (_) => setState(() {}),
      ),
    );
  }
}
