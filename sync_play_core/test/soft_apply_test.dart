/// soft-apply 纯计算部分对照扩展端 player-binding.ts 与
/// soft-apply-controller.ts 的公式。
library;

import 'package:sync_play_core/sync_play_core.dart';
import 'package:test/test.dart';

void main() {
  group('rateAdjustedPlaybackRate', () {
    test('nudges up when behind, down when ahead, proportional to drift', () {
      // drift=0.6 → offset=0.6*0.18=0.108,未触顶
      expect(
        rateAdjustedPlaybackRate(
          localCurrentTime: 10,
          targetTime: 10.6,
          basePlaybackRate: 1,
        ),
        closeTo(1.108, 0.0001),
      );
      expect(
        rateAdjustedPlaybackRate(
          localCurrentTime: 10.6,
          targetTime: 10,
          basePlaybackRate: 1,
        ),
        closeTo(0.892, 0.0001),
      );
    });

    test('offset is capped so catch-up never becomes a jump', () {
      // rate=1 时上限 0.12;drift=5 会让原始 offset 达 0.9
      expect(
        rateAdjustedPlaybackRate(
          localCurrentTime: 10,
          targetTime: 15,
          basePlaybackRate: 1,
        ),
        closeTo(1.12, 0.0001),
      );
    });

    test('cap widens with the base rate', () {
      // rate=2 时上限 min(0.26, 0.12+1*0.1)=0.22
      expect(
        rateAdjustedPlaybackRate(
          localCurrentTime: 10,
          targetTime: 15,
          basePlaybackRate: 2,
        ),
        closeTo(2.22, 0.0001),
      );
    });
  });

  group('softApplySignature', () {
    test('steps the position by at most the step limit', () {
      // drift=1.0,stepScale=0.45 → stepLimit=clamp(0.45, 0.22, 0.4)=0.4
      final applied = softApplySignature(
        localCurrentTime: 10,
        targetTime: 11,
        basePlaybackRate: 1,
      );
      expect(applied.currentTime, closeTo(10.4, 0.0001));
      // 倍速偏移仍被 ±0.12 夹住(rate=1 时的上限)
      expect(applied.playbackRate, closeTo(1.12, 0.0001));
    });

    test('a small drift still moves by the step floor, not all at once', () {
      // drift=0.3 → |drift|*0.45=0.135,低于 minStep 0.22,步长取 0.22
      final applied = softApplySignature(
        localCurrentTime: 10,
        targetTime: 10.3,
        basePlaybackRate: 1,
      );
      expect(applied.currentTime, closeTo(10.22, 0.0001));
      expect(applied.playbackRate, closeTo(1.054, 0.0001));
    });

    test('steps backwards when ahead of the target', () {
      final applied = softApplySignature(
        localCurrentTime: 11,
        targetTime: 10,
        basePlaybackRate: 1,
      );
      expect(applied.currentTime, closeTo(10.6, 0.0001));
      expect(applied.playbackRate, closeTo(0.88, 0.0001));
    });
  });

  group('softApplyTimeoutMs', () {
    test('floors at the minimum for a drift within the recovery band', () {
      expect(
        softApplyTimeoutMs(remainingDriftSeconds: 0.1),
        softApplyMinTimeoutMs,
      );
    });

    test('grows with drift and RTT, capped at the maximum', () {
      // 2000 + (1.2-0.2)*900 = 2900
      expect(softApplyTimeoutMs(remainingDriftSeconds: 1.2), 2900);
      // 2000 + 200*2.5 + 900 = 3400
      expect(softApplyTimeoutMs(remainingDriftSeconds: 1.2, rttMs: 200), 3400);
      expect(
        softApplyTimeoutMs(remainingDriftSeconds: 30, rttMs: 5000),
        softApplyMaxTimeoutMs,
      );
    });
  });

  group('relativeDriftCloseMs', () {
    test('is drift divided by the rate offset, in bounds', () {
      // 0.6 / 0.108 = 5.56s
      expect(
        relativeDriftCloseMs(driftSeconds: 0.6, rateOffsetSeconds: 0.108),
        5556,
      );
      // 大偏移收敛快,但不低于下限
      expect(
        relativeDriftCloseMs(driftSeconds: 0.5, rateOffsetSeconds: 5),
        rateOnlyMinRestoreMs,
      );
      // 极小偏移不得让倍速一直挂着
      expect(
        relativeDriftCloseMs(driftSeconds: 100, rateOffsetSeconds: 0.001),
        rateOnlyMaxRestoreMs,
      );
    });
  });
}
