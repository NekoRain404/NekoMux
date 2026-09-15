import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import '../core/i18n/strings.dart';
import '../widgets/app_drawer.dart';
import '../widgets/quick_key_bar.dart';

/// Local shell (terminal emulator) page providing a simulated Termux-style CLI.
/// 本地终端模拟器页面，提供模拟 Termux 风格的命令行界面。
class LocalShellPage extends ConsumerStatefulWidget {
  const LocalShellPage({super.key});

  @override
  ConsumerState<LocalShellPage> createState() => _LocalShellPageState();
}

/// Private state managing the terminal output buffer, command parsing, and UI.
/// 私有状态，管理终端输出缓冲区、命令解析和界面。
class _LocalShellPageState extends ConsumerState<LocalShellPage> {
  /// Scroll controller for auto-scrolling terminal output to the bottom.
  /// 滚动控制器，用于自动将终端输出滚动到底部。
  final _scrollController = ScrollController();

  /// Text editing controller for the command input field.
  /// 命令输入框的文本编辑控制器。
  final _inputController = TextEditingController();

  /// Focus node for the command input field.
  /// 命令输入框的焦点节点。
  final _focusNode = FocusNode();

  /// Accumulated terminal output lines.
  /// 累积的终端输出行。
  final List<_TerminalLine> _lines = [];
  final List<String> _history = [];
  int _historyIndex = -1;

  /// Current working directory for the simulated shell.
  /// 模拟 Shell 的当前工作目录。
  final String _cwd = '/data/data/com.nekomux/files';

  /// Simulated filesystem entries for the `ls` command.
  /// 模拟的文件系统条目，用于 `ls` 命令。
  static const List<_FileEntry> _mockFiles = [
    _FileEntry('home', true),
    _FileEntry('config.json', false),
    _FileEntry('hosts.db', false),
    _FileEntry('keys', true),
    _FileEntry('logs', true),
    _FileEntry('credentials.dat', false),
  ];

  @override
  void initState() {
    super.initState();

    /// Populate the terminal with the initial banner and mock device info.
    /// 用初始横幅和模拟设备信息填充终端。
    _lines.addAll([
      const _TerminalLine('[NekoMux Local Shell]', isHeader: true),
      const _TerminalLine('Device: Android'),
      const _TerminalLine('Architecture: aarch64'),
      const _TerminalLine('User: termux'),
      const _TerminalLine('Working Directory: /data/data/com.nekomux/files'),
      const _TerminalLine('', isEmpty: true),
      _TerminalLine('$_cwd \$ ', isPrompt: true),
    ]);
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _inputController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  /// Scrolls the terminal output to the bottom after a short delay
  /// to allow the layout to settle.
  /// 短暂延迟后将终端输出滚动到底部，以便布局稳定。
  void _scrollToBottom() {
    Timer(const Duration(milliseconds: 50), () {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 100),
          curve: Curves.easeOut,
        );
      }
    });
  }

  /// Submits the current input text as a command, processes it, and outputs the result.
  /// 提交当前输入文本作为命令，处理后输出结果。
  void _submitCommand(String text) {
    if (text.trim().isEmpty) {
      /// Empty input: just print a new prompt.
      /// 空输入：仅打印新提示符。
      _lines.add(_TerminalLine('$_cwd \$ ', isPrompt: true));
      setState(() {});
      _scrollToBottom();
      return;
    }

    final command = text.trim();
    _history.add(command);
    _historyIndex = _history.length;

    /// Echo the user's typed command in the terminal.
    /// 在终端中回显用户输入的命令。
    _lines.add(_TerminalLine('$_cwd \$ $command', isUserInput: true));

    /// Parse and execute the command.
    /// 解析并执行命令。
    _executeCommand(command.split(' '));

    setState(() {});
    _scrollToBottom();
  }

  /// Simulates command execution by matching the command name and producing mock output.
  /// 通过匹配命令名称并生成模拟输出来模拟命令执行。
  void _executeCommand(List<String> args) {
    if (args.isEmpty) return;
    final cmd = args[0];

    switch (cmd) {
      case 'help':

        /// Display available commands.
        /// 显示可用命令。
        _lines.addAll(const [
          _TerminalLine('Available commands:', isHeader: true),
          _TerminalLine('  ls         - List directory contents'),
          _TerminalLine('  pwd        - Print working directory'),
          _TerminalLine('  whoami     - Show current user'),
          _TerminalLine('  uname -a   - Show system information'),
          _TerminalLine('  echo xxx   - Echo text back'),
          _TerminalLine('  help       - Show this help'),
          _TerminalLine('  clear      - Clear the screen'),
        ]);
        break;

      case 'ls':

        /// List mock directory contents.
        /// 列出模拟目录内容。
        for (final entry in _mockFiles) {
          _lines.add(_TerminalLine(entry.toString()));
        }
        break;

      case 'pwd':

        /// Print working directory.
        /// 打印工作目录。
        _lines.add(_TerminalLine(_cwd));
        break;

      case 'whoami':

        /// Print current user.
        /// 打印当前用户。
        _lines.add(const _TerminalLine('termux'));
        break;

      case 'uname':

        /// Simulate `uname -a` output.
        /// 模拟 `uname -a` 输出。
        if (args.length > 1 && args[1] == '-a') {
          _lines.add(
            const _TerminalLine(
              'Linux localhost 5.10.189-android13+ #1 SMP PREEMPT '
              'Tue Jul 16 19:12:05 CST 2024 aarch64 Android',
            ),
          );
        } else {
          _lines.add(const _TerminalLine('Linux'));
        }
        break;

      case 'echo':

        /// Echo back the remaining arguments.
        /// 回显剩余参数。
        _lines.add(_TerminalLine(args.skip(1).join(' ')));
        break;

      case 'clear':

        /// Clear all terminal output.
        /// 清除所有终端输出。
        _lines.clear();
        break;

      default:

        /// Unknown command feedback.
        /// 未知命令反馈。
        _lines.add(_TerminalLine('$cmd: command not found'));
        break;
    }

    /// Append a new prompt after command output (unless cleared).
    /// 在命令输出后追加新提示符（除非已清屏）。
    if (cmd != 'clear') {
      _lines.add(_TerminalLine(''));
      _lines.add(_TerminalLine('$_cwd \$ ', isPrompt: true));
    } else {
      _lines.add(_TerminalLine('$_cwd \$ ', isPrompt: true));
    }
  }

  /// Handles quick-key bar taps in the local input field.
  /// 处理本地输入框中的快捷按键栏点击。
  void _onQuickKey(String label, String sequence) {
    HapticFeedback.lightImpact();
    switch (label) {
      case '↑':
        _showHistory(delta: -1);
        return;
      case '↓':
        _showHistory(delta: 1);
        return;
      case 'Home':
        _inputController.selection = const TextSelection.collapsed(offset: 0);
        _focusNode.requestFocus();
        return;
      case 'End':
        _inputController.selection = TextSelection.collapsed(
          offset: _inputController.text.length,
        );
        _focusNode.requestFocus();
        return;
      case 'C-c':
        if (_inputController.text.isNotEmpty) {
          _inputController.clear();
          _lines.add(const _TerminalLine('^C', isUserInput: true));
          _lines.add(_TerminalLine('$_cwd \$ ', isPrompt: true));
          setState(() {});
          _scrollToBottom();
        }
        _focusNode.requestFocus();
        return;
      case 'C-d':
      case 'C-z':
      case 'PgUp':
      case 'PgDn':
      case 'Esc':
        _focusNode.requestFocus();
        return;
    }
    _insertInput(sequence);
  }

  void _showHistory({required int delta}) {
    if (_history.isEmpty) {
      _focusNode.requestFocus();
      return;
    }

    _historyIndex = (_historyIndex + delta).clamp(0, _history.length);
    final text = _historyIndex == _history.length
        ? ''
        : _history[_historyIndex];
    _inputController.text = text;
    _inputController.selection = TextSelection.collapsed(offset: text.length);
    _focusNode.requestFocus();
  }

  void _insertInput(String text) {
    final currentText = _inputController.text;
    final selection = _inputController.selection;
    final baseOffset = selection.baseOffset;

    if (baseOffset < 0) {
      /// No selection: append the key at the end.
      /// 无选区：在末尾追加按键文本。
      _inputController.text = currentText + text;
      _inputController.selection = TextSelection.collapsed(
        offset: _inputController.text.length,
      );
    } else {
      /// Insert the key at the cursor position.
      /// 在光标位置插入按键文本。
      final newText =
          currentText.substring(0, baseOffset) +
          text +
          currentText.substring(baseOffset);
      _inputController.text = newText;
      _inputController.selection = TextSelection.collapsed(
        offset: baseOffset + text.length,
      );
    }
    _focusNode.requestFocus();
  }

  Color _terminalBg(ColorScheme cs) => cs.surface;

  Color _terminalPanel(ColorScheme cs) => cs.surfaceContainerHighest;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final terminalBg = _terminalBg(cs);
    final terminalPanel = _terminalPanel(cs);
    return GestureDetector(
      /// Tapping anywhere on the terminal body focuses the input field.
      /// 点击终端区域任意位置，焦点转移到输入框。
      onTap: () => _focusNode.requestFocus(),
      child: Scaffold(
        backgroundColor: terminalBg,
        drawer: const AppDrawer(currentModule: 'shell', isTopLevel: true),
        appBar: AppBar(
          backgroundColor: terminalPanel,
          leading: Builder(
            builder: (ctx) => IconButton(
              icon: Icon(
                Icons.menu,
                color: cs.onSurface.withValues(alpha: 0.6),
              ),
              onPressed: () => Scaffold.of(ctx).openDrawer(),
            ),
          ),
          title: Text(
            t('local_shell'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontFamily: 'monospace',
              color: cs.onSurface,
              fontSize: 15,
            ),
          ),
        ),
        body: Column(
          children: [
            /// Terminal output area — scrollable, full-black background.
            /// 终端输出区域 — 可滚动，纯黑背景。
            Expanded(
              child: Container(
                color: terminalBg,
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                child: ListView.builder(
                  controller: _scrollController,
                  itemCount: _lines.length,
                  itemBuilder: (context, index) {
                    final line = _lines[index];
                    return _buildLine(line);
                  },
                ),
              ),
            ),

            /// Command input bar — minimal styling, green cursor.
            /// 命令输入栏 — 极简风格，绿色光标。
            Container(
              decoration: BoxDecoration(
                color: terminalPanel,
                border: Border(
                  top: BorderSide(
                    color: Theme.of(
                      context,
                    ).dividerColor.withValues(alpha: 0.8),
                  ),
                ),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              child: TextField(
                controller: _inputController,
                focusNode: _focusNode,
                cursorColor: cs.primary,
                style: GoogleFonts.jetBrainsMono(
                  color: cs.primary,
                  fontSize: 14,
                ),
                decoration: InputDecoration(
                  border: InputBorder.none,
                  isDense: true,
                  contentPadding: EdgeInsets.zero,
                  hintText: t('input_command_hint'),
                  hintStyle: TextStyle(
                    color: cs.onSurface.withValues(alpha: 0.6),
                    fontSize: 13,
                  ),
                ),
                onSubmitted: (text) {
                  _submitCommand(text);
                  _inputController.clear();
                },
              ),
            ),

            /// Quick-key bar for terminal shortcuts.
            /// 终端快捷按键栏。
            QuickKeyBar(onKeyTap: _onQuickKey),
          ],
        ),
      ),
    );
  }

  /// Builds a single terminal output line with appropriate styling.
  /// 构建单行终端输出，使用适当的样式。
  Widget _buildLine(_TerminalLine line) {
    final cs = Theme.of(context).colorScheme;
    if (line.isEmpty) {
      return const SizedBox(height: 2);
    }

    Color textColor;
    FontWeight? weight;

    if (line.isHeader) {
      /// Header text in accent blue.
      /// 标题文本使用蓝色强调。
      textColor = cs.secondary;
      weight = FontWeight.w700;
    } else if (line.isUserInput) {
      /// User input in light green.
      /// 用户输入使用浅绿色。
      textColor = cs.primary;
      weight = FontWeight.w500;
    } else if (line.isPrompt) {
      /// Shell prompt in cyan-green.
      /// Shell 提示符使用青绿色。
      textColor = cs.secondary;
      weight = null;
    } else {
      /// Normal output in white.
      /// 普通输出使用白色。
      textColor = cs.onSurface;
      weight = null;
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 1),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Text(
          line.text,
          softWrap: false,
          style: GoogleFonts.jetBrainsMono(
            color: textColor,
            fontSize: 13,
            fontWeight: weight,
            height: 1.5,
          ),
        ),
      ),
    );
  }
}

// ---- Helper data classes / 辅助数据类 ----

/// Represents a single line in the terminal output buffer with rendering hints.
/// 表示终端输出缓冲区中的一行，并带有渲染提示。
class _TerminalLine {
  final String text;
  final bool isHeader;
  final bool isUserInput;
  final bool isPrompt;
  final bool isEmpty;

  const _TerminalLine(
    this.text, {
    this.isHeader = false,
    this.isUserInput = false,
    this.isPrompt = false,
    this.isEmpty = false,
  });
}

/// A simulated filesystem entry for the `ls` command output.
/// 用于 `ls` 命令输出的模拟文件系统条目。
class _FileEntry {
  final String name;
  final bool isDirectory;

  const _FileEntry(this.name, this.isDirectory);

  @override
  String toString() => isDirectory ? '$name/' : name;
}
