import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../../core/i18n/strings.dart';
import '../../widgets/resource_chart.dart';

/// The resource panel of the host console: chart, legend, live badge and the
/// overlay that replaces it when monitoring cannot deliver samples.
/// 主机控制台的资源面板：图表、图例、实时徽标，以及监控无法提供样本时取代它的
/// 覆盖层。
///
/// Presentation only. Every number it draws was measured by the page's probe;
/// this widget never invents one, and when there are none to draw it says so
/// rather than showing a plausible curve.
/// 只负责展示。它画出的每个数字都由页面的探针测得；本组件从不编造数字，而没有数字
/// 可画时它会如实说明，而不是画出一条看似可信的曲线。
class ResourceMonitorCard extends StatelessWidget {
  /// Drives the high-usage glow; the page owns the controller's lifecycle.
  /// 驱动高负载辉光；控制器生命周期由页面持有。
  final Animation<double> glow;

  /// CPU series, one point per sample.
  /// CPU 序列，每个样本一个点。
  final List<FlSpot> cpuData;

  /// RAM series, one point per sample.
  /// RAM 序列，每个样本一个点。
  final List<FlSpot> ramData;

  /// Latest CPU reading in percent, or `null` while there is none to show.
  /// 最新 CPU 读数（百分比）；尚无读数可显示时为 `null`。
  ///
  /// Null is a state of its own, not a zero: the first sample of a session has
  /// no delta to measure, and a cleared window has nothing behind it at all.
  /// Printing 0.0% for either would describe a machine burning no CPU — the
  /// invented measurement these series exist to avoid.
  /// `null` 是独立的一种状态，而不是零：一次会话的首个样本没有可测的增量，被清空的
  /// 窗口背后则什么都没有。两者若都印成 0.0%，描述的就是一台不烧 CPU 的机器——正是
  /// 这些序列存在的意义所要避免的凭空捏造。
  final double? latestCpu;

  /// Latest RAM reading in percent, or `null` while there is none to show.
  /// 最新 RAM 读数（百分比）；尚无读数可显示时为 `null`。
  final double? latestRam;

  /// Whether samples are arriving.
  /// 样本是否正在到达。
  final bool live;

  /// Whether a connection attempt is in progress.
  /// 是否正在尝试连接。
  final bool connecting;

  /// Why monitoring stopped, when it did.
  /// 监控停止的原因（若已停止）。
  final String? error;

  /// Time between two samples; the chart derives its axis labels from it so the
  /// span the user reads matches the span that was sampled.
  /// 两个样本之间的时间间隔；图表据此推导坐标轴标签，使用户读到的时间跨度与采样
  /// 跨度一致。
  final Duration sampleInterval;

  /// Retries the monitoring connection.
  /// 重试监控连接。
  final Future<void> Function() onRetry;

  const ResourceMonitorCard({
    super.key,
    required this.glow,
    required this.cpuData,
    required this.ramData,
    required this.latestCpu,
    required this.latestRam,
    required this.live,
    required this.connecting,
    required this.error,
    required this.sampleInterval,
    required this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final dividerColor = Theme.of(context).dividerColor;
    final cpuColor = cs.secondary;
    final ramColor = cs.primary;
    final showUnavailable = !live && !connecting && error != null;
    final showGlow =
        !showUnavailable && ((latestCpu ?? 0) >= 85 || (latestRam ?? 0) >= 85);

    /// Everything that does not depend on the glow animation.
    /// 与辉光动画无关的一切。
    ///
    /// Built once per *state* change and handed to [AnimatedBuilder] as its
    /// `child`, so the animation frames cannot reach it. It used to be returned
    /// from the builder, which re-ran this whole subtree — including
    /// [ResourceChart.build], with its `LineChartData`, two `LineChartBarData`,
    /// a `LinearGradient` and a tooltip closure — sixty times a second even
    /// while the glow was off and the opacity was pinned at 0.0, where no pixel
    /// could change.
    /// 每次**状态**变化只构建一次，并作为 `child` 交给 [AnimatedBuilder]，动画帧因此
    /// 到不了这里。过去它由 builder 返回，整棵子树会被重跑——包括
    /// [ResourceChart.build] 及其 `LineChartData`、两个 `LineChartBarData`、一个
    /// `LinearGradient` 与一个提示闭包——每秒六十次，而辉光关闭、透明度恒为 0.0 时
    /// 根本没有像素会变。
    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.show_chart, color: cs.secondary, size: 18),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                t('resource_monitor'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: cs.onSurface,
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(width: 8),
            _headerBadge(cs, showUnavailable: showUnavailable),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            _Legend(label: 'CPU', color: cpuColor),
            const SizedBox(width: 16),
            _Legend(label: 'RAM', color: ramColor),
          ],
        ),
        const SizedBox(height: 8),
        // The overlay takes the chart's place instead of covering it. It used
        // to be a `Positioned.fill` in a `Stack` whose height came from the
        // chart's fixed 180 px, which left its content a 144 px scroll viewport
        // — and its ~200 px of message, hint and retry button were laid out
        // below it, the button outside the panel and outside a hit test. When
        // it is up there is no chart to protect anyway: the samples are cleared
        // before it appears, so a flat zero line is all that would sit
        // underneath.
        // 覆盖层**取代**图表占位，而不是盖在图表上。过去它是 `Stack` 中的
        // `Positioned.fill`，而 Stack 的高度来自图表固定的 180 px，于是其内容只有
        // 144 px 的滚动视口——而约 200 px 的说明、提示与重试按钮被排到视口之外，
        // 按钮既在面板之外，也在命中测试之外。何况它出现时已无图可护：样本在它出现
        // 之前就被清空，底下只会是一条贴零的直线。
        if (showUnavailable)
          MonitorUnavailableOverlay(message: error!, onRetry: onRetry)
        else
          ResourceChart(
            cpuData: cpuData,
            ramData: ramData,
            cpuColor: cpuColor,
            ramColor: ramColor,
            sampleInterval: sampleInterval,
          ),
        const SizedBox(height: 12),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            _UsageText(label: 'CPU', value: latestCpu, color: cpuColor),
            _UsageText(label: 'RAM', value: latestRam, color: ramColor),
          ],
        ),
      ],
    );

    // Only the glow animates, so the animation is only listened to when it can
    // be seen: with no glow there is no builder to run per frame at all.
    // 会动的只有辉光，因此只在它看得见时才监听动画：没有辉光时，连每帧运行的
    // builder 都不存在。
    if (!showGlow) {
      return _panel(cs, dividerColor, content, glowOpacity: null);
    }
    return AnimatedBuilder(
      animation: glow,
      child: content,
      builder: (context, child) => _panel(
        cs,
        dividerColor,
        child!,
        glowOpacity: 0.15 + glow.value * 0.30,
      ),
    );
  }

  /// The panel box around [child]: border, shadow, and the glow when it applies.
  /// 包裹 [child] 的面板外框：边框、阴影，以及适用时的辉光。
  ///
  /// [glowOpacity] is non-null only on the animated path, where it changes per
  /// frame; the neutral shadow is used for every other state.
  /// [glowOpacity] 仅在有动画时非空，此时它逐帧变化；其余状态一律使用中性阴影。
  Widget _panel(
    ColorScheme cs,
    Color dividerColor,
    Widget child, {
    required double? glowOpacity,
  }) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: dividerColor, width: 0.5),
        boxShadow: glowOpacity == null
            ? [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.12),
                  blurRadius: 10,
                  offset: const Offset(0, 3),
                ),
              ]
            : [
                BoxShadow(
                  color: cs.error.withValues(alpha: glowOpacity),
                  blurRadius: 16,
                  spreadRadius: 2,
                ),
              ],
      ),
      child: child,
    );
  }

  /// The badge at the right of the panel title.
  /// 面板标题右侧的徽标。
  ///
  /// The live badge text carries the interval (`Live · 3s`) in its translation,
  /// which is why the polling period belongs to the same constant as
  /// [sampleInterval]: the two must not drift apart.
  /// 实时徽标的译文自带间隔（`实时 · 3s`），因此轮询周期与 [sampleInterval] 必须是
  /// 同一个常量：两者不能各自漂移。
  Widget _headerBadge(ColorScheme cs, {required bool showUnavailable}) {
    if (live) {
      return ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 128),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(
            color: cs.primary.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(8),
          ),
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
      );
    }
    if (showUnavailable) {
      return ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 128),
        child: Text(
          t('simulated_data'),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: cs.error,
            fontSize: 11,
            fontWeight: FontWeight.w600,
          ),
        ),
      );
    }
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 128),
      child: Text(
        t('recent_samples'),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: cs.onSurface.withValues(alpha: 0.36),
          fontSize: 11,
        ),
      ),
    );
  }
}

/// Covers the chart when monitoring has stopped, stating why and offering a
/// retry.
/// 监控停止时覆盖图表，说明原因并提供重试。
///
/// This overlay is what keeps an unmonitored host honest: there is no
/// simulated curve underneath to mistake for a real one, and the last real
/// samples are cleared before it appears.
/// 这层覆盖是「未监控主机」保持诚实的方式：底下没有被误认成真实数据的模拟曲线，
/// 而且它出现之前最后一次真实样本已被清空。
class MonitorUnavailableOverlay extends StatelessWidget {
  /// Why monitoring stopped, already localized by the page.
  /// 监控停止的原因，已由页面本地化。
  final String message;

  /// Retries the connection.
  /// 重试连接。
  final Future<void> Function() onRetry;

  const MonitorUnavailableOverlay({
    super.key,
    required this.message,
    required this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: cs.surface.withValues(alpha: 0.94),
        borderRadius: BorderRadius.circular(8),
      ),
      padding: const EdgeInsets.all(18),
      child: Center(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.cloud_off_outlined, color: cs.error, size: 32),
              const SizedBox(height: 10),
              Text(
                t('simulated_data'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: cs.onSurface,
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                message,
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: cs.onSurface.withValues(alpha: 0.66),
                  fontSize: 12,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                t('monitor_unavailable_hint'),
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: cs.onSurface.withValues(alpha: 0.52),
                  fontSize: 11,
                ),
              ),
              const SizedBox(height: 14),
              FilledButton.icon(
                onPressed: () => onRetry(),
                icon: const Icon(Icons.refresh, size: 18),
                label: Text(
                  t('retry'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Small colour swatch plus label, one per series.
/// 每条序列一个色块加标签。
class _Legend extends StatelessWidget {
  final String label;
  final Color color;

  const _Legend({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        const SizedBox(width: 4),
        Text(
          label,
          style: TextStyle(
            color: cs.onSurface.withValues(alpha: 0.6),
            fontSize: 11,
          ),
        ),
      ],
    );
  }
}

/// Dot, label and percentage for one series under the chart.
/// 图表下方每条序列的圆点、标签与百分比。
class _UsageText extends StatelessWidget {
  final String label;

  /// The reading to show, or `null` when there is not one.
  /// 要显示的读数；没有时（或无法获知时）为 `null`。
  ///
  /// A missing sample is not a measurement of zero, so it is not rendered as
  /// one: the row shows [noValue] instead, which is the same in every language.
  /// 缺少样本不等于测得了零，因此不按零渲染：此行改为显示 [noValue]，它在每种语言
  /// 里都一样。
  final double? value;

  final Color color;

  /// What "no sample yet" looks like.
  /// 「尚无样本」的呈现形式。
  static const String noValue = '—';

  const _UsageText({
    required this.label,
    required this.value,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final v = value;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 6),
        Text(
          '$label ',
          style: TextStyle(
            color: cs.onSurface.withValues(alpha: 0.6),
            fontSize: 12,
          ),
        ),
        Text(
          v == null ? noValue : '${v.toStringAsFixed(1)}%',
          style: TextStyle(
            color: color,
            fontSize: 13,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }
}
