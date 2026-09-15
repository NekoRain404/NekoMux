import 'package:fl_chart/fl_chart.dart';

/// The CPU/RAM series the console chart draws.
/// 控制台图表绘制的 CPU/RAM 序列。
///
/// This is a rendering buffer, not a source of truth: `docs/MAINTENANCE.md`
/// keeps the latest numeric values separate ([latestCpu] / [latestRam]) so the
/// chart can be reset without losing the current reading.
/// 这只是渲染缓冲，不是真相来源：`docs/MAINTENANCE.md` 要求把最新数值单独存放
/// （[latestCpu] / [latestRam]），从而在重置图表时不丢失当前读数。
///
/// The x coordinates are fixed at 0…capacity-1 and values shift left. Rebuilding
/// with variable x values makes the chart jump and can hide the RAM line, which
/// is why the shift is done here once instead of at each call site.
/// x 坐标固定为 0…capacity-1，数值向左移动。改用变化的 x 值重建会让图表跳动，
/// 还可能把 RAM 线藏起来，因此这次移动集中在这里做一次，而不是散落在各调用点。
class MonitorSamples {
  /// How many points the window holds — the console has always drawn 20.
  /// 窗口内的点数——控制台一直画 20 个。
  static const int defaultCapacity = 20;

  MonitorSamples({int capacity = defaultCapacity})
    : capacity = capacity,
      cpuData = List.generate(capacity, (i) => FlSpot(i.toDouble(), 0)),
      ramData = List.generate(capacity, (i) => FlSpot(i.toDouble(), 0));

  /// Number of points in the window.
  /// 窗口内的点数。
  final int capacity;

  /// CPU series, mutated in place by [commit].
  /// CPU 序列，由 [commit] 原地修改。
  final List<FlSpot> cpuData;

  /// RAM series, mutated in place by [commit].
  /// RAM 序列，由 [commit] 原地修改。
  final List<FlSpot> ramData;

  double _latestCpu = 0;
  double _latestRam = 0;
  bool _filled = false;

  /// Latest CPU reading, independent of the chart buffer.
  /// 最新 CPU 读数，独立于图表缓冲。
  double get latestCpu => _latestCpu;

  /// Latest RAM reading, independent of the chart buffer.
  /// 最新 RAM 读数，独立于图表缓冲。
  double get latestRam => _latestRam;

  /// Whether a real sample has filled the window since the last [beginSession]
  /// or [clear].
  /// 自上次 [beginSession] 或 [clear] 以来，是否已有真实样本填满窗口。
  bool get isFilled => _filled;

  /// The time span the whole window covers at a sampling [interval].
  /// 在采样间隔 [interval] 下，整个窗口覆盖的时间跨度。
  ///
  /// The chart labels its axis with this, which is what keeps the number on
  /// screen equal to the number of seconds actually represented — the axis used
  /// to be written for a one-second interval while the console sampled every
  /// three, so the span a user read was a third of the real one.
  /// 图表用它标注坐标轴，从而让屏幕上的数字等于实际代表的秒数——坐标轴过去是按
  /// 一秒采样间隔写的，而控制台每三秒采一次，用户读到的跨度只有真实值的三分之一。
  int windowSeconds(Duration interval) => capacity * interval.inSeconds;

  /// Records one sample as the newest point.
  /// 将一个样本记录为最新的点。
  ///
  /// The first sample after a session starts fills the whole window instead of
  /// sitting alone at the right edge, so a reading that is real from the first
  /// tick (memory) is drawn across it immediately rather than after a minute of
  /// sliding. A `cpu` of 0 on that first sample is the caller saying there is
  /// no delta yet, not a measured idle CPU.
  /// 会话开始后的首个样本会填满整个窗口，而不是孤零零地待在右边缘，使从第一个 tick
  /// 起就真实的读数（内存）立即铺满窗口，而不必等它滑动一分钟。首个样本里 `cpu`
  /// 为 0 是调用方表示「尚无增量」，而不是测得了空闲的 CPU。
  void commit({required double cpu, required double ram}) {
    _latestCpu = cpu;
    _latestRam = ram;

    if (!_filled) {
      for (var i = 0; i < capacity; i++) {
        cpuData[i] = FlSpot(i.toDouble(), cpu);
        ramData[i] = FlSpot(i.toDouble(), ram);
      }
      _filled = true;
      return;
    }

    for (var i = 0; i < capacity - 1; i++) {
      cpuData[i] = FlSpot(i.toDouble(), cpuData[i + 1].y);
      ramData[i] = FlSpot(i.toDouble(), ramData[i + 1].y);
    }
    final last = (capacity - 1).toDouble();
    cpuData[capacity - 1] = FlSpot(last, cpu);
    ramData[capacity - 1] = FlSpot(last, ram);
  }

  /// Starts a fresh session while leaving the current points on screen.
  /// 开启新会话，同时保留屏幕上现有的点。
  ///
  /// Used when reconnecting: the old points are still the last thing actually
  /// measured, and the first sample of the new session replaces all of them, so
  /// the window never mixes two sessions' samples as if they were contiguous.
  /// 用于重连：旧点仍是最后一次真实测量的结果，而新会话的首个样本会整体替换它们，
  /// 窗口因此不会把两次会话的样本当成连续数据混在一起。
  void beginSession() {
    _filled = false;
  }

  /// Drops the window back to an empty (all-zero) state.
  /// 将窗口清回空（全零）状态。
  ///
  /// Used when monitoring stops: no live data is being displayed, and leaving
  /// the last session's curve behind the overlay would invite reading it as
  /// current.
  /// 用于监控停止时：此时没有任何实时数据在显示，把上一次会话的曲线留在覆盖层
  /// 后面，只会让人把它当成当前值来读。
  void clear() {
    _filled = false;
    _latestCpu = 0;
    _latestRam = 0;
    for (var i = 0; i < capacity; i++) {
      cpuData[i] = FlSpot(i.toDouble(), 0);
      ramData[i] = FlSpot(i.toDouble(), 0);
    }
  }
}
