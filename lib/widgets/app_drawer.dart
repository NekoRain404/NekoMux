import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/app_info.dart';
import '../core/i18n/strings.dart';
import 'brand_mark.dart';
import '../pages/credential_list_page.dart';
import '../pages/snippet_list_page.dart';
import '../pages/settings_page.dart';

// Metrics a section header and the tiles it labels must agree on.
// 分节标题与其下方 tile 必须一致的尺寸。
//
// A tile's title text begins after everything in front of it — its own two
// paddings, the leading icon square and the gap that follows — so the header's
// left inset is that same sum. Sharing the arithmetic is what puts the two on
// one left edge; a header that merely happens to be left-aligned would still
// sit at the wrong x.
// tile 标题文字的起点，等于排在它前面的所有东西之和——自身两层内边距、前置图标方块
// 及其后的间隙；分节标题的左缩进就是这个和值。共享这段算术，两者才落在同一条左边
// 缘上；仅仅「也靠左」的标题仍然会停在错误的横坐标上。
const double _tileOuterInset = 12; // Tile's own outer padding / tile 外层内边距
const double _tileInnerInset = 12; // Padding inside the tap target / 点击区内边距
const double _tileIconBox = 32; // Leading icon square / 前置图标方块
const double _tileIconGap = 12; // Icon-to-text gap / 图标与文字间距
const double _tileTextInset =
    _tileOuterInset + _tileInnerInset + _tileIconBox + _tileIconGap;

class AppDrawer extends ConsumerWidget {
  final String currentModule;
  final bool isTopLevel;

  const AppDrawer({
    super.key,
    this.currentModule = 'hosts',
    this.isTopLevel = false,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    return Drawer(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      child: SafeArea(
        child: Column(
          // Start, not the default centre: `_Section` is a Padding around a
          // short Text, which used to shrink-wrap and centre itself in the
          // drawer while every `_Tile` beside it filled the width.
          // 用 start 而不是默认的 center：`_Section` 是包着短 Text 的 Padding，
          // 原本会收缩并居中，而旁边的 `_Tile` 都是占满宽度的。
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            /// Header
            Container(
              width: double.infinity,
              padding: const EdgeInsets.fromLTRB(20, 28, 20, 20),
              decoration: BoxDecoration(
                color: cs.surface,
                border: Border(
                  bottom: BorderSide(color: Theme.of(context).dividerColor),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: cs.primary.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    // The app's own mark, not a generic terminal glyph: this
                    // header is the first thing the drawer shows and the only
                    // place in the app that stands in for the icon.
                    child: Center(
                      child: BrandMark(
                        size: 30,
                        color: cs.primary,
                        cursorColor: cs.secondary,
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    appName,
                    style: TextStyle(
                      color: cs.onSurface,
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    t('app_desc'),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: cs.onSurface.withValues(alpha: 0.4),
                      fontSize: 10,
                    ),
                  ),
                ],
              ),
            ),
            _Tile(
              icon: Icons.dns_outlined,
              title: t('my_hosts'),
              subtitle: t('hosts_subtitle'),
              selected: currentModule == 'hosts',
              onTap: () => _go(
                context,
                '/',
                selected: currentModule == 'hosts' && isTopLevel,
              ),
            ),
            const Divider(height: 1, indent: 20, endIndent: 20),
            _Section(t('tools')),
            _Tile(
              icon: Icons.vpn_key_outlined,
              title: t('credentials'),
              selected: currentModule == 'credentials',
              onTap: () => _go(
                context,
                const CredentialListPage(),
                selected: currentModule == 'credentials' && isTopLevel,
              ),
            ),
            _Tile(
              icon: Icons.description_outlined,
              title: t('snippets'),
              selected: currentModule == 'snippets',
              onTap: () => _go(
                context,
                const SnippetListPage(),
                selected: currentModule == 'snippets' && isTopLevel,
              ),
            ),
            const Divider(height: 1, indent: 20, endIndent: 20),
            _Section(t('system')),
            _Tile(
              icon: Icons.settings_outlined,
              title: t('settings'),
              selected: currentModule == 'settings',
              onTap: () => _go(
                context,
                const SettingsPage(),
                selected: currentModule == 'settings' && isTopLevel,
              ),
            ),
            _Tile(
              icon: Icons.info_outlined,
              title: t('about'),
              onTap: () {
                Navigator.pop(context);
                showAboutDialog(
                  context: context,
                  applicationName: appName,
                  applicationVersion: appVersion,
                  applicationLegalese: '© 2026 $appName',
                  children: [
                    const SizedBox(height: 8),
                    Text(t('app_desc'), style: const TextStyle(fontSize: 13)),
                  ],
                );
              },
            ),
            const Spacer(),
            Padding(
              padding: const EdgeInsets.all(20),
              // Still centred: the column above is start-aligned so the section
              // headers line up with the tiles, and without this the footer
              // would be dragged left with them. Centred is where it has always
              // been, and the defect fix does not move it.
              // 仍然是居中：上面的 Column 改成 start 对齐是为了让分节标题与 tile 对
              // 齐，若不这样，页脚会被一并拽到左边。居中是它一直以来的位置，本次修复不
              // 移动它。
              child: Center(
                child: Text(
                  'v$appVersion',
                  style: TextStyle(
                    color: cs.onSurface.withValues(alpha: 0.3),
                    fontSize: 10,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _go(BuildContext context, dynamic target, {bool selected = false}) {
    final nav = Navigator.of(context);
    nav.pop();
    if (selected) return;
    nav.popUntil((route) => route.isFirst);
    if (target is String) {
      if (target != '/') {
        nav.pushNamed(target);
      }
    } else if (target is Widget) {
      nav.push(MaterialPageRoute(builder: (_) => target));
    }
  }
}

class _Section extends StatelessWidget {
  final String title;
  const _Section(this.title);
  @override
  Widget build(BuildContext context) => Padding(
    // Left inset is where a tile's title text starts, so the heading sits
    // directly above the labels it groups rather than above their icons.
    // 左缩进取 tile 标题文字的起点，标题便正好压在其所辖标签的正上方，而不是对着图标。
    padding: const EdgeInsets.fromLTRB(_tileTextInset, 16, 20, 4),
    child: Text(
      title,
      style: TextStyle(
        color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.35),
        fontSize: 11,
        fontWeight: FontWeight.w600,
        letterSpacing: 0,
      ),
    ),
  );
}

class _Tile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final VoidCallback? onTap;
  final bool selected;

  const _Tile({
    required this.icon,
    required this.title,
    this.subtitle,
    this.onTap,
    this.selected = false,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final c = cs.primary;
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: _tileOuterInset,
        vertical: 3,
      ),
      child: Material(
        color: selected ? c.withValues(alpha: 0.10) : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: _tileInnerInset,
              vertical: 10,
            ),
            child: Row(
              children: [
                Container(
                  width: _tileIconBox,
                  height: _tileIconBox,
                  decoration: BoxDecoration(
                    color: selected
                        ? c.withValues(alpha: 0.12)
                        : cs.onSurface.withValues(alpha: 0.04),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(
                    icon,
                    color: selected ? c : cs.onSurface.withValues(alpha: 0.6),
                    size: 18,
                  ),
                ),
                const SizedBox(width: _tileIconGap),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: selected ? c : cs.onSurface,
                          fontSize: 13,
                          fontWeight: selected
                              ? FontWeight.w600
                              : FontWeight.normal,
                        ),
                      ),
                      if (subtitle != null)
                        Text(
                          subtitle!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: cs.onSurface.withValues(alpha: 0.35),
                            fontSize: 10,
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
