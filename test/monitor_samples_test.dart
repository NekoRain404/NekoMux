import 'package:fl_chart/fl_chart.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neko_mux/pages/console/monitor_samples.dart';

/// The y value at a fixed x coordinate.
double yAt(List<FlSpot> spots, int index) => spots[index].y;

void main() {
  group('window', () {
    test('starts as a flat zero line at fixed x coordinates', () {
      final samples = MonitorSamples();

      expect(samples.cpuData.length, MonitorSamples.defaultCapacity);
      expect(samples.ramData.length, MonitorSamples.defaultCapacity);
      for (var i = 0; i < samples.capacity; i++) {
        expect(samples.cpuData[i].x, i.toDouble());
        expect(samples.cpuData[i].y, 0);
      }
      expect(samples.isFilled, isFalse);
    });

    test('reports the sampled span, not a hardcoded one', () {
      final samples = MonitorSamples();

      // The 3-second console really covers 60 seconds across its 20 points; the
      // chart used to label that window '20s' because the label was written for
      // a one-second interval.
      expect(samples.windowSeconds(const Duration(seconds: 3)), 60);
      expect(samples.windowSeconds(const Duration(seconds: 1)), 20);
    });
  });

  group('commit', () {
    test('the first sample fills the whole window', () {
      final samples = MonitorSamples();

      samples.commit(cpu: 12.5, ram: 40);

      expect(samples.isFilled, isTrue);
      expect(samples.latestCpu, 12.5);
      expect(samples.latestRam, 40);
      for (var i = 0; i < samples.capacity; i++) {
        expect(yAt(samples.cpuData, i), 12.5);
        expect(yAt(samples.ramData, i), 40);
      }
    });

    test('later samples shift left and append at the right', () {
      final samples = MonitorSamples();
      samples.commit(cpu: 10, ram: 20);
      samples.commit(cpu: 30, ram: 50);

      // x stays fixed: rebuilding with moving x values makes the chart jump and
      // can hide the RAM line.
      for (var i = 0; i < samples.capacity; i++) {
        expect(samples.cpuData[i].x, i.toDouble());
      }
      expect(yAt(samples.cpuData, samples.capacity - 2), 10);
      expect(yAt(samples.cpuData, samples.capacity - 1), 30);
      expect(yAt(samples.ramData, samples.capacity - 2), 20);
      expect(yAt(samples.ramData, samples.capacity - 1), 50);
      expect(samples.latestCpu, 30);
      expect(samples.latestRam, 50);
    });

    test('keeps the latest reading independent of the buffer', () {
      final samples = MonitorSamples();
      samples.commit(cpu: 10, ram: 20);
      samples.commit(cpu: 30, ram: 50);

      // `docs/MAINTENANCE.md`: the chart is a rendering buffer, the latest
      // value is stored separately, and clearing the buffer must not lose it.
      samples.beginSession();
      expect(samples.latestCpu, 30);
      expect(samples.latestRam, 50);
    });

    test('a new session refills the window on its first sample', () {
      final samples = MonitorSamples();
      samples.commit(cpu: 10, ram: 20);
      samples.commit(cpu: 30, ram: 50);

      samples.beginSession();
      expect(samples.isFilled, isFalse);
      // The old points stay visible until the new session has one of its own —
      // they are still the last thing actually measured.
      expect(yAt(samples.cpuData, 0), 10);

      samples.commit(cpu: 70, ram: 80);
      for (var i = 0; i < samples.capacity; i++) {
        expect(yAt(samples.cpuData, i), 70);
        expect(yAt(samples.ramData, i), 80);
      }
    });
  });

  group('clear', () {
    test('drops both the points and the latest reading', () {
      final samples = MonitorSamples();
      samples.commit(cpu: 90, ram: 95);

      samples.clear();

      expect(samples.latestCpu, 0);
      expect(samples.latestRam, 0);
      expect(samples.isFilled, isFalse);
      for (var i = 0; i < samples.capacity; i++) {
        expect(yAt(samples.cpuData, i), 0);
        expect(yAt(samples.ramData, i), 0);
      }

      // The window refills from scratch, so a stopped session's curve cannot
      // reappear as if it were current.
      samples.commit(cpu: 5, ram: 6);
      for (var i = 0; i < samples.capacity; i++) {
        expect(yAt(samples.cpuData, i), 5);
      }
    });
  });
}
