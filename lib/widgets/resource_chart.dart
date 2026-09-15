import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

/// A line chart displaying CPU (blue) and RAM (green) usage over time with 0–100% range and touch tooltips.
/// 折线图组件，显示 CPU 和 RAM 随时间的使用率，范围 0–100%，支持触摸提示。
class ResourceChart extends StatelessWidget {
  final List<FlSpot> cpuData;
  final List<FlSpot> ramData;
  final Color? cpuColor;
  final Color? ramColor;

  const ResourceChart({
    super.key,
    required this.cpuData,
    required this.ramData,
    this.cpuColor,
    this.ramColor,
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
                    return Text(
                      value.toInt() == 0 ? '20s' : '0s',
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
