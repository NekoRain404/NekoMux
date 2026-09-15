import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/i18n/strings.dart';
import '../pages/credential_list_page.dart';
import '../pages/snippet_list_page.dart';
import '../pages/settings_page.dart';

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
                    child: Icon(Icons.terminal, color: cs.primary, size: 24),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'NekoMux',
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
                  applicationName: 'NekoMux',
                  applicationVersion: '1.0.0',
                  applicationLegalese: '© 2026 NekoMux',
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
              child: Text(
                'v1.0.0-beta',
                style: TextStyle(
                  color: cs.onSurface.withValues(alpha: 0.3),
                  fontSize: 10,
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
    padding: const EdgeInsets.fromLTRB(24, 16, 20, 4),
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
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
      child: Material(
        color: selected ? c.withValues(alpha: 0.10) : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              children: [
                Container(
                  width: 32,
                  height: 32,
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
