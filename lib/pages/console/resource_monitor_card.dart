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

  /// Latest CPU reading in percent.
  /// 最新 CPU 读数（百分比）。
  final double latestCpu;

  /// Latest RAM reading in percent.
  /// 最新 RAM 读数（百分比）。
  final double latestRam;

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
    final showGlow = !showUnavailable && (latestCpu >= 85 || latestRam >= 85);

    return AnimatedBuilder(
      animation: glow,
      builder: (context, child) {
        final glowOpacity = showGlow ? 0.15 + (glow.value * 0.30) : 0.0;

        return Container(
          margin: const EdgeInsets.symmetric(horizontal: 16),
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: cs.surface,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: dividerColor, width: 0.5),
            boxShadow: showGlow
                ? [
                    BoxShadow(
                      color: cs.error.withValues(alpha: glowOpacity),
                      blurRadius: 16,
                      spreadRadius: 2,
                    ),
                  ]
                : [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.12),
                      blurRadius: 10,
                      offset: const Offset(0, 3),
                    ),
                  ],
          ),
          child: Column(
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
              Stack(
                children: [
                  ResourceChart(
                    cpuData: cpuData,
                    ramData: ramData,
                    cpuColor: cpuColor,
                    ramColor: ramColor,
                    sampleInterval: sampleInterval,
                  ),
                  if (showUnavailable)
                    Positioned.fill(
                      child: MonitorUnavailableOverlay(
                        message: error!,
                        onRetry: onRetry,
                      ),
                    ),
                ],
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
          ),
        );
      },
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
  final double value;
  final Color color;

  const _UsageText({
    required this.label,
    required this.value,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
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
          '${value.toStringAsFixed(1)}%',
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
