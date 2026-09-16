import 'package:flutter/material.dart';

import '../../core/i18n/strings.dart';
import '../../core/theme/app_fonts.dart';
import '../../models/host.dart';
import '../../widgets/app_ui.dart';
import '../../widgets/host_card.dart';

/// Pinned bar of the host console: title, live/connecting indicator, refresh.
/// 主机控制台的固定顶栏：标题、实时/连接中指示、刷新。
///
/// Presentation only — it reports taps and renders state it is handed, and
/// knows nothing about SSH or polling.
/// 只负责展示：上报点击并渲染传入的状态，对 SSH 与轮询一无所知。
class HostConsoleAppBar extends StatelessWidget {
  /// Whether a monitoring connection is being established.
  /// 是否正在建立监控连接。
  final bool connecting;

  /// Whether the monitor is currently receiving samples.
  /// 监控当前是否在接收样本。
  final bool live;

  /// Leaves the page.
  /// 离开本页。
  final VoidCallback onBack;

  /// Re-polls, or retries the connection when there is none. Null while a poll
  /// is already running, which also disables the button.
  final VoidCallback? onRefresh;

  const HostConsoleAppBar({
    super.key,
    required this.connecting,
    required this.live,
    required this.onBack,
    required this.onRefresh,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return SliverAppBar(
      pinned: true,
      backgroundColor: cs.surface,
      leading: IconButton(
        icon: Icon(
          Icons.arrow_back,
          color: cs.onSurface.withValues(alpha: 0.7),
        ),
        onPressed: onBack,
      ),
      title: Row(
        children: [
          Flexible(
            child: Text(
              t('host_detail'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 10),
          if (connecting)
            SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: cs.secondary,
              ),
            )
          else if (live)
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 118),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: cs.primary.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: cs.primary.withValues(alpha: 0.3)),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.circle, size: 6, color: cs.primary),
                    const SizedBox(width: 4),
                    Flexible(
                      child: Text(
                        t('real_time_interval'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: cs.primary,
                          fontSize: 10,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            )
          else
            const _MonitorUnavailableBadge(),
        ],
      ),
      actions: [
        // The button becomes the progress it starts. It used to stay a refresh
        // icon with no disabled state, so during the two sequential commands a
        // refresh runs — up to ten seconds each — a second tap queued another
        // pair against the same connection, and nothing on screen said the
        // first pair was still going.
        if (onRefresh == null)
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 14),
            child: Center(
              child: SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          )
        else
          IconButton(
            tooltip: t('refresh'),
            icon: Icon(
              Icons.refresh,
              color: cs.onSurface.withValues(alpha: 0.62),
            ),
            onPressed: onRefresh,
          ),
      ],
    );
  }
}

/// The grey badge shown when the monitor is not live and not connecting.
/// 监控既非实时、也不在连接中时显示的灰色徽标。
///
/// It reads "monitor unavailable" in every language the app ships (the key is
/// named `simulated_data`, a leftover from a time this page drew invented
/// numbers — the app never fabricates a reading any more, and the text said so
/// even before this badge was extracted).
/// 在应用发布的每种语言里它都读作「监控不可用」（该键名为 `simulated_data`，
/// 是本页曾经绘制虚构数值的时代遗留——如今应用不再编造任何读数，而文案在本次拆分
/// 之前就已经是实话）。
class _MonitorUnavailableBadge extends StatelessWidget {
  const _MonitorUnavailableBadge();

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 118),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: cs.onSurface.withValues(alpha: 0.07),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
          t('simulated_data'),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: cs.onSurface.withValues(alpha: 0.6),
            fontSize: 10,
            fontWeight: FontWeight.w500,
          ),
        ),
      ),
    );
  }
}

/// Header card: host alias, resolved host name, OS banner and status chips.
/// 页头卡片：主机别名、解析出的主机名、系统信息与状态标签。
class HostConsoleIdentityCard extends StatelessWidget {
  /// The host this console belongs to.
  /// 本控制台所属的主机。
  final Host host;

  /// Host name read from the machine, or `''` when it could not be read — in
  /// which case the address is shown instead.
  /// 从机器上读到的主机名；读不到时为 `''`，此时改显示地址。
  final String hostname;

  /// Distro / kernel banner, or `''`.
  /// 发行版／内核信息；读不到时为 `''`。
  final String osInfo;

  /// What the console can honestly say about the host right now.
  /// 控制台目前能如实说明的主机状态。
  ///
  /// Three states, not two, and for the same reason the home page has three:
  /// when the host key is not trusted the handshake never completes, so
  /// **nothing about the machine's availability was measured**. Rendering that
  /// as the red "offline" badge asserts an outage nobody observed — and the two
  /// screens then contradict each other, the home list reading "unverified"
  /// while this card reads "offline" for the same host at the same moment.
  /// 三态而非两态，理由与首页相同：主机密钥不受信时握手根本不会完成，因此**关于这台
  /// 机器可用性的一切都没有被测量过**。把它渲染成红色的「离线」徽章等于断言一次没人
  /// 观察到的宕机——而且两个界面会互相矛盾：同一时刻首页读作「待验证」，这张卡片读作
  /// 「离线」。
  final HostStatus status;

  /// The stored host key this device trusts for this host, or null when there
  /// is none.
  ///
  /// The key is what makes this card an answer to "is someone intercepting
  /// me": the fingerprint can be compared against the one the server prints
  /// (`ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub`) without opening a
  /// second connection or leaving the screen.
  final Map<String, Object?>? trustedKey;

  /// Copies [value] and says so. Owned by the page, which holds the messenger.
  final void Function(String value)? onCopy;

  const HostConsoleIdentityCard({
    super.key,
    required this.host,
    required this.hostname,
    required this.osInfo,
    required this.status,
    this.trustedKey,
    this.onCopy,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return AppCard(
      margin: const EdgeInsets.all(16),
      padding: const EdgeInsets.all(16),
      child: Row(
        children: [
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              color: cs.primary.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Center(
              child: Text(
                Host.getOsLogoChar(host.osType),
                style: const TextStyle(fontSize: 28),
              ),
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  host.alias,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: cs.onSurface,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  hostname.isNotEmpty ? hostname : host.displayAddress,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: cs.onSurface.withValues(alpha: 0.48),
                    fontSize: 12,
                  ),
                ),
                if (osInfo.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    osInfo,
                    style: TextStyle(
                      color: cs.onSurface.withValues(alpha: 0.36),
                      fontSize: 10,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
                const SizedBox(height: 4),
                Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  children: [
                    // The same label and colour the home list uses, so the two
                    // screens cannot describe one host differently.
                    // 与首页列表同一套文案与配色，两个界面因此不可能对同一台主机给出
                    // 不同说法。
                    AppBadge(
                      label: hostStatusLabel(status),
                      color: hostStatusColor(cs, status),
                    ),
                    AppBadge(label: 'SSH :${host.port}', color: cs.secondary),
                    if ((host.credentialUsername ?? '').isNotEmpty)
                      AppBadge(
                        label:
                            '${t('username')}: ${host.credentialUsername}',
                        color: cs.primary,
                      ),
                  ],
                ),
                if (fingerprint case final key?) ...[
                  const SizedBox(height: 6),
                  // The key this device decided to trust for this host, shown
                  // where the user is already looking when they suspect the
                  // connection. Tapping copies it: comparing fingerprints is
                  // done by eye against a value printed elsewhere, and typing a
                  // 47-character MD5 from a phone screen is not.
                  InkWell(
                    onTap: onCopy == null ? null : () => onCopy!(key),
                    borderRadius: BorderRadius.circular(4),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: Row(
                        children: [
                          Icon(
                            Icons.key_outlined,
                            size: 12,
                            color: cs.onSurface.withValues(alpha: 0.36),
                          ),
                          const SizedBox(width: 4),
                          Expanded(
                            child: Text(
                              key,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: cs.onSurface.withValues(alpha: 0.4),
                                fontSize: 10,
                                fontFamily: AppFonts.mono,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// The stored fingerprint, or null when this host has no recorded key yet.
  String? get fingerprint {
    final value = trustedKey?['fingerprint'];
    return value is String && value.isNotEmpty ? value : null;
  }
}
