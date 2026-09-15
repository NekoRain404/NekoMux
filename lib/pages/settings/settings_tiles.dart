// The row widgets every section of the Settings page is built from.
// 设置页各个分节所用的行控件。
//
// Presentation only: each tile renders the labels, values and icons it is given
// and reports the change back through a callback. None of them reads a provider
// or touches the database, so a section can be reordered — or a setting wired to
// its real consumer — without any of this changing.
// 纯展示层：每个 tile 只渲染传入的标签、数值与图标，并通过回调上报变化。它们都不读
// provider、不接触数据库，因此调整分节顺序、或把某个设置接到真正的使用点上，都无需
// 改动本文件。
import 'package:flutter/material.dart';

import '../../widgets/app_ui.dart';

/// Whether a subtitle still says something its title does not.
/// 副标题是否还说了标题没说的事。
///
/// The translations are deliberately bilingual — a "中文标题" with an "English
/// subtitle" underneath — which reads well in an interface that is not English,
/// but makes every row say the same thing twice once the app is switched to
/// English (`Terminal Font Size` over `Terminal Font Size`, and the same for
/// Connection Timeout, Haptic Feedback and others). A subtitle equal to its
/// title carries no information in any language, so it is dropped here rather
/// than rendered twice. Fixing it in the widget rather than in the translation
/// data keeps the bilingual look everywhere it is still doing something, and
/// covers every language at once.
/// 译文有意做成中英对照——「中文标题」下面配一行英文副标题——在非英文界面下观感很
/// 好，但界面切到英文后每一行都会把同一句话显示两遍（`Terminal Font Size` 上方又是
/// `Terminal Font Size`，Connection Timeout、Haptic Feedback 等也是如此）。与标题
/// 相同的副标题在任何语言下都不携带信息，因此这里直接不渲染，而不是显示两遍。在控件
/// 里修而不是改译文，既保住了其它地方仍然有效的中英对照观感，也一次覆盖所有语言。
bool _hasDistinctSub(String title, String sub) => sub.trim() != title.trim();

/// Section heading, e.g. "Appearance" or "Data".
/// 分节标题，例如「外观」或「数据」。
class SettingsSectionHeader extends StatelessWidget {
  final String title;

  const SettingsSectionHeader({super.key, required this.title});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 12),
      child: Text(
        title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: cs.onSurface.withValues(alpha: 0.48),
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// Common card shell: the margins and padding every settings row shares.
/// 通用卡片外壳：所有设置行共用的外边距与内边距。
class SettingsTileShell extends StatelessWidget {
  final Widget child;
  final VoidCallback? onTap;

  const SettingsTileShell({super.key, required this.child, this.onTap});

  @override
  Widget build(BuildContext context) {
    return AppCard(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      onTap: onTap,
      child: child,
    );
  }
}

/// A setting whose value is a number on a slider, with the value shown.
/// 数值由滑块调节、并把当前值显示出来的设置项。
class SettingsSliderTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String sub;
  final String display;
  final double value;
  final double min;
  final double max;
  final int div;
  final ValueChanged<double> onChanged;

  const SettingsSliderTile({
    super.key,
    required this.icon,
    required this.title,
    required this.sub,
    required this.display,
    required this.value,
    required this.min,
    required this.max,
    required this.div,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return SettingsTileShell(
      child: Row(
        children: [
          Icon(icon, color: cs.primary, size: 20),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: cs.onSurface, fontSize: 14),
                ),
                if (_hasDistinctSub(title, sub))
                  Text(
                    sub,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: cs.onSurface.withValues(alpha: 0.48),
                      fontSize: 10,
                    ),
                  ),
              ],
            ),
          ),
          Text(
            display,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: cs.primary,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: MediaQuery.sizeOf(context).width < 380 ? 92 : 120,
            child: SliderTheme(
              data: SliderThemeData(
                trackHeight: 3,
                thumbShape: RoundSliderThumbShape(enabledThumbRadius: 6),
                activeTrackColor: cs.secondary,
                inactiveTrackColor: cs.onSurface.withValues(alpha: 0.1),
                thumbColor: cs.secondary,
              ),
              child: Slider(
                value: value,
                min: min,
                max: max,
                divisions: div,
                onChanged: onChanged,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A setting that is on or off; the whole row toggles it.
/// 开关型设置项；点击整行即可切换。
class SettingsSwitchTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String sub;
  final bool value;
  final ValueChanged<bool> onChanged;

  const SettingsSwitchTile({
    super.key,
    required this.icon,
    required this.title,
    required this.sub,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return SettingsTileShell(
      onTap: () => onChanged(!value),
      child: Row(
        children: [
          Icon(icon, color: cs.primary, size: 20),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: cs.onSurface, fontSize: 14),
                ),
                if (_hasDistinctSub(title, sub))
                  Text(
                    sub,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: cs.onSurface.withValues(alpha: 0.48),
                      fontSize: 10,
                    ),
                  ),
              ],
            ),
          ),
          Switch(
            value: value,
            onChanged: onChanged,
            activeThumbColor: cs.secondary,
          ),
        ],
      ),
    );
  }
}

/// A setting entered as text, committed on submit and rejected in place.
/// 以文本输入的设置项：提交时生效，非法输入就地标红。
///
/// The subtitle doubles as the error line: [onSubmit] returning false swaps the
/// hint for [errorText] and paints the field, so the user sees why the edit did
/// not stick instead of watching the old value silently return.
/// 副标题兼作错误行：[onSubmit] 返回 false 时提示文字换成 [errorText] 并把输入框
/// 标红，用户能看出这次修改为何没有生效，而不是眼看旧值悄悄回来。
class SettingsInputTile extends StatefulWidget {
  final IconData icon;
  final String title;
  final String sub;

  /// Value shown when the field is not being edited.
  /// 未处于编辑状态时显示的数值。
  final String init;
  final TextInputType type;
  final String errorText;
  final bool Function(String) onSubmit;

  const SettingsInputTile({
    super.key,
    required this.icon,
    required this.title,
    required this.sub,
    required this.init,
    required this.type,
    required this.errorText,
    required this.onSubmit,
  });

  @override
  State<SettingsInputTile> createState() => _SettingsInputTileState();
}

class _SettingsInputTileState extends State<SettingsInputTile> {
  late final TextEditingController _controller;
  late final FocusNode _focusNode;
  bool _hasError = false;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.init);
    _focusNode = FocusNode();
  }

  @override
  void didUpdateWidget(SettingsInputTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Only follow a value that changed elsewhere while this field was idle:
    // overwriting what the user is typing would eat the edit mid-keystroke.
    // 只跟随输入框空闲时在别处发生的数值变化：覆盖用户正在输入的内容会打断编辑。
    if (!_focusNode.hasFocus &&
        oldWidget.init != widget.init &&
        _controller.text != widget.init) {
      _controller.text = widget.init;
      _hasError = false;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _submit() {
    final ok = widget.onSubmit(_controller.text.trim());
    setState(() => _hasError = !ok);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final dividerColor = Theme.of(context).dividerColor;
    return SettingsTileShell(
      child: Row(
        children: [
          Icon(widget.icon, color: _hasError ? cs.error : cs.primary, size: 20),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: cs.onSurface, fontSize: 14),
                ),
                // An error is never suppressed, even in the impossible case of
                // it matching the title: it is the reason the edit was refused,
                // not a restatement of the label. Only the idle subtitle obeys
                // the rule.
                // 出错时一律显示，即使出现「错误文字恰好等于标题」这种不可能的情
                // 况：它是这次修改被拒的原因，而不是标题的复述。只有空闲时的副标题
                // 才受该规则约束。
                if (_hasError || _hasDistinctSub(widget.title, widget.sub))
                  Text(
                    _hasError ? widget.errorText : widget.sub,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: _hasError
                          ? cs.error
                          : cs.onSurface.withValues(alpha: 0.48),
                      fontSize: 10,
                    ),
                  ),
              ],
            ),
          ),
          SizedBox(
            width: 80,
            child: TextField(
              controller: _controller,
              focusNode: _focusNode,
              keyboardType: widget.type,
              style: TextStyle(color: cs.onSurface, fontSize: 12),
              textAlign: TextAlign.center,
              decoration: InputDecoration(
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 6,
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide(color: dividerColor),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide(
                    color: _hasError ? cs.error : dividerColor,
                  ),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide(
                    color: _hasError ? cs.error : cs.secondary,
                  ),
                ),
              ),
              onSubmitted: (_) => _submit(),
              onEditingComplete: _submit,
            ),
          ),
        ],
      ),
    );
  }
}

/// A setting that opens something else; the current value sits on the right.
/// 点击后打开别处的设置项；当前值显示在右侧。
class SettingsListTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String sub;
  final VoidCallback onTap;

  const SettingsListTile({
    super.key,
    required this.icon,
    required this.title,
    required this.sub,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return SettingsTileShell(
      onTap: onTap,
      child: Row(
        children: [
          Icon(icon, color: cs.primary, size: 20),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: cs.onSurface, fontSize: 14),
            ),
          ),
          // The gap travels with the text: a dropped subtitle must not leave its
          // spacing behind as a mystery indent before the chevron.
          // 间距跟着文字一起走：副标题不显示时，不能在箭头前留下一段莫名的空白。
          if (_hasDistinctSub(title, sub)) ...[
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                sub,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.right,
                style: TextStyle(
                  color: cs.onSurface.withValues(alpha: 0.48),
                  fontSize: 12,
                ),
              ),
            ),
          ],
          const SizedBox(width: 4),
          Icon(
            Icons.chevron_right,
            color: cs.onSurface.withValues(alpha: 0.3),
            size: 20,
          ),
        ],
      ),
    );
  }
}

/// A setting that performs an action, with the consequence spelled out below.
/// 执行动作的设置项，其后果写在下方说明中。
class SettingsActionTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String sub;
  final Color color;
  final VoidCallback onTap;

  const SettingsActionTile({
    super.key,
    required this.icon,
    required this.title,
    required this.sub,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return SettingsTileShell(
      onTap: onTap,
      child: Row(
        children: [
          Icon(icon, color: color, size: 20),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: cs.onSurface,
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                if (_hasDistinctSub(title, sub))
                  Text(
                    sub,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: cs.onSurface.withValues(alpha: 0.48),
                      fontSize: 10,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// A read-only row, e.g. the app name and version under "About".
/// 只读行，例如「关于」下的应用名与版本号。
class SettingsInfoTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String sub;

  const SettingsInfoTile({
    super.key,
    required this.icon,
    required this.title,
    required this.sub,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return SettingsTileShell(
      child: Row(
        children: [
          Icon(icon, color: cs.primary.withValues(alpha: 0.6), size: 18),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: cs.onSurface,
                fontSize: 14,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          // Same rule as the list tile: the gap goes with the text it separated.
          // 与列表行同一条规则：间距跟着它所分隔的文字一起消失。
          if (_hasDistinctSub(title, sub)) ...[
            const SizedBox(width: 12),
            Flexible(
              child: Text(
                sub,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.right,
                style: TextStyle(
                  color: cs.onSurface.withValues(alpha: 0.48),
                  fontSize: 12,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
