/// 播放器同步引擎测试:纯决策函数对照扩展端
/// playback-apply/reconcile/broadcast 的语义,引擎集成用假 session/port。
library;

import 'package:sync_play_core/sync_play_core.dart';
import 'package:test/test.dart';

const sharedUrl = 'https://www.bilibili.com/video/BV1xx411c7mD?cid=42';
const otherUrl = 'https://www.bilibili.com/video/BV1ab411c7mD';

PlaybackState playback({
  String url = sharedUrl,
  double currentTime = 30,
  PlaybackPlayState playState = PlaybackPlayState.playing,
  PlaybackSyncIntent? syncIntent,
  double playbackRate = 1,
  num serverTime = 1000,
  String actorId = 'member-2',
  num seq = 1,
  bool? userInitiated,
}) => PlaybackState(
  url: url,
  currentTime: currentTime,
  playState: playState,
  syncIntent: syncIntent,
  userInitiated: userInitiated,
  playbackRate: playbackRate,
  updatedAt: serverTime,
  serverTime: serverTime,
  actorId: actorId,
  seq: seq,
);

RoomState roomState({
  SharedVideo? sharedVideo = const SharedVideo(
    videoId: 'BV1xx411c7mD:42',
    url: sharedUrl,
    title: 'Video',
    sharedByMemberId: 'member-2',
  ),
  PlaybackState? playback,
}) => RoomState(
  roomCode: 'ABC123',
  sharedVideo: sharedVideo,
  playback: playback,
  members: const [RoomMember(id: 'member-1', name: 'Alice')],
);

class FakeSession implements PlayerSyncSessionApi {
  @override
  String? memberId = 'member-1';
  @override
  String? roomCode = 'ABC123';
  @override
  bool awaitingFreshRoomState = false;
  @override
  RoomState? roomState;
  @override
  double? rttMs;

  final playbackUpdates = <PlaybackState>[];
  final sharedVideos = <SharedVideo>[];

  @override
  void sendPlaybackUpdate(PlaybackState playback) =>
      playbackUpdates.add(playback);

  @override
  void shareVideo(SharedVideo video, {PlaybackState? playback}) =>
      sharedVideos.add(video);
}

class FakePort implements SyncPlayPlayerPort {
  final calls = <String>[];

  @override
  Future<void> seekTo(double seconds) async =>
      calls.add('seekTo:${seconds.toStringAsFixed(1)}');

  @override
  Future<void> play() async => calls.add('play');

  @override
  Future<void> pause() async => calls.add('pause');

  @override
  Future<void> setRate(double rate) async => calls.add('setRate:$rate');

  @override
  Future<void> openVideo(
    BilibiliVideoRef ref, {
    required double initialSeconds,
    required bool startPaused,
  }) async => calls.add(
    'openVideo:${ref.normalizedUrl}'
    ':${initialSeconds.toStringAsFixed(1)}:paused=$startPaused',
  );
}

class DeferredTask {
  DeferredTask(this.delay, this.task);

  final Duration delay;
  final void Function() task;
  bool cancelled = false;
}

class EngineHarness {
  EngineHarness() {
    engine = PlayerSyncEngine(
      session: session,
      port: port,
      nowMs: () => now,
      scheduleDelayed: (delay, task) {
        final entry = DeferredTask(delay, task);
        deferred.add(entry);
        return () => entry.cancelled = true;
      },
    );
  }

  final session = FakeSession();
  final port = FakePort();
  num now = 100000;
  late final PlayerSyncEngine engine;

  /// 引擎登记的延迟任务(远端 pause 去抖),由测试手动触发。
  final List<DeferredTask> deferred = [];

  /// 触发所有未取消的到期任务,返回实际执行的个数。
  Future<int> fireDeferred() async {
    var fired = 0;
    for (final entry in List.of(deferred)) {
      if (entry.cancelled) {
        continue;
      }
      entry.task();
      fired++;
    }
    deferred.clear();
    // 施加是 async 的,让出一拍等它跑完
    await Future<void>.delayed(Duration.zero);
    return fired;
  }

  LocalPlaybackSnapshot snapshot({
    double position = 30,
    PlaybackPlayState playState = PlaybackPlayState.playing,
    double rate = 1,
  }) => (positionSeconds: position, playState: playState, playbackRate: rate);

  /// 加载共享视频并完成 hydration(施加过一次权威状态)。
  Future<void> loadSharedVideoAndHydrate() async {
    engine.onVideoLoaded(bvid: 'BV1xx411c7mD', cid: 42, title: 'Video');
    final state = roomState(playback: playback(currentTime: 30));
    session.roomState = state;
    engine.lastKnownPositionSeconds = 30;
    engine.lastKnownRate = 1;
    await engine.applyRoomState(state);
    port.calls.clear();
    session.playbackUpdates.clear();
  }
}

void main() {
  group('decidePlaybackReconcileMode', () {
    test('paused: hard-seek beyond 0.15s, ignore within', () {
      expect(
        decidePlaybackReconcileMode(
          localCurrentTime: 10,
          targetTime: 10.1,
          playState: PlaybackPlayState.paused,
        ).mode,
        PlaybackReconcileMode.ignore,
      );
      expect(
        decidePlaybackReconcileMode(
          localCurrentTime: 10,
          targetTime: 10.2,
          playState: PlaybackPlayState.paused,
        ).mode,
        PlaybackReconcileMode.hardSeek,
      );
    });

    test('playing: tiered thresholds at rate 1', () {
      PlaybackReconcileMode modeFor(double delta) =>
          decidePlaybackReconcileMode(
            localCurrentTime: 10,
            targetTime: 10 + delta,
            playState: PlaybackPlayState.playing,
          ).mode;
      expect(modeFor(0.4), PlaybackReconcileMode.ignore);
      expect(modeFor(0.7), PlaybackReconcileMode.rateOnly);
      expect(modeFor(1.1), PlaybackReconcileMode.softApply);
      expect(modeFor(1.5), PlaybackReconcileMode.hardSeek);
    });

    test('playing: thresholds widen with playback rate', () {
      // rate=2 时 ignore 阈值 0.45*(1+1*0.35)=0.6075
      expect(
        decidePlaybackReconcileMode(
          localCurrentTime: 10,
          targetTime: 10.5,
          playState: PlaybackPlayState.playing,
          playbackRate: 2,
        ).mode,
        PlaybackReconcileMode.ignore,
      );
    });

    test('explicit seek always hard-seeks', () {
      expect(
        decidePlaybackReconcileMode(
          localCurrentTime: 10,
          targetTime: 10.05,
          playState: PlaybackPlayState.playing,
          isExplicitSeek: true,
        ).mode,
        PlaybackReconcileMode.hardSeek,
      );
    });
  });

  group('derivePlaybackSyncIntent', () {
    test('recent user seek carried by timeupdate within 2.5s grace', () {
      final intent = derivePlaybackSyncIntent(
        eventSource: LocalPlaybackEventSource.timeupdate,
        lastExplicitUserAction: (kind: ExplicitUserActionKind.seek, at: 1000),
        lastForcedPauseAt: 0,
        now: 3400,
      );
      expect(intent, PlaybackSyncIntent.explicitSeek);
      expect(
        derivePlaybackSyncIntent(
          eventSource: LocalPlaybackEventSource.timeupdate,
          lastExplicitUserAction: (kind: ExplicitUserActionKind.seek, at: 1000),
          lastForcedPauseAt: 0,
          now: 3600,
        ),
        isNull,
      );
    });

    test('actions preceding a forced pause are inert', () {
      expect(
        derivePlaybackSyncIntent(
          eventSource: LocalPlaybackEventSource.seeked,
          lastExplicitUserAction: (kind: ExplicitUserActionKind.seek, at: 1000),
          lastForcedPauseAt: 1500,
          now: 1600,
        ),
        isNull,
      );
    });

    test('user ratechange within grace maps to explicit-ratechange', () {
      expect(
        derivePlaybackSyncIntent(
          eventSource: LocalPlaybackEventSource.ratechange,
          lastExplicitUserAction: (
            kind: ExplicitUserActionKind.ratechange,
            at: 1000,
          ),
          lastForcedPauseAt: 0,
          now: 1500,
        ),
        PlaybackSyncIntent.explicitRatechange,
      );
    });
  });

  group('deriveUserInitiatedPause', () {
    test('true only for pause events backed by a recent explicit pause', () {
      expect(
        deriveUserInitiatedPause(
          eventSource: LocalPlaybackEventSource.pause,
          playState: PlaybackPlayState.paused,
          lastExplicitUserAction: (kind: ExplicitUserActionKind.pause, at: 900),
          lastForcedPauseAt: 0,
          programmaticApplyUntil: 0,
          programmaticApplyPlayState: null,
          now: 1000,
        ),
        isTrue,
      );
    });

    test('false inside a paused programmatic apply window', () {
      expect(
        deriveUserInitiatedPause(
          eventSource: LocalPlaybackEventSource.pause,
          playState: PlaybackPlayState.paused,
          lastExplicitUserAction: (kind: ExplicitUserActionKind.pause, at: 900),
          lastForcedPauseAt: 0,
          programmaticApplyUntil: 1200,
          programmaticApplyPlayState: PlaybackPlayState.paused,
          now: 1000,
        ),
        isFalse,
      );
    });
  });

  group('decidePlaybackApplication', () {
    final currentVideo = buildBilibiliVideoRef(bvid: 'BV1xx411c7mD', cid: 42)!;

    PlaybackApplyDecision decide({
      RoomState? state,
      BilibiliVideoRef? video,
      bool hydrating = false,
      PlaybackVersion? lastApplied,
      PlaybackVersion? lastLocal,
      num now = 10000,
      num lastIntentAt = 0,
      PlaybackPlayState? lastIntentPlayState,
    }) => decidePlaybackApplication(
      roomState: state ?? roomState(playback: playback()),
      currentVideo: video ?? currentVideo,
      normalizedCurrentUrl: (video ?? currentVideo).normalizedUrl,
      pendingRoomStateHydration: hydrating,
      explicitNonSharedPlaybackUrl: null,
      now: now,
      lastLocalIntentAt: lastIntentAt,
      lastLocalIntentPlayState: lastIntentPlayState,
      lastAppliedVersion: lastApplied,
      lastLocalPlaybackVersion: lastLocal,
      localMemberId: 'member-1',
    );

    test('empty room accepts hydration', () {
      final decision = decide(
        state: roomState(sharedVideo: null, playback: null),
        hydrating: true,
      );
      expect(decision, isA<ApplyEmptyRoom>());
      expect((decision as ApplyEmptyRoom).acceptedHydration, isTrue);
    });

    test('non-shared current video pauses on paused hydration only when '
        'not confirmed different', () {
      final other = buildBilibiliVideoRef(bvid: 'BV1ab411c7mD')!;
      final decision = decide(
        state: roomState(
          playback: playback(playState: PlaybackPlayState.paused),
        ),
        video: other,
        hydrating: true,
      );
      expect(decision, isA<ApplyIgnoreNonShared>());
      // 两个 URL 均已规范化且确认不同:不强制暂停
      expect(
        (decision as ApplyIgnoreNonShared).shouldPauseNonSharedVideo,
        isFalse,
      );
    });

    test('local pause intent guards against remote playing', () {
      expect(
        decide(
          now: 10000,
          lastIntentAt: 9500,
          lastIntentPlayState: PlaybackPlayState.paused,
        ),
        isA<ApplyIgnoreLocalGuard>(),
      );
      expect(
        decide(
          now: 10000,
          lastIntentAt: 8000,
          lastIntentPlayState: PlaybackPlayState.paused,
        ),
        isA<ApplyPlayback>(),
      );
    });

    test('stale playback versions are ignored', () {
      expect(
        decide(lastApplied: (serverTime: 2000, seq: 5)),
        isA<ApplyIgnoreStalePlayback>(),
      );
      expect(
        decide(
          state: roomState(playback: playback(serverTime: 2000, seq: 6)),
          lastApplied: (serverTime: 2000, seq: 5),
        ),
        isA<ApplyPlayback>(),
      );
    });

    test('own playback at or below local seq is ignored', () {
      final decision = decide(
        state: roomState(playback: playback(actorId: 'member-1', seq: 3)),
        lastLocal: (serverTime: 0, seq: 3),
      );
      expect(decision, isA<ApplyIgnoreSelfPlaybackVersion>());
    });
  });

  group('PlayerSyncEngine', () {
    test(
      'applies remote playing state: seek + play, suppresses echo',
      () async {
        final harness = EngineHarness();
        harness.engine.onVideoLoaded(bvid: 'BV1xx411c7mD', cid: 42);
        harness.engine.lastKnownPositionSeconds = 10;
        harness.engine.lastKnownRate = 1;
        final state = roomState(playback: playback(currentTime: 30));
        harness.session.roomState = state;

        await harness.engine.applyRoomState(state);
        expect(harness.port.calls, ['seekTo:30.0', 'play']);

        // 程序化施加窗口内回流的 playing 状态是回声,不得广播
        harness.engine.onLocalPlayStateChanged(
          LocalPlaybackEventSource.playing,
          harness.snapshot(),
        );
        expect(harness.session.playbackUpdates, isEmpty);

        // 固定窗口过期,但 seek 尚未在播放器上落地:仍视为回声窗口内,
        // 否则会把 seek 前的旧位置当成新 seek 广播出去
        harness.now += programmaticApplyWindowMs + 100;
        harness.engine.onLocalPosition(harness.snapshot(position: 10));
        expect(harness.engine.isInProgrammaticApplyWindow, isTrue);
        harness.engine.onLocalPlayStateChanged(
          LocalPlaybackEventSource.playing,
          harness.snapshot(),
        );
        expect(harness.session.playbackUpdates, isEmpty);

        // 位置到位后收敛回常规窗口,过期即恢复广播
        harness.engine.onLocalPosition(harness.snapshot(position: 30));
        harness.now += programmaticApplyWindowMs + 100;
        expect(harness.engine.isInProgrammaticApplyWindow, isFalse);
        harness.engine.onLocalPlayStateChanged(
          LocalPlaybackEventSource.playing,
          harness.snapshot(),
        );
        expect(harness.session.playbackUpdates, hasLength(1));
      },
    );

    test('rate-only drift nudges the rate instead of seeking', () async {
      final harness = EngineHarness();
      await harness.loadSharedVideoAndHydrate();
      harness.engine.lastKnownPositionSeconds = 30;

      // 0.7s 漂移落在 rateOnly 档:只调速率,绝不能 seek
      final state = roomState(
        playback: playback(currentTime: 30.7, seq: 5),
      );
      harness.session.roomState = state;
      await harness.engine.applyRoomState(state);

      expect(harness.port.calls, ['setRate:1.12', 'play']);
      expect(harness.port.calls.join(), isNot(contains('seekTo')));
    });

    test('soft-apply drift steps the position, not a full jump', () async {
      final harness = EngineHarness();
      await harness.loadSharedVideoAndHydrate();
      harness.engine.lastKnownPositionSeconds = 30;

      // 1.1s 漂移落在 softApply 档:进度只走一小步(≤0.4s),不是跳到 31.1
      final state = roomState(
        playback: playback(currentTime: 31.1, seq: 5),
      );
      harness.session.roomState = state;
      await harness.engine.applyRoomState(state);

      expect(harness.port.calls, contains('seekTo:30.4'));
      expect(harness.port.calls.join(), isNot(contains('seekTo:31.1')));
    });

    test('restores the base rate when the catch-up converges', () async {
      final harness = EngineHarness();
      await harness.loadSharedVideoAndHydrate();
      harness.engine.lastKnownPositionSeconds = 30;

      final state = roomState(playback: playback(currentTime: 31.1, seq: 5));
      harness.session.roomState = state;
      await harness.engine.applyRoomState(state);
      harness.engine.lastKnownRate = 1.12;
      harness.port.calls.clear();

      // 本地追到目标 ±0.2s 内:恢复基准倍速
      harness.engine.onLocalPosition(harness.snapshot(position: 31.0));
      await Future<void>.delayed(Duration.zero);
      expect(harness.port.calls, contains('setRate:1.0'));
    });

    test('local buffering abandons an active catch-up', () async {
      final harness = EngineHarness();
      await harness.loadSharedVideoAndHydrate();
      harness.engine.lastKnownPositionSeconds = 30;

      final state = roomState(playback: playback(currentTime: 30.7, seq: 5));
      harness.session.roomState = state;
      await harness.engine.applyRoomState(state);
      harness.engine.lastKnownRate = 1.12;
      harness.port.calls.clear();

      // 追平期间开始缓冲:放弃追平并把倍速调回去
      harness.engine.onLocalPlayStateChanged(
        LocalPlaybackEventSource.waiting,
        harness.snapshot(playState: PlaybackPlayState.buffering),
      );
      await Future<void>.delayed(Duration.zero);
      expect(harness.port.calls, contains('setRate:1.0'));
    });

    test('a user rate change ends the catch-up without restoring', () async {
      final harness = EngineHarness();
      await harness.loadSharedVideoAndHydrate();
      harness.engine.lastKnownPositionSeconds = 30;

      final state = roomState(playback: playback(currentTime: 30.7, seq: 5));
      harness.session.roomState = state;
      await harness.engine.applyRoomState(state);
      harness.engine.lastKnownRate = 2;
      harness.now += programmaticApplyWindowMs + 100;
      harness.port.calls.clear();

      // 用户接管倍速:不得把我们的基准倍速覆盖回去
      harness.engine.onLocalRateChanged(harness.snapshot(rate: 2));
      await Future<void>.delayed(Duration.zero);
      expect(harness.port.calls.join(), isNot(contains('setRate')));
    });

    test('never overwrites a rate that is no longer ours', () async {
      final harness = EngineHarness();
      await harness.loadSharedVideoAndHydrate();
      harness.engine.lastKnownPositionSeconds = 30;

      final state = roomState(playback: playback(currentTime: 31.1, seq: 5));
      harness.session.roomState = state;
      await harness.engine.applyRoomState(state);
      // 播放器上的倍速已不是我们写的 1.12(用户在移动端改了速度,
      // 而该路径目前不经过引擎):恢复会吞掉用户的操作
      harness.engine.lastKnownRate = 2;
      harness.port.calls.clear();

      harness.engine.onLocalPosition(harness.snapshot(position: 31.0));
      await Future<void>.delayed(Duration.zero);
      expect(harness.port.calls.join(), isNot(contains('setRate')));
    });

    test('suppresses local broadcasts while catching up', () async {
      final harness = EngineHarness();
      await harness.loadSharedVideoAndHydrate();
      harness.engine.lastKnownPositionSeconds = 30;

      final state = roomState(playback: playback(currentTime: 30.7, seq: 5));
      harness.session.roomState = state;
      await harness.engine.applyRoomState(state);
      harness.now += programmaticApplyWindowMs + 100;
      harness.session.playbackUpdates.clear();

      // 追平期间进度/倍速是故意调偏的,不得播出去污染房间
      harness.now += timeupdateBroadcastMinIntervalMs + 100;
      harness.engine.onLocalPosition(harness.snapshot(position: 30.4));
      expect(harness.session.playbackUpdates, isEmpty);
    });

    test('remote buffering aligns position without pausing locally', () async {
      final harness = EngineHarness();
      await harness.loadSharedVideoAndHydrate();
      harness.engine.lastKnownPositionSeconds = 30;

      // 对端在缓冲:只对齐进度,绝不能把本地拉停
      final state = roomState(
        playback: playback(
          currentTime: 45,
          playState: PlaybackPlayState.buffering,
          seq: 5,
        ),
      );
      harness.session.roomState = state;
      await harness.engine.applyRoomState(state);

      expect(harness.port.calls, ['seekTo:45.0']);
      expect(harness.port.calls, isNot(contains('pause')));
    });

    test('defers remote pause, dropping it when superseded', () async {
      final harness = EngineHarness();
      await harness.loadSharedVideoAndHydrate();
      harness.engine.lastKnownPositionSeconds = 30;

      // 缓冲抖动产生的瞬时 paused(非用户主动):不得立即施加
      final paused = roomState(
        playback: playback(
          currentTime: 30,
          playState: PlaybackPlayState.paused,
          seq: 5,
        ),
      );
      harness.session.roomState = paused;
      await harness.engine.applyRoomState(paused);
      expect(harness.port.calls, isEmpty);
      expect(harness.deferred, hasLength(1));

      // 250ms 内对端恢复播放:待施加的暂停整个作废
      final resumed = roomState(
        playback: playback(
          currentTime: 30.2,
          playState: PlaybackPlayState.playing,
          seq: 6,
        ),
      );
      harness.session.roomState = resumed;
      await harness.engine.applyRoomState(resumed);
      expect(harness.port.calls, ['play']);

      expect(await harness.fireDeferred(), 0);
      expect(harness.port.calls, isNot(contains('pause')));
    });

    test('applies a deferred remote pause when nothing supersedes', () async {
      final harness = EngineHarness();
      await harness.loadSharedVideoAndHydrate();
      harness.engine.lastKnownPositionSeconds = 30;

      final paused = roomState(
        playback: playback(
          currentTime: 30,
          playState: PlaybackPlayState.paused,
          seq: 5,
        ),
      );
      harness.session.roomState = paused;
      await harness.engine.applyRoomState(paused);
      expect(harness.port.calls, isEmpty);

      expect(await harness.fireDeferred(), 1);
      expect(harness.port.calls, contains('pause'));
    });

    test('applies a user-initiated remote pause immediately', () async {
      final harness = EngineHarness();
      await harness.loadSharedVideoAndHydrate();
      harness.engine.lastKnownPositionSeconds = 30;

      // 用户主动暂停走快速通道,不吃 250ms 可见延迟
      final paused = roomState(
        playback: playback(
          currentTime: 30,
          playState: PlaybackPlayState.paused,
          seq: 5,
          userInitiated: true,
        ),
      );
      harness.session.roomState = paused;
      await harness.engine.applyRoomState(paused);

      expect(harness.port.calls, contains('pause'));
      expect(harness.deferred, isEmpty);
    });

    test('broadcasts buffering as a stop-like state', () async {
      final harness = EngineHarness();
      await harness.loadSharedVideoAndHydrate();
      harness.now += programmaticApplyWindowMs + 100;

      harness.engine.onLocalPlayStateChanged(
        LocalPlaybackEventSource.waiting,
        harness.snapshot(playState: PlaybackPlayState.buffering),
      );
      expect(harness.session.playbackUpdates, hasLength(1));
      expect(
        harness.session.playbackUpdates.single.playState,
        PlaybackPlayState.buffering,
      );
      // 缓冲不是用户操作,不得带显式控制意图
      expect(harness.session.playbackUpdates.single.syncIntent, isNull);
      expect(harness.session.playbackUpdates.single.userInitiated, isNull);
    });

    test('suppresses buffering caused by applying remote playback', () async {
      final harness = EngineHarness();
      harness.engine.onVideoLoaded(bvid: 'BV1xx411c7mD', cid: 42);
      harness.engine.lastKnownPositionSeconds = 10;
      harness.engine.lastKnownRate = 1;
      final state = roomState(playback: playback(currentTime: 30));
      harness.session.roomState = state;
      await harness.engine.applyRoomState(state);
      harness.session.playbackUpdates.clear();

      // 施加引起的缓冲:位置还停在 10,广播出去会把房间按旧位置打成暂停
      harness.now += programmaticApplyWindowMs + 100;
      harness.engine.onLocalPlayStateChanged(
        LocalPlaybackEventSource.waiting,
        harness.snapshot(position: 10, playState: PlaybackPlayState.buffering),
      );
      expect(harness.session.playbackUpdates, isEmpty);
    });

    test('does not heartbeat stale positions while applying', () async {
      final harness = EngineHarness();
      harness.engine.onVideoLoaded(bvid: 'BV1xx411c7mD', cid: 42);
      harness.engine.lastKnownPositionSeconds = 10;
      harness.engine.lastKnownRate = 1;
      final state = roomState(playback: playback(currentTime: 200));
      harness.session.roomState = state;
      await harness.engine.applyRoomState(state);
      harness.session.playbackUpdates.clear();

      // seek 未落地期间的位置心跳仍报旧位置,广播会被服务端当成新 seek
      harness.now += timeupdateBroadcastMinIntervalMs + 100;
      harness.engine.onLocalPosition(harness.snapshot(position: 10));
      expect(harness.session.playbackUpdates, isEmpty);

      // 到位后恢复心跳
      harness.engine.onLocalPosition(harness.snapshot(position: 200));
      harness.now += programmaticApplyWindowMs + timeupdateBroadcastMinIntervalMs;
      harness.engine.onLocalPosition(harness.snapshot(position: 202));
      expect(harness.session.playbackUpdates, hasLength(1));
      expect(harness.session.playbackUpdates.single.currentTime, 202);
    });

    test('programmatic seek settle window expires on timeout', () async {
      final harness = EngineHarness();
      harness.engine.onVideoLoaded(bvid: 'BV1xx411c7mD', cid: 42);
      harness.engine.lastKnownPositionSeconds = 10;
      harness.engine.lastKnownRate = 1;
      final state = roomState(playback: playback(currentTime: 30));
      harness.session.roomState = state;
      await harness.engine.applyRoomState(state);

      // seek 始终没落地(换源/失败):窗口不得无限挂着
      harness.now += programmaticSeekSettleTimeoutMs + 100;
      harness.engine.onLocalPosition(harness.snapshot(position: 10));
      expect(harness.engine.isInProgrammaticApplyWindow, isFalse);
    });

    test('user seek during settle wait is broadcast, not swallowed', () async {
      final harness = EngineHarness();
      harness.engine.onVideoLoaded(bvid: 'BV1xx411c7mD', cid: 42);
      harness.engine.lastKnownPositionSeconds = 10;
      harness.engine.lastKnownRate = 1;
      final state = roomState(playback: playback(currentTime: 30));
      harness.session.roomState = state;
      await harness.engine.applyRoomState(state);
      harness.session.playbackUpdates.clear();

      harness.now += programmaticApplyWindowMs + 100;
      // 目标位置附近的 seek 回流是施加回声
      harness.engine.onLocalSeek(harness.snapshot(position: 30));
      expect(harness.session.playbackUpdates, isEmpty);

      // 等待到位期间用户又拖了进度条:明显偏离目标,按用户意图广播
      harness.engine.onLocalSeek(harness.snapshot(position: 120));
      expect(harness.session.playbackUpdates, hasLength(1));
      expect(harness.session.playbackUpdates.single.currentTime, 120);
      expect(
        harness.session.playbackUpdates.single.syncIntent,
        PlaybackSyncIntent.explicitSeek,
      );
    });

    test(
      'navigates to a different shared video with position and pause',
      () async {
        final harness = EngineHarness();
        harness.engine.onVideoLoaded(bvid: 'BV1ab411c7mD');
        final state = roomState(
          playback: playback(
            currentTime: 61.5,
            playState: PlaybackPlayState.paused,
          ),
        );
        harness.session.roomState = state;

        await harness.engine.applyRoomState(state);
        expect(harness.port.calls, ['openVideo:$sharedUrl:61.5:paused=true']);
        expect(harness.engine.pendingRoomStateHydration, isTrue);
      },
    );

    test('drops small drift, seeks large drift', () async {
      final harness = EngineHarness();
      await harness.loadSharedVideoAndHydrate();

      harness.engine.lastKnownPositionSeconds = 30.3;
      final smallDrift = roomState(
        playback: playback(currentTime: 30.0, serverTime: 2000, seq: 2),
      );
      harness.session.roomState = smallDrift;
      await harness.engine.applyRoomState(smallDrift);
      expect(harness.port.calls, ['play']); // 无 seek

      harness.port.calls.clear();
      final largeDrift = roomState(
        playback: playback(currentTime: 35, serverTime: 3000, seq: 3),
      );
      harness.session.roomState = largeDrift;
      await harness.engine.applyRoomState(largeDrift);
      expect(harness.port.calls, ['seekTo:35.0', 'play']);
    });

    test(
      'timeupdate heartbeat throttles to one per 2s while playing',
      () async {
        final harness = EngineHarness();
        await harness.loadSharedVideoAndHydrate();
        harness.now += programmaticApplyWindowMs + 100;

        harness.engine.onLocalPosition(harness.snapshot(position: 31));
        expect(harness.session.playbackUpdates, hasLength(1));

        harness.now += 500;
        harness.engine.onLocalPosition(harness.snapshot(position: 31.5));
        expect(harness.session.playbackUpdates, hasLength(1));

        harness.now += 2000;
        harness.engine.onLocalPosition(harness.snapshot(position: 33.5));
        expect(harness.session.playbackUpdates, hasLength(2));

        // 暂停状态不发 timeupdate 心跳
        harness.now += 3000;
        harness.engine.onLocalPosition(
          harness.snapshot(playState: PlaybackPlayState.paused),
        );
        expect(harness.session.playbackUpdates, hasLength(2));
      },
    );

    test('user seek broadcasts explicit-seek intent', () async {
      final harness = EngineHarness();
      await harness.loadSharedVideoAndHydrate();
      harness.now += programmaticApplyWindowMs + 100;

      harness.engine.onLocalSeek(harness.snapshot(position: 90));
      expect(harness.session.playbackUpdates, hasLength(1));
      final update = harness.session.playbackUpdates.single;
      expect(update.syncIntent, PlaybackSyncIntent.explicitSeek);
      expect(update.currentTime, 90);
      expect(update.actorId, 'member-1');
    });

    test('hydration gate blocks broadcasts without a recent gesture', () async {
      final harness = EngineHarness();
      harness.session.roomState = roomState(playback: playback());
      harness.engine.onVideoLoaded(bvid: 'BV1xx411c7mD', cid: 42);
      expect(harness.engine.pendingRoomStateHydration, isTrue);

      harness.engine.onLocalPlayStateChanged(
        LocalPlaybackEventSource.playing,
        harness.snapshot(),
      );
      expect(harness.session.playbackUpdates, isEmpty);

      // 用户手势豁免 hydration 门
      harness.engine.onUserGesture(ExplicitUserActionKind.play);
      harness.engine.onLocalPlayStateChanged(
        LocalPlaybackEventSource.playing,
        harness.snapshot(),
      );
      expect(harness.session.playbackUpdates, hasLength(1));
    });

    test('force-pauses autoplaying non-shared video in room', () async {
      final harness = EngineHarness();
      await harness.loadSharedVideoAndHydrate();
      harness.now += programmaticApplyWindowMs + 100;

      // 切到非共享视频,自动开播(无用户手势)
      harness.engine.onVideoLoaded(bvid: 'BV1ab411c7mD');
      harness.engine.pendingRoomStateHydration = false;
      harness.engine.onLocalPlayStateChanged(
        LocalPlaybackEventSource.playing,
        harness.snapshot(),
      );
      expect(harness.port.calls, ['pause']);
      expect(harness.session.playbackUpdates, isEmpty);

      // 用户明确点播该视频:授权本地播放,不再强制暂停,也不广播
      harness.port.calls.clear();
      harness.now += userGestureGraceMs + 100;
      harness.engine.onUserGesture(ExplicitUserActionKind.play);
      harness.engine.onLocalPlayStateChanged(
        LocalPlaybackEventSource.playing,
        harness.snapshot(),
      );
      expect(harness.port.calls, isEmpty);
      expect(harness.session.playbackUpdates, isEmpty);
      expect(
        harness.engine.explicitNonSharedPlaybackUrl,
        'https://www.bilibili.com/video/BV1ab411c7mD',
      );
    });

    /// 本人是共享者的房间状态(自动分享的前置条件之一)。
    void makeLocalUserTheSharer(EngineHarness harness) {
      harness.session.roomState = roomState(
        sharedVideo: const SharedVideo(
          videoId: 'BV1xx411c7mD:42',
          url: sharedUrl,
          title: 'Video',
          sharedByMemberId: 'member-1',
        ),
        playback: playback(),
      );
    }

    test('auto-shares the next video after the shared one plays out', () async {
      final harness = EngineHarness();
      await harness.loadSharedVideoAndHydrate();
      makeLocalUserTheSharer(harness);

      // 共享视频自然播完 → 连播加载下一个
      harness.engine.onLocalEnded(
        harness.snapshot(playState: PlaybackPlayState.paused),
      );
      harness.engine.onVideoLoaded(bvid: 'BV1ab411c7mD', title: 'Next');
      expect(harness.session.sharedVideos, hasLength(1));
      expect(harness.session.sharedVideos.single.url, otherUrl);
      expect(harness.session.sharedVideos.single.title, 'Next');
    });

    test('does not auto-share a manually opened video', () async {
      // 回归:用户手动切视频被当成连播自动共享给房间
      final harness = EngineHarness();
      await harness.loadSharedVideoAndHydrate();
      makeLocalUserTheSharer(harness);

      harness.engine.onVideoLoaded(bvid: 'BV1ab411c7mD', title: 'Next');
      expect(harness.session.sharedVideos, isEmpty);
    });

    test('does not auto-share after leaving the video page', () async {
      // 回归(用户报告):退出当前视频再打开新视频被自动共享。
      // 连播是同播放器实例内换源,播放器销毁即证明是手动选片。
      final harness = EngineHarness();
      await harness.loadSharedVideoAndHydrate();
      makeLocalUserTheSharer(harness);

      harness.engine.onLocalEnded(
        harness.snapshot(playState: PlaybackPlayState.paused),
      );
      harness.engine.onPlayerDetached();
      harness.engine.onVideoLoaded(bvid: 'BV1ab411c7mD', title: 'Next');
      expect(harness.session.sharedVideos, isEmpty);
    });

    test('does not auto-share beyond the continuation window', () async {
      final harness = EngineHarness();
      await harness.loadSharedVideoAndHydrate();
      makeLocalUserTheSharer(harness);

      harness.engine.onLocalEnded(
        harness.snapshot(playState: PlaybackPlayState.paused),
      );
      harness.now += autoplayContinuationWindowMs + 1;
      harness.engine.onVideoLoaded(bvid: 'BV1ab411c7mD', title: 'Next');
      expect(harness.session.sharedVideos, isEmpty);
    });

    test('does not auto-share when the user acts after the end', () async {
      // 播完后又操作播放器 = 手动选片
      final harness = EngineHarness();
      await harness.loadSharedVideoAndHydrate();
      makeLocalUserTheSharer(harness);

      harness.engine.onLocalEnded(
        harness.snapshot(playState: PlaybackPlayState.paused),
      );
      harness.now += 100;
      harness.engine.onUserGesture(ExplicitUserActionKind.play);
      harness.engine.onVideoLoaded(bvid: 'BV1ab411c7mD', title: 'Next');
      expect(harness.session.sharedVideos, isEmpty);
    });

    test('defers auto-share until the title resolves', () async {
      // 标题随详情接口异步到达,早于它分享会把 videoId 当标题发出去
      final harness = EngineHarness();
      await harness.loadSharedVideoAndHydrate();
      makeLocalUserTheSharer(harness);

      harness.engine.onLocalEnded(
        harness.snapshot(playState: PlaybackPlayState.paused),
      );
      harness.engine.onVideoLoaded(bvid: 'BV1ab411c7mD');
      expect(harness.session.sharedVideos, isEmpty);

      harness.engine.onTitleResolved('Next');
      expect(harness.session.sharedVideos, hasLength(1));
      expect(harness.session.sharedVideos.single.title, 'Next');
    });

    test('a resolved title alone never triggers a share', () async {
      final harness = EngineHarness();
      await harness.loadSharedVideoAndHydrate();
      makeLocalUserTheSharer(harness);

      harness.engine.onVideoLoaded(bvid: 'BV1ab411c7mD');
      harness.engine.onTitleResolved('Next');
      expect(harness.session.sharedVideos, isEmpty);
      expect(harness.engine.currentTitle, 'Next');
    });

    test('defers auto-share while awaiting fresh room state', () async {
      final harness = EngineHarness();
      await harness.loadSharedVideoAndHydrate();
      makeLocalUserTheSharer(harness);
      harness.engine.onLocalEnded(
        harness.snapshot(playState: PlaybackPlayState.paused),
      );
      harness.session.awaitingFreshRoomState = true;
      harness.engine.onVideoLoaded(bvid: 'BV1ab411c7mD', title: 'Next');
      expect(harness.session.sharedVideos, isEmpty);
    });

    test('does not auto-share when someone else is the sharer', () async {
      final harness = EngineHarness();
      await harness.loadSharedVideoAndHydrate();
      harness.engine.onVideoLoaded(bvid: 'BV1ab411c7mD', title: 'Next');
      expect(harness.session.sharedVideos, isEmpty);
    });

    test(
      'self playback echo advances version without touching the player',
      () async {
        final harness = EngineHarness();
        await harness.loadSharedVideoAndHydrate();
        harness.now += programmaticApplyWindowMs + 100;

        harness.engine.onLocalSeek(harness.snapshot(position: 90));
        final localSeq = harness.session.playbackUpdates.single.seq;

        // 服务器回流自己的状态(seq 相同):不施加
        final echo = roomState(
          playback: playback(
            actorId: 'member-1',
            seq: localSeq,
            serverTime: 5000,
            currentTime: 90,
          ),
        );
        harness.session.roomState = echo;
        await harness.engine.applyRoomState(echo);
        expect(harness.port.calls, isEmpty);
      },
    );

    test('videoIdsMayReferToSameVideo tolerates unknown cid/page', () {
      expect(
        videoIdsMayReferToSameVideo('BV1xx411c7mD:42', 'BV1xx411c7mD'),
        isTrue,
      );
      expect(
        videoIdsMayReferToSameVideo('BV1xx411c7mD:42', 'BV1xx411c7mD:p2'),
        isTrue, // cid 与分P无法互证不同
      );
      expect(
        videoIdsMayReferToSameVideo('BV1xx411c7mD:42', 'BV1xx411c7mD:43'),
        isFalse,
      );
      expect(
        videoIdsMayReferToSameVideo('BV1xx411c7mD:p2', 'BV1xx411c7mD:p3'),
        isFalse,
      );
      expect(
        videoIdsMayReferToSameVideo('BV1xx411c7mD', 'BV1ab411c7mD'),
        isFalse,
      );
    });

    test('repeated room states trigger navigation only once', () async {
      // 回归:每条 room:state 都 push 视频页导致页面堆叠卡死
      final harness = EngineHarness();
      harness.engine.onVideoLoaded(bvid: 'BV1ab411c7mD');
      final state = roomState(playback: playback());
      harness.session.roomState = state;

      await harness.engine.applyRoomState(state);
      await harness.engine.applyRoomState(state);
      await harness.engine.applyRoomState(state);
      expect(
        harness.port.calls.where((call) => call.startsWith('openVideo')),
        hasLength(1),
      );
    });

    test('adopts the shared identity when the target video loads', () async {
      // 回归:共享 URL 不带 cid、本地身份带 cid,严格比对导致反复导航
      final harness = EngineHarness();
      final shared = RoomState(
        roomCode: 'ABC123',
        sharedVideo: const SharedVideo(
          videoId: 'BV1xx411c7mD',
          url: 'https://www.bilibili.com/video/BV1xx411c7mD',
          title: 'Video',
          sharedByMemberId: 'member-2',
        ),
        playback: playback(
          url: 'https://www.bilibili.com/video/BV1xx411c7mD',
          currentTime: 30,
        ),
        members: const [RoomMember(id: 'member-1', name: 'Alice')],
      );
      harness.session.roomState = shared;
      await harness.engine.applyRoomState(shared);
      expect(harness.port.calls.single, startsWith('openVideo'));
      harness.port.calls.clear();

      // 目标页加载:本地以 bvid+cid 构造,身份应采纳为房间形态
      harness.engine.onVideoLoaded(bvid: 'BV1xx411c7mD', cid: 42);
      expect(harness.engine.currentVideo!.videoId, 'BV1xx411c7mD');
      expect(
        harness.engine.currentVideo!.normalizedUrl,
        'https://www.bilibili.com/video/BV1xx411c7mD',
      );

      // 再来 room:state:不再导航,正常施加播放状态
      harness.engine.lastKnownPositionSeconds = 0;
      harness.engine.lastKnownRate = 1;
      await harness.engine.applyRoomState(shared);
      expect(harness.port.calls, ['seekTo:30.0', 'play']);

      // 广播使用房间的共享 URL(其他端才认得)
      harness.now += programmaticApplyWindowMs + 100;
      harness.engine.onLocalSeek(harness.snapshot(position: 50));
      expect(
        harness.session.playbackUpdates.single.url,
        'https://www.bilibili.com/video/BV1xx411c7mD',
      );
    });

    test('adopts identity late when video loaded before joining', () async {
      final harness = EngineHarness();
      // 先加载视频(未进房时无共享状态可采纳)
      harness.engine.onVideoLoaded(bvid: 'BV1xx411c7mD', cid: 42);
      expect(harness.engine.currentVideo!.videoId, 'BV1xx411c7mD:42');

      // 进房后收到同一视频的共享(无 cid 形态):补采纳,不导航
      final shared = RoomState(
        roomCode: 'ABC123',
        sharedVideo: const SharedVideo(
          videoId: 'BV1xx411c7mD',
          url: 'https://www.bilibili.com/video/BV1xx411c7mD',
          title: 'Video',
        ),
        playback: playback(
          url: 'https://www.bilibili.com/video/BV1xx411c7mD',
          currentTime: 30,
        ),
        members: const [RoomMember(id: 'member-1', name: 'Alice')],
      );
      harness.session.roomState = shared;
      harness.engine.lastKnownPositionSeconds = 0;
      harness.engine.lastKnownRate = 1;
      await harness.engine.applyRoomState(shared);
      expect(harness.engine.currentVideo!.videoId, 'BV1xx411c7mD');
      expect(harness.port.calls, ['seekTo:30.0', 'play']);
    });

    test('resetRoomLocalState allows navigating again after rejoin', () async {
      final harness = EngineHarness();
      harness.engine.onVideoLoaded(bvid: 'BV1ab411c7mD');
      final state = roomState(playback: playback());
      harness.session.roomState = state;
      await harness.engine.applyRoomState(state);
      harness.engine.resetRoomLocalState();
      await harness.engine.applyRoomState(state);
      expect(
        harness.port.calls.where((call) => call.startsWith('openVideo')),
        hasLength(2),
      );
    });

    test(
      'manual shareCurrentVideo sends video with playback snapshot',
      () async {
        final harness = EngineHarness();
        harness.engine.onVideoLoaded(bvid: 'BV1xx411c7mD', cid: 42, title: 'V');
        harness.engine.shareCurrentVideo(snapshot: harness.snapshot());
        expect(harness.session.sharedVideos, hasLength(1));
        expect(harness.session.sharedVideos.single.videoId, 'BV1xx411c7mD:42');
      },
    );
  });

  group('PlayerSyncEngine (bangumi)', () {
    const epUrl = 'https://www.bilibili.com/bangumi/play/ep123456';
    const ssUrl = 'https://www.bilibili.com/bangumi/play/ss26257';

    RoomState pgcRoomState({String videoId = 'ep123456', String url = epUrl}) =>
        RoomState(
          roomCode: 'ABC123',
          sharedVideo: SharedVideo(
            videoId: videoId,
            url: url,
            title: 'Bangumi',
            sharedByMemberId: 'member-2',
          ),
          playback: playback(url: url, currentTime: 30),
          members: const [RoomMember(id: 'member-1', name: 'Alice')],
        );

    test('shares a loaded episode with ep identity', () {
      final harness = EngineHarness();
      harness.engine.onVideoLoaded(epId: 123456, seasonId: 26257, title: 'B');
      expect(harness.engine.currentVideo!.videoId, 'ep123456');
      expect(harness.engine.currentVideo!.normalizedUrl, epUrl);
      harness.engine.shareCurrentVideo(snapshot: harness.snapshot());
      expect(harness.session.sharedVideos.single.videoId, 'ep123456');
    });

    test('navigates to a shared episode and aligns on load', () async {
      final harness = EngineHarness();
      harness.engine.onVideoLoaded(bvid: 'BV1ab411c7mD');
      final state = pgcRoomState();
      harness.session.roomState = state;
      await harness.engine.applyRoomState(state);
      expect(harness.port.calls.single, startsWith('openVideo:$epUrl'));
      harness.port.calls.clear();

      // 目标番剧页加载:ep 身份逐字对齐,不再导航,正常施加
      harness.engine.onVideoLoaded(epId: 123456, seasonId: 26257);
      harness.engine.lastKnownPositionSeconds = 0;
      harness.engine.lastKnownRate = 1;
      await harness.engine.applyRoomState(state);
      expect(harness.port.calls, ['seekTo:30.0', 'play']);
    });

    test('adopts ss identity when the local season matches', () async {
      // 浏览器扩展在番剧季页(ss URL)分享:身份不含集数,导航后
      // App 打开具体某集(ep 形态),按 seasonId 采纳房间身份
      final harness = EngineHarness();
      final state = pgcRoomState(videoId: 'ss26257', url: ssUrl);
      harness.session.roomState = state;
      harness.engine.onVideoLoaded(epId: 123456, seasonId: 26257);
      expect(harness.engine.currentVideo!.videoId, 'ss26257');
      expect(harness.engine.currentVideo!.normalizedUrl, ssUrl);

      harness.engine.lastKnownPositionSeconds = 0;
      harness.engine.lastKnownRate = 1;
      await harness.engine.applyRoomState(state);
      expect(harness.port.calls, ['seekTo:30.0', 'play']);
    });

    test('does not adopt ss identity for a different season', () async {
      final harness = EngineHarness();
      final state = pgcRoomState(videoId: 'ss26257', url: ssUrl);
      harness.session.roomState = state;
      harness.engine.onVideoLoaded(epId: 999, seasonId: 11111);
      expect(harness.engine.currentVideo!.videoId, 'ep999');

      await harness.engine.applyRoomState(state);
      expect(harness.port.calls.single, startsWith('openVideo:$ssUrl'));
    });

    test('clears season context when a normal video loads', () {
      final harness = EngineHarness();
      harness.engine.onVideoLoaded(epId: 123456, seasonId: 26257);
      expect(harness.engine.currentSeasonId, 26257);
      harness.engine.onVideoLoaded(bvid: 'BV1xx411c7mD', cid: 42);
      expect(harness.engine.currentSeasonId, isNull);
    });
  });

  group('PlayerSyncEngine (player detach)', () {
    test(
      'stale identity no longer swallows a re-shared video after detach',
      () async {
        // 回归:离开视频页后 currentVideo 过期,共享同 bvid 视频时被采纳
        // 判定吸收,既不导航也无播放器可施加
        final harness = EngineHarness();
        harness.engine.onVideoLoaded(bvid: 'BV1xx411c7mD', cid: 42);
        harness.engine.onPlayerDetached();
        expect(harness.engine.currentVideo, isNull);

        final state = roomState(playback: playback());
        harness.session.roomState = state;
        await harness.engine.applyRoomState(state);
        expect(harness.port.calls.single, startsWith('openVideo:$sharedUrl'));
      },
    );

    test('same shared URL does not re-open after leaving its page', () async {
      // 对齐扩展端 tab-controller:用户主动离开共享视频不被拉回,
      // 共享 URL 变化才重新导航
      final harness = EngineHarness();
      harness.engine.onVideoLoaded(bvid: 'BV1ab411c7mD');
      final state = roomState(playback: playback());
      harness.session.roomState = state;
      await harness.engine.applyRoomState(state);
      expect(harness.port.calls.single, startsWith('openVideo:$sharedUrl'));
      harness.port.calls.clear();

      // 跟随到达共享视频页,随后离开
      harness.engine.onVideoLoaded(bvid: 'BV1xx411c7mD', cid: 42);
      harness.engine.onPlayerDetached();

      await harness.engine.applyRoomState(state);
      expect(harness.port.calls, isEmpty);

      // 共享切到新视频:重新导航
      const nextUrl = 'https://www.bilibili.com/video/BV1cd411c7mD';
      final next = RoomState(
        roomCode: 'ABC123',
        sharedVideo: const SharedVideo(
          videoId: 'BV1cd411c7mD',
          url: nextUrl,
          title: 'Next',
          sharedByMemberId: 'member-2',
        ),
        playback: playback(url: nextUrl, serverTime: 2000, seq: 2),
        members: const [RoomMember(id: 'member-1', name: 'Alice')],
      );
      harness.session.roomState = next;
      await harness.engine.applyRoomState(next);
      expect(harness.port.calls.single, startsWith('openVideo:$nextUrl'));
    });

    test('openSharedVideoManually bypasses the navigation guard', () async {
      final harness = EngineHarness();
      final state = roomState(playback: playback());
      harness.session.roomState = state;
      await harness.engine.applyRoomState(state);
      harness.engine.onVideoLoaded(bvid: 'BV1xx411c7mD', cid: 42);
      harness.engine.onPlayerDetached();
      harness.port.calls.clear();

      await harness.engine.openSharedVideoManually();
      expect(harness.port.calls.single, startsWith('openVideo:$sharedUrl'));

      // 已在共享视频页时不重复导航
      harness.engine.onVideoLoaded(bvid: 'BV1xx411c7mD', cid: 42);
      harness.port.calls.clear();
      await harness.engine.openSharedVideoManually();
      expect(harness.port.calls, isEmpty);
    });
  });
}
