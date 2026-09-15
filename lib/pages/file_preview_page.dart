import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../core/i18n/strings.dart';
import '../widgets/app_ui.dart';

/// Page for previewing and optionally editing the content of a text file.
/// 用于预览并可选择编辑文本文件内容的页面。
class FilePreviewPage extends StatefulWidget {
  /// Largest file content this page is willing to render, in UTF-16 code units.
  /// 本页面愿意渲染的最大文件内容，单位为 UTF-16 码元。
  ///
  /// The page hands the whole file to one [SelectableText] / [TextField], and
  /// the text engine lays it out as a single span: both the first paint and
  /// every relayout afterwards cost time proportional to the file, not to the
  /// part of it on screen. The file manager opens `log` files as text, so
  /// tapping a multi-hundred-megabyte `/var/log` file is an ordinary action
  /// that ends in a frozen UI or an OOM kill — the page, the text engine and
  /// the clipboard would each try to hold the entire content.
  /// 本页面把整个文件交给单个 [SelectableText] / [TextField]，文本引擎会将其作为
  /// 单个 span 排版：首次绘制以及之后每次重排的耗时都与文件大小成正比，而非与屏幕
  /// 上可见的部分相关。文件管理器会把 `log` 当作文本打开，因此点击一个几百 MB 的
  /// `/var/log` 文件是很平常的操作，却会让界面卡死或被系统 OOM 杀掉。
  ///
  /// 1 MiB (1,048,576) sits between the two populations this page is opened on:
  /// hand-edited text — `conf`, `sh`, `json`, `md`, `env` — is almost always
  /// far below 100 KiB, while a log worth opening is well above 10 MiB. Any
  /// cutoff in the 256 KiB–2 MiB band separates them; 1 MiB leaves the larger
  /// margin on the side where being wrong is expensive.
  /// 1 MiB（1,048,576）位于本页面会打开的两类文件之间：手工编辑的文本（`conf`、
  /// `sh`、`json`、`md`、`env`）几乎都远小于 100 KiB，而值得打开的日志则远超
  /// 10 MiB。256 KiB–2 MiB 之间的任何阈值都能区分二者；取 1 MiB 是为出错代价更大
  /// 的一侧留出更大余量。
  ///
  /// The count is in UTF-16 code units, which is what [String.length] reports.
  /// Log and config files are ASCII, where one code unit is one byte on the
  /// wire, so a caller that holds the file's size in bytes — the file manager
  /// gets one from the directory listing — may compare it against this
  /// constant directly and skip reading the file at all.
  /// 计数单位是 [String.length] 所用的 UTF-16 码元。日志与配置文件都是 ASCII，
  /// 一个码元等于线上一个字节，因此持有文件字节大小的调用方（文件管理器可从目录
  /// 列表拿到）可以直接用它与该常量比较，从而根本不去读取文件。
  static const int maxContentLength = 1024 * 1024;

  /// The display name of the file (shown in the app bar).
  /// 文件的显示名称（显示在顶部导航栏）。
  final String filename;

  /// The full text content of the file.
  /// 文件的完整文本内容。
  final String content;

  /// Optional callback invoked when the user saves edits.
  /// 用户保存编辑内容时调用的可选回调。
  final void Function(String newContent)? onSave;

  const FilePreviewPage({
    super.key,
    required this.filename,
    required this.content,
    this.onSave,
  });

  /// Whether [content] is past [maxContentLength] and will not be rendered.
  /// [content] 是否超过 [maxContentLength]、因而不会被渲染。
  static bool isTooLarge(String content) => content.length > maxContentLength;

  @override
  State<FilePreviewPage> createState() => _FilePreviewPageState();
}

class _FilePreviewPageState extends State<FilePreviewPage> {
  /// Whether the page is currently in edit mode.
  /// 页面当前是否处于编辑模式。
  bool _isEditing = false;
  bool _isSaving = false;
  bool _isHandlingBack = false;

  /// Controller for the editable text field.
  /// 可编辑文本框的控制器。
  late TextEditingController _controller;
  late String _savedContent;

  /// Line and character counts of the controller's text, kept in step with
  /// each edit rather than recomputed from the whole file.
  /// 控制器文本的行数与字符数，随每次编辑更新，而不是重算整个文件。
  final _TextMetrics _metrics = _TextMetrics();

  /// Whether the file is too large for this page to render.
  /// 文件是否过大，以致本页面无法渲染。
  bool get _isTooLarge => FilePreviewPage.isTooLarge(widget.content);

  @override
  void initState() {
    super.initState();
    _savedContent = widget.content;
    _controller = TextEditingController(text: widget.content);
    _controller.addListener(_handleTextChanged);

    /// Counting an oversized file would scan the very content this page has
    /// just refused to render, so the counts are simply never taken for it.
    /// 为超大文件计数就等于扫描本页面刚刚拒绝渲染的内容，因此索性不统计。
    if (!_isTooLarge) _metrics.reset(widget.content);
  }

  @override
  void dispose() {
    _controller.removeListener(_handleTextChanged);
    _controller.dispose();
    super.dispose();
  }

  /// Folds the edit that produced the current text into the counts.
  /// 把产生当前文本的那次编辑折算进计数。
  ///
  /// The listener (rather than `TextField.onChanged`) is deliberate: it also
  /// sees the programmatic reset to [_savedContent] when edit mode is left, so
  /// the counts cannot drift from the text being displayed.
  /// 这里用监听器而不是 `TextField.onChanged` 是有意的：离开编辑模式时对
  /// [_savedContent] 的程序化还原它也能看到，计数因此不会与显示的文本脱节。
  void _handleTextChanged() {
    if (_isTooLarge) return;
    if (_metrics.update(_controller.text)) setState(() {});
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
            /// An oversized file has no editor, so it offers no save either.
            /// 超大文件没有编辑器，因此也不提供保存。
            if (!_isTooLarge && _isEditing && widget.onSave != null)
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

            /// Copying an oversized file would put the same multi-hundred-
            /// megabyte string on the clipboard, so the page offers only the
            /// notice in that case.
            /// 复制超大文件会把同样几百 MB 的字符串放进剪贴板，此时页面只给出提示。
            if (!_isTooLarge)
              IconButton(
                icon: Icon(
                  Icons.copy_outlined,
                  color: cs.onSurface.withValues(alpha: 0.64),
                ),
                tooltip: t('copy'),
                onPressed: _copyContent,
              ),
            if (!_isTooLarge && widget.onSave != null)
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
        body: _isTooLarge
            ? _buildTooLargeNotice()
            : Column(
                children: [
                  _buildMetaBar(),
                  Expanded(child: _isEditing ? _buildEditor() : _buildViewer()),
                ],
              ),
      ),
    );
  }

  /// Stands in for the viewer and editor when the file is past the limit.
  /// 文件超过上限时代替查看器与编辑器显示。
  Widget _buildTooLargeNotice() {
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.description_outlined,
              size: 40,
              color: cs.onSurface.withValues(alpha: 0.36),
            ),
            const SizedBox(height: 12),
            Text(
              t('file_too_large'),
              textAlign: TextAlign.center,
              style: TextStyle(color: cs.onSurface.withValues(alpha: 0.6)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMetaBar() {
    final cs = Theme.of(context).colorScheme;
    final lineCount = _metrics.lines;
    final chars = _metrics.chars;
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
                label: t('unsaved_changes'),
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
      ),
    );
  }
}

/// Line and character counts of a text that is being edited, updated from the
/// edit that changed it instead of being recomputed from the whole string.
/// 正在编辑的文本的行数与字符数：由改动它的那次编辑更新，而不是重算整个字符串。
///
/// The metadata bar used to run `'\n'.allMatches(text).length` and
/// `text.characters.length` on every keystroke. Both walk the entire file — the
/// first allocating one `Match` per line, the second one cluster per character
/// — so typing latency grew with the size of the file instead of with the size
/// of the edit. This class derives each edit's delta from the slice that
/// actually changed, which keeps the numbers exactly as they were while making
/// a keystroke cost what the line around it costs, not what the file costs.
/// 元信息栏此前每次按键都要执行 `'\n'.allMatches(text).length` 与
/// `text.characters.length`。两者都会遍历整个文件——前者每行分配一个 `Match`，
/// 后者每字符分配一个簇——于是输入延迟随文件增大而增大，而不是随改动大小变化。
/// 本类只从真正改变的那一段推导增量，数值与原来完全一致，但一次按键的代价只与
/// 它所在的行有关，而与文件大小无关。
class _TextMetrics {
  /// Number of '\n' in [_text]; the visible line count is derived from it.
  /// [_text] 中 '\n' 的个数；可见行数由它推导。
  int _newlines = 0;

  /// Number of grapheme clusters in [_text].
  /// [_text] 中字素簇的个数。
  int _chars = 0;

  /// The text these counts describe; also the diff base for the next edit.
  /// 这些计数所描述的文本；也是下次编辑的差分基准。
  String _text = '';

  /// Line count, matching the previous implementation exactly: an empty text
  /// has no lines, anything else has one more line than it has newlines.
  /// 行数，与原先的实现完全一致：空文本没有行，其余文本的行数比换行数多一。
  int get lines => _text.isEmpty ? 0 : _newlines + 1;

  /// Character count, in grapheme clusters, so an emoji or a CJK ideograph
  /// still counts as one character.
  /// 字符数，按字素簇计，因此一个 emoji 或一个汉字仍算作一个字符。
  int get chars => _chars;

  /// Recounts both values from scratch for [text].
  /// 为 [text] 从头重算两个数值。
  void reset(String text) {
    _text = text;
    _newlines = _countNewlines(text, 0, text.length);
    _chars = text.characters.length;
  }

  /// Folds the edit that turned the previously counted text into [text] into
  /// both counts, and reports whether [text] differed from it at all.
  /// 把「由上次计数的文本变为 [text]」的这次编辑折算进两个计数，并返回
  /// [text] 是否与上次计数的文本不同。
  bool update(String text) {
    if (text == _text) return false;
    final previous = _text;
    final previousLength = previous.length;
    final length = text.length;
    final shared = previousLength < length ? previousLength : length;

    /// Longest run of code units the two texts still share at each end: what
    /// lies between the two runs is the edit.
    /// 两个文本在首尾仍共享的最长码元段：两段之间即为本次编辑。
    var prefix = 0;
    while (prefix < shared &&
        previous.codeUnitAt(prefix) == text.codeUnitAt(prefix)) {
      prefix++;
    }
    var suffix = 0;
    while (suffix < shared - prefix &&
        previous.codeUnitAt(previousLength - 1 - suffix) ==
            text.codeUnitAt(length - 1 - suffix)) {
      suffix++;
    }

    /// Newlines cannot appear or disappear outside the replaced slice, so they
    /// are counted there and nowhere else.
    /// 换行只会在被替换的那一段内增减，因此只统计该段。
    _newlines +=
        _countNewlines(text, prefix, length - suffix) -
        _countNewlines(previous, prefix, previousLength - suffix);

    /// Grapheme clusters do not split at an arbitrary index, so the recount
    /// window is anchored to positions that are boundaries in *both* texts:
    /// a position straight after a '\n' always is one (UAX #29 rule GB4), and
    /// so is either end of the string. [start] falls inside the shared prefix,
    /// [end] is measured back from the shared suffix, so everything outside
    /// the window is identical, and the difference of the two windows is the
    /// difference of the whole texts.
    /// 字素簇不会在任意位置断开，因此重算窗口的两端都锚定在两个文本中都是边界的
    /// 位置：紧跟在 '\n' 之后的位置必然是边界（UAX #29 规则 GB4），字符串两端也是。
    /// [start] 落在共享前缀内，[end] 由共享后缀回推，窗口之外的内容完全相同，于是
    /// 两个窗口之差就是整个文本之差。
    final start = _lineStart(previous, prefix);
    final end = _lineEnd(text, length - suffix);
    final previousEnd = previousLength - (length - end);
    _chars +=
        text.substring(start, end).characters.length -
        previous.substring(start, previousEnd).characters.length;

    _text = text;
    return true;
  }

  /// Number of '\n' in `text[start, end)`.
  /// `text[start, end)` 中 '\n' 的个数。
  static int _countNewlines(String text, int start, int end) {
    var count = 0;
    for (var i = start; i < end; i++) {
      if (text.codeUnitAt(i) == 0x0A) count++;
    }
    return count;
  }

  /// Index just past the last '\n' before [index], or 0 when there is none.
  /// [index] 之前最后一个 '\n' 的后一个下标；没有则为 0。
  static int _lineStart(String text, int index) {
    if (index <= 0) return 0;
    final newline = text.lastIndexOf('\n', index - 1);
    return newline < 0 ? 0 : newline + 1;
  }

  /// Index just past the first '\n' at or after [index], or the end of the text
  /// when there is none.
  /// [index] 及之后第一个 '\n' 的后一个下标；没有则为文本末尾。
  static int _lineEnd(String text, int index) {
    final newline = text.indexOf('\n', index < 0 ? 0 : index);
    return newline < 0 ? text.length : newline + 1;
  }
}
