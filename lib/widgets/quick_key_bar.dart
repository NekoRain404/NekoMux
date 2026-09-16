import 'package:flutter/material.dart';
import '../core/i18n/strings.dart';

/// Visual weight of a key, resolved against the current `ColorScheme` by
/// [QuickKeyBar].
/// 按键的视觉权重，由 [QuickKeyBar] 依据当前 `ColorScheme` 解析。
enum QuickKeyTone {
  /// Ordinary key — drawn in the neutral outline color.
  /// 普通按键，使用中性描边色。
  normal,

  /// Ends the foreground process (C-c, C-d).
  /// 结束前台进程的按键（C-c、C-d）。
  danger,

  /// Suspends the foreground process (C-z).
  /// 挂起前台进程的按键（C-z）。
  suspend,
}

/// One key of the [QuickKeyBar]: the label it draws and the exact bytes it
/// sends to the remote shell.
/// [QuickKeyBar] 上的单个按键：绘制的标签，以及发送给远端 shell 的确切字节。
class QuickKeyDef {
  /// Text drawn on the pill. Terminal control keys stay in their literal `C-x`
  /// form in every language, so these labels are never translated.
  /// 按钮上绘制的文本。终端控制键在任何语言下都保持 `C-x` 字面形式，
  /// 因此这些标签永不翻译。
  final String label;

  /// Bytes written to the PTY when the key is tapped. Must never be empty.
  /// 点击后写入 PTY 的字节，绝不能为空。
  final String sequence;

  /// Visual weight of the key.
  /// 按键的视觉权重。
  final QuickKeyTone tone;

  const QuickKeyDef(
    this.label,
    this.sequence, {
    this.tone = QuickKeyTone.normal,
  });
}

/// Horizontal scrollable quick-access key bar for terminal. Each key triggers a
/// callback when tapped.
/// 横向可滚动的终端快捷按键栏，每个按键可触发回调。
class QuickKeyBar extends StatelessWidget {
  final void Function(String label, String sequence)? onKeyTap;
  final VoidCallback? onSnippetsTap;

  /// Invoked by the clipboard pill. Null hides it — pasting into a shell that
  /// is not connected would silently go nowhere.
  final VoidCallback? onPasteTap;

  const QuickKeyBar({
    super.key,
    this.onKeyTap,
    this.onSnippetsTap,
    this.onPasteTap,
  });

  /// The keys, in bar order, split into groups that [_GroupDivider] separates.
  /// 按键按栏内顺序排列，分组之间由 [_GroupDivider] 分隔。
  ///
  /// Two rules shape the order. First, by what a key saves on a phone rather
  /// than by ANSI order: the group a line of shell work touches every time
  /// comes first, and a key appended to the tail costs the keys before it
  /// nothing. Second, the existing groups keep their internal order and their
  /// colors, so a swipe that used to land on C-c still lands on C-c.
  /// 排序遵循两条规则。其一，依据「在手机上能省多少事」而非 ANSI 顺序：每一行
  /// shell 操作都会用到的分组排在前面，而追加到末尾的键不会把前面的键挤远。
  /// 其二，既有分组保持内部顺序与配色，过去一次滑动能摸到 C-c 的人，现在依然
  /// 一次滑动就能摸到。
  static const List<List<QuickKeyDef>> keyGroups = [
    // 1. Completion and cursor movement — reached for on every line. Tab is the
    //    single most used terminal key, and the arrows are how history is
    //    walked, which matters more on a phone than anywhere else.
    // 1. 补全与光标移动——每一行命令都会用到。Tab 是终端里用得最多的单键，
    //    方向键则是翻阅历史的方式，这在手机上比在其他地方都更重要。
    [
      QuickKeyDef('Tab', '\t'),
      QuickKeyDef('↑', '\x1B[A'),
      QuickKeyDef('↓', '\x1B[B'),
      QuickKeyDef('←', '\x1B[D'),
      QuickKeyDef('→', '\x1B[C'),
      QuickKeyDef('Home', '\x1B[H'),
      QuickKeyDef('End', '\x1B[F'),
      QuickKeyDef('PgUp', '\x1B[5~'),
      QuickKeyDef('PgDn', '\x1B[6~'),
      QuickKeyDef('Esc', '\x1B'),
    ],

    // 2. Signals — they act on what is running right now, so they sit next to
    //    the navigation keys: interrupting a runaway command must not be a
    //    swipe away. C-c/C-d are red because they end the process, C-z is
    //    secondary because it only suspends it — colors unchanged.
    // 2. 信号键——作用于当前正在运行的东西，因此紧挨导航键：中断失控命令不该
    //    需要滑动。C-c/C-d 为红色（结束进程），C-z 为次要色（仅挂起）——配色
    //    保持不变。
    [
      QuickKeyDef('C-c', '\x03', tone: QuickKeyTone.danger),
      QuickKeyDef('C-d', '\x04', tone: QuickKeyTone.danger),
      QuickKeyDef('C-z', '\x1A', tone: QuickKeyTone.suspend),
    ],

    // 3. Readline line editing — the real gap on a soft keyboard. Android
    //    keyboards have no Home/End that a shell binds to Ctrl+A/Ctrl+E, no
    //    kill-line, and no way to search history, so retyping a long command
    //    is otherwise the only option. Ordered by what each one saves: history
    //    search (nothing else can do it, and ↑ only walks one entry at a
    //    time), then cursor movement, then deletion backwards (C-u whole line,
    //    C-w one word) and forwards (C-k), then clearing the screen last
    //    because `clear` at least remains typeable.
    // 3. Readline 行编辑——软键盘真正的缺口。Android 键盘没有 shell 会绑定到
    //    Ctrl+A/Ctrl+E 的 Home/End，没有删除整行，也无法搜索历史，否则只能
    //    重新敲一遍长命令。组内按「省事程度」排序：历史搜索（没有替代手段，
    //    而 ↑ 只能逐条翻），接着是光标移动，然后是向后删除（C-u 整行、C-w 一个
    //    词）与向前删除（C-k），最后才是清屏——`clear` 至少还能敲出来。
    [
      QuickKeyDef('C-r', '\x12'),
      QuickKeyDef('C-a', '\x01'),
      QuickKeyDef('C-e', '\x05'),
      QuickKeyDef('C-u', '\x15'),
      QuickKeyDef('C-w', '\x17'),
      QuickKeyDef('C-k', '\x0B'),
      QuickKeyDef('C-l', '\x0C'),
    ],

    // 4. Characters a phone keyboard buries. `/` and `|` are the ones this bar
    //    already carried and keep their places; `-`, `~` and `>` join them
    //    because every real command line contains a flag, a home-directory
    //    path or a redirection, and all three need the symbols layer (on many
    //    layouts `~` also needs a long press). The rest of the symbols layer
    //    (`$`, `&`, `;`, `*`, `<`, quotes) is deliberately left out: one tap
    //    away, used less often than the Ctrl keys above, and every extra pill
    //    pushes everything after it further out of reach.
    // 4. 手机键盘藏起来的字符。`/` 与 `|` 是该栏本来就有的，位置不变；`-`、`~`
    //    与 `>` 加入进来，因为真实的命令行里总有选项、家目录路径或重定向，而
    //    这三个都要先切到符号层（在很多布局上 `~` 还得长按）。符号层的其余字符
    //    （`$`、`&`、`;`、`*`、`<`、引号）刻意不加：只多一次点击、用得比上面的
    //    Ctrl 键少，而且每多一个按钮都会把它后面的键推得更远。
    [
      QuickKeyDef('/', '/'),
      QuickKeyDef('|', '|'),
      QuickKeyDef('-', '-'),
      QuickKeyDef('~', '~'),
      QuickKeyDef('>', '>'),
    ],
  ];

  /// Flat view of [keyGroups], in bar order.
  /// [keyGroups] 的扁平视图，顺序与栏内一致。
  static List<QuickKeyDef> get allKeys => [
    for (final group in keyGroups) ...group,
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final dividerColor = theme.dividerColor;

    return Container(
      color: colorScheme.surface,
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            if (onSnippetsTap != null) ...[
              _KeyPill(
                label: '{}',
                tooltip: t('snippets'),
                color: colorScheme.primary,
                onTap: onSnippetsTap,
              ),
              _GroupDivider(color: dividerColor),
            ],
            // Paste leads the bar, before the character keys: it is the one pill
            // that brings in text from outside the app entirely, and the text it
            // brings is usually the command the user actually came to run.
            if (onPasteTap != null) ...[
              _KeyPill(
                label: '📋',
                tooltip: t('paste'),
                color: colorScheme.primary,
                onTap: onPasteTap,
              ),
              _GroupDivider(color: dividerColor),
            ],
            for (var g = 0; g < keyGroups.length; g++) ...[
              if (g > 0) _GroupDivider(color: dividerColor),
              for (final key in keyGroups[g])
                _KeyPill(
                  label: key.label,
                  tooltip: key.label,
                  color: _toneColor(key.tone, colorScheme),
                  onTap: onKeyTap == null
                      ? null
                      : () => onKeyTap!(key.label, key.sequence),
                ),
            ],
          ],
        ),
      ),
    );
  }

  /// Resolves a key's [QuickKeyTone] to the colors this bar used before the
  /// table was grouped; [QuickKeyTone.normal] keys keep the neutral outline.
  /// 将按键的 [QuickKeyTone] 解析为该栏分组之前就在使用的颜色；
  /// [QuickKeyTone.normal] 的按键保持中性描边。
  static Color? _toneColor(QuickKeyTone tone, ColorScheme colorScheme) {
    return switch (tone) {
      QuickKeyTone.danger => colorScheme.error,
      QuickKeyTone.suspend => colorScheme.secondary,
      QuickKeyTone.normal => null,
    };
  }
}

/// Thin vertical rule marking the boundary between two key groups.
/// 标记两个按键分组边界的细竖线。
class _GroupDivider extends StatelessWidget {
  final Color color;
  const _GroupDivider({required this.color});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 5),
      child: Container(
        width: 1,
        height: 20,
        color: color.withValues(alpha: 0.5),
      ),
    );
  }
}

class _KeyPill extends StatelessWidget {
  final String label;
  final String? tooltip;
  final VoidCallback? onTap;
  final Color? color;

  const _KeyPill({required this.label, this.tooltip, this.onTap, this.color});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = color ?? theme.colorScheme.onSurface.withValues(alpha: 0.6);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2.5),
      child: Material(
        color: theme.cardColor,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(8),
          child: Container(
            constraints: const BoxConstraints(minWidth: 42, minHeight: 34),
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 8),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: c.withValues(alpha: 0.4), width: 0.5),
            ),
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: c,
                fontSize: 11,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
