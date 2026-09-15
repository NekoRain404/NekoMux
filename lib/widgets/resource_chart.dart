import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

/// A line chart displaying CPU (blue) and RAM (green) usage over time with 0–100% range and touch tooltips.
/// 折线图组件，显示 CPU 和 RAM 随时间的使用率，范围 0–100%，支持触摸提示。
class ResourceChart extends StatelessWidget {
  final List<FlSpot> cpuData;
  final List<FlSpot> ramData;
  final Color? cpuColor;
  final Color? ramColor;

  /// Time between two consecutive points, used to label the x axis.
  /// 相邻两个点之间的时间间隔，用于标注 X 轴。
  ///
  /// The left label is derived from it as `point count × interval`, so the span
  /// the user reads is the span the caller actually sampled. It defaults to one
  /// second, which is what this chart assumed while the labels were hardcoded —
  /// a caller sampling every three seconds must pass its interval, or the axis
  /// will claim a third of the real window.
  /// 左侧标签由它推导（点数 × 间隔），因此用户读到的跨度就是调用方实际采样的跨度。
  /// 默认 1 秒，即标签写死时本组件的假设——每三秒采样一次的调用方必须传入自己的
  /// 间隔，否则坐标轴会声称只有真实窗口的三分之一。
  final Duration sampleInterval;

  const ResourceChart({
    super.key,
    required this.cpuData,
    required this.ramData,
    this.cpuColor,
    this.ramColor,
    this.sampleInterval = const Duration(seconds: 1),
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return SizedBox(
      height: 180,
      child: LineChart(
        LineChartData(
          minY: 0,
          maxY: 100,
          backgroundColor: Colors.transparent,
          gridData: FlGridData(
            show: true,
            drawVerticalLine: false,
            horizontalInterval: 25,
            getDrawingHorizontalLine: (value) => FlLine(
              color: Theme.of(context).dividerColor.withValues(alpha: 0.3),
              strokeWidth: 0.5,
            ),
          ),
          titlesData: FlTitlesData(
            leftTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 32,
                interval: 25,
                getTitlesWidget: (value, meta) => Text(
                  '${value.toInt()}%',
                  style: TextStyle(
                    color: cs.onSurface
                        .withValues(alpha: 0.6)
                        .withValues(alpha: 0.5),
                    fontSize: 10,
                  ),
                ),
              ),
            ),
            bottomTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 20,
                interval: 5,
                getTitlesWidget: (value, meta) {
                  if (value.toInt() == 0 || value.toInt() == 19) {
                    // `point count × interval`; with the default one-second
                    // interval and 20 points this is the historical `20s`.
                    // 「点数 × 间隔」；在默认 1 秒间隔与 20 个点下即历史上的 `20s`。
                    final span = cpuData.length * sampleInterval.inSeconds;
                    return Text(
                      value.toInt() == 0 ? '${span}s' : '0s',
                      style: TextStyle(
                        color: cs.onSurface
                            .withValues(alpha: 0.6)
                            .withValues(alpha: 0.5),
                        fontSize: 10,
                      ),
                    );
                  }
                  return const SizedBox.shrink();
                },
              ),
            ),
            topTitles: const AxisTitles(
              sideTitles: SideTitles(showTitles: false),
            ),
            rightTitles: const AxisTitles(
              sideTitles: SideTitles(showTitles: false),
            ),
          ),
          borderData: FlBorderData(show: false),
          lineTouchData: LineTouchData(
            touchTooltipData: LineTouchTooltipData(
              tooltipBgColor: cs.surface,
              tooltipRoundedRadius: 8,
              getTooltipItems: (touchedSpots) => touchedSpots.map((spot) {
                final label = spot.barIndex == 0 ? 'CPU' : 'RAM';
                final color = spot.barIndex == 0
                    ? (cpuColor ?? cs.secondary)
                    : (ramColor ?? cs.primary);
                return LineTooltipItem(
                  '$label: ${spot.y.toStringAsFixed(1)}%',
                  TextStyle(
                    color: color,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                );
              }).toList(),
            ),
          ),
          lineBarsData: [
            _buildLine(
              cpuData,
              cpuColor ?? cs.secondary,
              showArea: false,
              showDots: false,
            ),
            _buildLine(
              ramData,
              ramColor ?? cs.primary,
              dashArray: const [8, 5],
              showArea: true,
              showDots: true,
            ),
          ],
        ),
      ),
    );
  }

  LineChartBarData _buildLine(
    List<FlSpot> spots,
    Color color, {
    List<int>? dashArray,
    required bool showArea,
    required bool showDots,
  }) {
    return LineChartBarData(
      spots: spots,
      isCurved: true,
      curveSmoothness: 0.3,
      barWidth: showDots ? 3 : 2.5,
      color: color,
      dashArray: dashArray,
      dotData: FlDotData(
        show: showDots,
        checkToShowDot: (spot, barData) => spot.x == 19,
        getDotPainter: (spot, percent, barData, index) => FlDotCirclePainter(
          radius: 3.5,
          color: color,
          strokeWidth: 2,
          strokeColor: Colors.white,
        ),
      ),
      belowBarData: BarAreaData(
        show: showArea,
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [color.withValues(alpha: 0.10), color.withValues(alpha: 0.0)],
        ),
      ),
    );
  }
}
