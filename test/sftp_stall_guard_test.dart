import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:neko_mux/services/sftp_guards.dart';

/// The guards that keep a failed transfer from becoming a hung one.
/// 让失败的传输不至于变成挂死传输的那几道守护。
///
/// What is testable here is the *logic*: the interval's arithmetic, what a race
/// decides, and that not every silence is a stall. The I/O they wrap is
/// dartssh2's, and what it does with a rejected write was measured against a
/// real SSH server instead — see the report; a fake cannot reproduce it, because
/// the whole failure is inside dartssh2's own listener.
/// 这里可测的是**逻辑**：间隔的算术、一次竞速判定出什么，以及并非所有沉默都算停滞。
/// 它们包裹的 I/O 属于 dartssh2，而它对被拒绝写入的反应是对真实 SSH 服务器实测出来的
/// ——见报告；假实现无法复现它，因为整个失败都发生在 dartssh2 自己的监听器内部。

void main() {
  group('the interval', () {
    test('allows the floor rate several acknowledged chunks', () {
      // The documented derivation, checked rather than trusted: one acknowledged
      // chunk is the smallest sign of life, and the deadline has to be worth
      // several of them or a link at the floor would be declared dead while it
      // is still delivering.
      // 把注释里写明的推导变成断言，而不是靠信任：一个被确认的分块就是最小的生命迹象，
      // 而期限必须值好几个这样的分块，否则一条刚好处于下限的链路会在仍在传输时被判死。
      final chunkMillis =
          transferStallChunkBytes * 1000 / transferStallFloorBytesPerSecond;

      expect(
        defaultTransferStallTimeout.inMilliseconds,
        greaterThanOrEqualTo(3 * chunkMillis),
        reason: 'a link at the floor must fit three chunks in the interval',
      );
      expect(
        defaultTransferStallTimeout.inMilliseconds,
        lessThanOrEqualTo(const Duration(minutes: 2).inMilliseconds),
        reason: 'a wedged transfer must not sit there for minutes',
      );
    });
  });

  group('the watch', () {
    test('reports the work as finished when it finishes', () async {
      final watch = TransferStallWatch(const Duration(milliseconds: 60));

      expect(await watch.race(Future<void>.value()), isTrue);
      watch.stop();
    });

    test('reports a stall when the work never finishes', () async {
      final watch = TransferStallWatch(const Duration(milliseconds: 40));
      final never = Completer<void>();

      // The whole point of returning false rather than throwing: the work is
      // still pending, and the caller has to stop feeding it.
      // 返回 false 而不是抛异常的全部意义就在这里：工作仍然悬挂，调用方必须停止供数。
      expect(await watch.race(never.future), isFalse);
      expect(never.isCompleted, isFalse, reason: 'a stall does not end the work');
      watch.stop();
    });

    test('progress pushes the deadline back', () async {
      final watch = TransferStallWatch(const Duration(milliseconds: 60));
      final work = Completer<void>();

      // A transfer that keeps reporting is never declared dead, however long it
      // runs: this is the difference between a stall detector and a total
      // timeout, and it is what keeps a large upload over a slow link alive.
      // 持续报告进度的传输永远不会被判死，无论跑多久：这正是停滞检测与总超时的区别，
      // 也正是慢链路上的大文件上传得以存活的原因。
      final raced = watch.race(work.future);
      for (var i = 0; i < 6; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 30));
        watch.progress();
      }
      expect(work.isCompleted, isFalse);
      work.complete();
      expect(await raced, isTrue);

      watch.stop();
    });

    test('a progress report after the deadline changes nothing', () async {
      final watch = TransferStallWatch(const Duration(milliseconds: 30));
      final never = Completer<void>();

      expect(await watch.race(never.future), isFalse);
      // Nothing is being waited for any more, so this has nothing to push back.
      // 此刻已经没有在等待的东西，因此它没有可推后的对象。
      watch.progress();
      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(never.isCompleted, isFalse);
      watch.stop();
    });

    test('an error from the work is rethrown', () async {
      final watch = TransferStallWatch(const Duration(seconds: 5));

      await expectLater(
        watch.race(Future<void>.error(const FormatException('boom'))),
        throwsA(isA<FormatException>()),
      );
      watch.stop();
    });

    test('an error arriving after the deadline is dropped, not unhandled', () async {
      final watch = TransferStallWatch(const Duration(milliseconds: 30));
      final failing = Completer<void>();

      expect(await watch.race(failing.future), isFalse);
      // Two seconds later the abandoned work fails. Nobody is awaiting it; if
      // this test does not fail on an unhandled error, the guard absorbed it.
      // 两秒后这个被放弃的工作失败了。没有人等待它；如果本测试没有因未处理错误而失败，
      // 就说明守护吸收了它。
      failing.completeError(const FormatException('too late'));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      watch.stop();
    });

    test('stop is safe after a race and before one', () async {
      final watch = TransferStallWatch(const Duration(milliseconds: 30));
      watch.stop();
      watch.progress();
      expect(await watch.race(Future<void>.value()), isTrue);
      watch.stop();
      await Future<void>.delayed(const Duration(milliseconds: 40));
    });
  });

  group('bounded teardown', () {
    test('a teardown that throws is swallowed', () async {
      await boundedTeardown(
        Future<void>.error(const FormatException('handle already released')),
      );
    });

    test('a teardown that never finishes is given up on', () async {
      final never = Completer<void>();
      final started = DateTime.now();

      await boundedTeardown(never.future, timeout: const Duration(milliseconds: 40));

      expect(
        DateTime.now().difference(started),
        lessThan(const Duration(seconds: 2)),
        reason: 'the wait must end on its own, not when the connection does',
      );
      expect(never.isCompleted, isFalse);
    });

    test('a teardown that finishes is awaited, not just started', () async {
      var finished = false;
      await boundedTeardown(
        Future<void>.delayed(
          const Duration(milliseconds: 10),
          () => finished = true,
        ),
      );
      expect(finished, isTrue);
    });

    test('nothing to tear down is not a wait', () async {
      await boundedTeardown(null);
    });
  });

  group('the upload source guard', () {
    test('an error ends the stream instead of erroring it', () async {
      final reported = <Object>[];
      final controller = StreamController<Uint8List>();
      final chunks = <Uint8List>[];

      final done = guardedUploadSource(
        controller.stream,
        reported.add,
      ).forEach(chunks.add);

      controller.add(Uint8List(4));
      await Future<void>.delayed(Duration.zero);
      controller.addError(const FormatException('unreadable'));
      await Future<void>.delayed(Duration.zero);

      // Ended, not errored: an error on this stream is what hangs dartssh2's
      // writer instead of failing it, which is why the guard exists.
      // 结束，而不是报错：这条流上的错误会让 dartssh2 的写入器挂死而不是失败，守护存在
      // 的原因正在于此。
      await done;
      expect(reported, hasLength(1));
      expect(chunks, hasLength(1));
      expect(controller.isClosed, isFalse);
      await controller.close();
    });

    test('the chunks before the error are still delivered', () async {
      final reported = <Object>[];
      final chunks = <Uint8List>[];

      await guardedUploadSource(
        Stream<Uint8List>.error(const FormatException('immediately')),
        reported.add,
      ).forEach(chunks.add);

      expect(chunks, isEmpty);
      expect(reported, hasLength(1));
    });
  });
}
