/// 同步守卫对照 sync-guards.ts。
library;

import 'package:sync_play_core/sync_play_core.dart';
import 'package:test/test.dart';

const _url = 'https://www.bilibili.com/video/BV1xx411c7mD?cid=42';
const _other = 'https://www.bilibili.com/video/BV1ab411c7mD';

PlaybackState _playback({
  double currentTime = 30,
  PlaybackPlayState playState = PlaybackPlayState.playing,
  double playbackRate = 1,
}) => PlaybackState(
  url: _url,
  currentTime: currentTime,
  playState: playState,
  playbackRate: playbackRate,
  updatedAt: 1000,
  serverTime: 1000,
  actorId: 'member-2',
  seq: 1,
);

void main() {
  group('shouldForcePauseWhileWaitingForInitialRoomState', () {
    test('only fires in a room, while hydrating, and playing', () {
      bool call({
        String? room = 'ABC123',
        bool hydrating = true,
        bool paused = false,
      }) => shouldForcePauseWhileWaitingForInitialRoomState(
        activeRoomCode: room,
        pendingRoomStateHydration: hydrating,
        isLocalPaused: paused,
      );
      expect(call(), isTrue);
      expect(call(room: null), isFalse);
      expect(call(hydrating: false), isFalse);
      expect(call(paused: true), isFalse);
    });
  });

  group('shouldApplySelfPlayback', () {
    test('applies when the local player contradicts our own state', () {
      // 房间说暂停,本地还在播
      expect(
        shouldApplySelfPlayback(
          isLocalPaused: false,
          localCurrentTime: 30,
          localPlaybackRate: 1,
          playback: _playback(playState: PlaybackPlayState.paused),
        ),
        isTrue,
      );
      // 房间说播放,本地却停着
      expect(
        shouldApplySelfPlayback(
          isLocalPaused: true,
          localCurrentTime: 30,
          localPlaybackRate: 1,
          playback: _playback(),
        ),
        isTrue,
      );
    });

    test('applies on position or rate drift, skips when aligned', () {
      expect(
        shouldApplySelfPlayback(
          isLocalPaused: false,
          localCurrentTime: 30.7,
          localPlaybackRate: 1,
          playback: _playback(),
        ),
        isTrue,
      );
      expect(
        shouldApplySelfPlayback(
          isLocalPaused: false,
          localCurrentTime: 30,
          localPlaybackRate: 1.5,
          playback: _playback(),
        ),
        isTrue,
      );
      expect(
        shouldApplySelfPlayback(
          isLocalPaused: false,
          localCurrentTime: 30.3,
          localPlaybackRate: 1,
          playback: _playback(),
        ),
        isFalse,
      );
    });
  });

  group('shouldSuppressLocalEcho', () {
    SuppressedRemotePlayback suppressed({
      PlaybackPlayState playState = PlaybackPlayState.playing,
      double currentTime = 30,
      double playbackRate = 1,
    }) => (
      until: 2000,
      url: _url,
      playState: playState,
      currentTime: currentTime,
      playbackRate: playbackRate,
    );

    bool call({
      String? url = _url,
      PlaybackPlayState playState = PlaybackPlayState.playing,
      double currentTime = 30,
      double playbackRate = 1,
      num now = 1000,
      SuppressedRemotePlayback? memory,
    }) => shouldSuppressLocalEcho(
      suppressedRemotePlayback: memory ?? suppressed(),
      normalizedCurrentUrl: url,
      playState: playState,
      currentTime: currentTime,
      playbackRate: playbackRate,
      now: now,
    ).shouldSuppress;

    test('suppresses a matching echo, releases past the window', () {
      expect(call(), isTrue);
      expect(call(now: 2001), isFalse);
    });

    test('a different url, rate or play state is not an echo', () {
      expect(call(url: _other), isFalse);
      expect(call(playbackRate: 2), isFalse);
      expect(call(playState: PlaybackPlayState.paused), isFalse);
    });

    test('buffering counts as an echo of a remote playing state', () {
      expect(call(playState: PlaybackPlayState.buffering), isTrue);
    });

    test('the position threshold widens when both sides play', () {
      expect(call(currentTime: 30.8), isTrue);
      expect(call(currentTime: 31.0), isFalse);
      // 双方都不在播时收紧
      expect(
        call(
          playState: PlaybackPlayState.paused,
          currentTime: 30.3,
          memory: suppressed(playState: PlaybackPlayState.paused),
        ),
        isFalse,
      );
    });
  });

  group('shouldSuppressProgrammaticEvent', () {
    ({bool shouldSuppress, bool clearWindow}) call({
      LocalPlaybackEventSource eventSource = LocalPlaybackEventSource.playing,
      double currentTime = 30,
      ExplicitUserAction? action,
      num now = 500,
      ProgrammaticPlaybackSignature? signature = (
        url: _url,
        playState: PlaybackPlayState.playing,
        currentTime: 30.0,
        playbackRate: 1.0,
      ),
    }) => shouldSuppressProgrammaticEvent(
      programmaticApplyUntil: 1000,
      programmaticApplySignature: signature,
      normalizedCurrentUrl: _url,
      playState: PlaybackPlayState.playing,
      currentTime: currentTime,
      playbackRate: 1,
      eventSource: eventSource,
      lastExplicitUserAction: action,
      now: now,
    );

    test('no signature or an expired window suppresses nothing', () {
      expect(call(signature: null).shouldSuppress, isFalse);
      expect(call(now: 1001).shouldSuppress, isFalse);
    });

    test('the position threshold varies by event source', () {
      // seeked 档 0.6s
      expect(
        call(
          eventSource: LocalPlaybackEventSource.seeked,
          currentTime: 30.5,
        ).shouldSuppress,
        isTrue,
      );
      expect(
        call(
          eventSource: LocalPlaybackEventSource.seeked,
          currentTime: 30.7,
        ).shouldSuppress,
        isFalse,
      );
      // ratechange 档放宽到 1.2s
      expect(
        call(
          eventSource: LocalPlaybackEventSource.ratechange,
          currentTime: 31.1,
        ).shouldSuppress,
        isTrue,
      );
    });

    test('a matching user gesture is never an echo', () {
      final decision = call(
        eventSource: LocalPlaybackEventSource.pause,
        action: (kind: ExplicitUserActionKind.pause, at: 400),
      );
      expect(decision.shouldSuppress, isFalse);
      expect(decision.clearWindow, isTrue);
    });
  });

  group('shouldSuppressRemoteFollowupBroadcast', () {
    bool call({
      PlaybackPlayState playState = PlaybackPlayState.playing,
      LocalPlaybackEventSource eventSource = LocalPlaybackEventSource.playing,
      ExplicitUserAction? action,
      num now = 500,
      String? url = _url,
    }) => shouldSuppressRemoteFollowupBroadcast(
      remoteFollowPlayingUntil: 1000,
      remoteFollowPlayingUrl: _url,
      normalizedCurrentUrl: url,
      playState: playState,
      eventSource: eventSource,
      lastExplicitUserAction: action,
      now: now,
    ).shouldSuppress;

    test('suppresses follow-up playing noise inside the window', () {
      expect(call(), isTrue);
      expect(call(now: 1001), isFalse);
      expect(call(url: _other), isFalse);
    });

    test('a pause is a real change and clears the window', () {
      final decision = shouldSuppressRemoteFollowupBroadcast(
        remoteFollowPlayingUntil: 1000,
        remoteFollowPlayingUrl: _url,
        normalizedCurrentUrl: _url,
        playState: PlaybackPlayState.paused,
        eventSource: LocalPlaybackEventSource.pause,
        lastExplicitUserAction: null,
        now: 500,
      );
      expect(decision.shouldSuppress, isFalse);
      expect(decision.nextUrl, isNull);
    });

    test('user gestures and post-seek playback are let through', () {
      expect(
        call(
          eventSource: LocalPlaybackEventSource.play,
          action: (kind: ExplicitUserActionKind.play, at: 400),
        ),
        isFalse,
      );
      expect(
        call(
          eventSource: LocalPlaybackEventSource.canplay,
          action: (kind: ExplicitUserActionKind.seek, at: 400),
        ),
        isFalse,
      );
    });
  });

  group('shouldSuppressRemotePlayTransition', () {
    bool call({
      PlaybackPlayState playState = PlaybackPlayState.paused,
      double currentTime = 30,
      ExplicitPlaybackAction? action,
      num now = 500,
    }) => shouldSuppressRemotePlayTransition(
      recentRemotePlayingIntent: (until: 1000, url: _url, currentTime: 30),
      normalizedCurrentUrl: _url,
      playState: playState,
      currentTime: currentTime,
      lastExplicitPlaybackAction: action,
      now: now,
    ).shouldSuppress;

    test('suppresses a transient pause near the applied position', () {
      expect(call(), isTrue);
      expect(call(currentTime: 32), isFalse);
      expect(call(now: 1001), isFalse);
      expect(call(playState: PlaybackPlayState.playing), isFalse);
    });

    test('a deliberate user pause is never suppressed', () {
      expect(
        call(action: (playState: PlaybackPlayState.paused, at: 400)),
        isFalse,
      );
    });
  });

  group('hasRecentRemoteStopIntent', () {
    bool call({
      num now = 500,
      PlaybackPlayState? intended = PlaybackPlayState.paused,
      String? shared = _url,
      String? current = _url,
      SuppressedRemotePlayback? memory,
    }) => hasRecentRemoteStopIntent(
      now: now,
      pauseHoldUntil: 1000,
      normalizedCurrentUrl: current,
      activeSharedUrl: shared,
      intendedPlayState: intended,
      suppressedRemotePlayback: memory,
    );

    test('holds while the pause intent is live', () {
      expect(call(), isTrue);
      expect(call(now: 1001), isFalse);
    });

    test('does not hold on a different video', () {
      expect(call(current: _other), isFalse);
    });

    test('falls back to the last applied remote state', () {
      expect(call(intended: PlaybackPlayState.playing), isFalse);
      expect(
        call(
          intended: PlaybackPlayState.playing,
          memory: (
            until: 2000,
            url: _url,
            playState: PlaybackPlayState.paused,
            currentTime: 30,
            playbackRate: 1,
          ),
        ),
        isTrue,
      );
    });
  });
}
