/// 本地显式操作保护窗口对照 pending-local-override.ts。
library;

import 'package:sync_play_core/sync_play_core.dart';
import 'package:test/test.dart';

const _url = 'https://www.bilibili.com/video/BV1xx411c7mD?cid=42';

PlaybackState _playback({
  double currentTime = 30,
  PlaybackPlayState playState = PlaybackPlayState.playing,
  PlaybackSyncIntent? syncIntent,
  double playbackRate = 1,
  String actorId = 'member-2',
  num seq = 1,
}) => PlaybackState(
  url: _url,
  currentTime: currentTime,
  playState: playState,
  syncIntent: syncIntent,
  playbackRate: playbackRate,
  updatedAt: 1000,
  serverTime: 1000,
  actorId: actorId,
  seq: seq,
);

void main() {
  group('rememberPendingLocalOverride', () {
    test('registers on an explicit seek', () {
      final pending = rememberPendingLocalOverride(
        payload: _playback(
          currentTime: 200,
          syncIntent: PlaybackSyncIntent.explicitSeek,
          seq: 7,
        ),
        now: 1000,
      );
      expect(pending?.kind, PendingLocalOverrideKind.seek);
      expect(pending?.targetTime, 200);
      expect(pending?.seq, 7);
      expect(pending?.expiresAt, 1000 + pendingLocalSeekGuardMs);
    });

    test('registers on a broadcast following a user rate change', () {
      final pending = rememberPendingLocalOverride(
        payload: _playback(playbackRate: 2),
        now: 1000,
        followsUserRatechange: true,
      );
      expect(pending?.kind, PendingLocalOverrideKind.ratechange);
      expect(pending?.playbackRate, 2);
    });

    test('an ordinary heartbeat registers nothing', () {
      expect(
        rememberPendingLocalOverride(payload: _playback(), now: 1000),
        isNull,
      );
    });
  });

  group('decidePendingLocalOverride', () {
    PendingLocalOverride seekPending({num seq = 7, num expiresAt = 6000}) => (
      kind: PendingLocalOverrideKind.seek,
      url: _url,
      seq: seq,
      expiresAt: expiresAt,
      targetTime: 200.0,
      playbackRate: null,
    );

    PendingLocalOverrideDecision decide(
      PlaybackState playback, {
      PendingLocalOverride? pending,
      num now = 2000,
    }) => decidePendingLocalOverride(
      pending: pending ?? seekPending(),
      playback: playback,
      localMemberId: 'member-1',
      now: now,
    );

    test('ignores stale remote state while a local seek is in flight', () {
      // 我们跳到了 200,房间还在流转跳之前的 30
      final decision = decide(_playback(currentTime: 30));
      expect(decision.shouldIgnore, isTrue);
      expect(decision.reason, 'pending-local-explicit-seek');
      expect(decision.nextPending, isNotNull);
    });

    test('releases once the room reaches the seek target', () {
      final decision = decide(_playback(currentTime: 200.2));
      expect(decision.shouldIgnore, isFalse);
      expect(decision.reason, 'seek-settled');
      expect(decision.nextPending, isNull);
    });

    test('releases when our own broadcast comes back acknowledged', () {
      final decision = decide(
        _playback(currentTime: 30, actorId: 'member-1', seq: 7),
      );
      expect(decision.shouldIgnore, isFalse);
      expect(decision.reason, 'self-echo-ack');
      expect(decision.nextPending, isNull);
    });

    test('an older self broadcast does not release the guard', () {
      final decision = decide(
        _playback(currentTime: 30, actorId: 'member-1', seq: 6),
      );
      expect(decision.shouldIgnore, isTrue);
    });

    test('expires so a lost seek cannot block sync forever', () {
      final decision = decide(_playback(currentTime: 30), now: 6001);
      expect(decision.shouldIgnore, isFalse);
      expect(decision.reason, 'expired');
      expect(decision.nextPending, isNull);
    });

    test('does not guard against a different video', () {
      final other = PlaybackState(
        url: 'https://www.bilibili.com/video/BV1ab411c7mD',
        currentTime: 30,
        playState: PlaybackPlayState.playing,
        playbackRate: 1,
        updatedAt: 1000,
        serverTime: 1000,
        actorId: 'member-2',
        seq: 1,
      );
      expect(decide(other).shouldIgnore, isFalse);
    });

    test('a rate guard only applies to playing state', () {
      final pending = (
        kind: PendingLocalOverrideKind.ratechange,
        url: _url,
        seq: 7,
        expiresAt: 6000,
        targetTime: null,
        playbackRate: 2.0,
      );
      expect(
        decide(_playback(playbackRate: 1), pending: pending).shouldIgnore,
        isTrue,
      );
      expect(
        decide(
          _playback(playState: PlaybackPlayState.paused, playbackRate: 1),
          pending: pending,
        ).shouldIgnore,
        isFalse,
      );
      expect(
        decide(_playback(playbackRate: 2), pending: pending).reason,
        'rate-settled',
      );
    });
  });
}
