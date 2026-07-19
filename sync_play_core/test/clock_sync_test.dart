/// 对时纯函数测试,数值断言与 extension/src/background/clock-sync.ts 的
/// 实现语义逐项对照(含 JS Math.round 的负半数取整行为)。
library;

import 'package:sync_play_core/sync_play_core.dart';
import 'package:test/test.dart';

PlaybackState _playback({
  required PlaybackPlayState playState,
  double currentTime = 10,
  double playbackRate = 1,
  num serverTime = 1000,
}) => PlaybackState(
  url: 'https://www.bilibili.com/video/BV1xx411c7mD',
  currentTime: currentTime,
  playState: playState,
  playbackRate: playbackRate,
  updatedAt: 1,
  serverTime: serverTime,
  actorId: 'member-1',
  seq: 1,
);

RoomState _roomState(PlaybackState? playback) => RoomState(
  roomCode: 'ABC123',
  sharedVideo: null,
  playback: playback,
  members: const [RoomMember(id: 'member-1', name: 'Alice')],
);

void main() {
  test('first clock sample is taken as-is', () {
    final sample = updateClockSample(
      clientSendTime: 1000,
      serverReceiveTime: 1600,
      serverSendTime: 1650,
      now: 2000,
    );
    // rtt = 2000 - 1000 - (1650 - 1600) = 950
    expect(sample.rttMs, 950);
    // offset = ((1600 - 1000) + (1650 - 2000)) / 2 = 125
    expect(sample.clockOffsetMs, 125);
  });

  test('subsequent samples apply the 0.7/0.3 EWMA and round', () {
    final sample = updateClockSample(
      clientSendTime: 900,
      serverReceiveTime: 950,
      serverSendTime: 960,
      now: 1000,
      previousRttMs: 100,
      previousClockOffsetMs: -10,
    );
    // sampleRtt = 1000 - 900 - 10 = 90 → 100*0.7 + 90*0.3 = 97
    expect(sample.rttMs, 97);
    // sampleOffset = (50 + (960 - 1000)) / 2 = 5 → -10*0.7 + 5*0.3 = -5.5
    // JS Math.round(-5.5) = -5(Dart round() 是 -6,实现里已对齐 JS)
    expect(sample.clockOffsetMs, -5);
  });

  test('compensates playing room state by elapsed server time', () {
    final state = _roomState(
      _playback(
        playState: PlaybackPlayState.playing,
        currentTime: 10,
        playbackRate: 2,
        serverTime: 1000,
      ),
    );
    final compensated = compensateRoomStateForClock(state, 100, now: 2000);
    // estimatedServerNow = 2100, elapsed = 1100ms → 10 + 1.1*2 = 12.2
    expect(compensated.playback!.currentTime, closeTo(12.2, 1e-9));
    // 其余字段不变
    expect(compensated.roomCode, state.roomCode);
    expect(compensated.playback!.playState, PlaybackPlayState.playing);
  });

  test('clamps negative elapsed time to zero', () {
    final state = _roomState(
      _playback(playState: PlaybackPlayState.playing, serverTime: 99999),
    );
    final compensated = compensateRoomStateForClock(state, 0, now: 2000);
    expect(compensated.playback!.currentTime, 10);
  });

  test('returns state unchanged when paused, or without offset/playback', () {
    final paused = _roomState(_playback(playState: PlaybackPlayState.paused));
    expect(
      identical(compensateRoomStateForClock(paused, 100, now: 0), paused),
      isTrue,
    );

    final playing = _roomState(_playback(playState: PlaybackPlayState.playing));
    expect(
      identical(compensateRoomStateForClock(playing, null, now: 0), playing),
      isTrue,
    );

    final empty = _roomState(null);
    expect(
      identical(compensateRoomStateForClock(empty, 100, now: 0), empty),
      isTrue,
    );
  });

  test('converts websocket URLs to healthcheck/connection-check URLs', () {
    expect(
      toHealthcheckUrl('wss://sync.example.com/ws?room=1#x'),
      'https://sync.example.com/',
    );
    expect(
      toHealthcheckUrl('ws://localhost:8787/ws'),
      'http://localhost:8787/',
    );
    expect(
      toConnectionCheckUrl('wss://sync.example.com:8443/ws'),
      'https://sync.example.com:8443/api/connection-check',
    );
    expect(toHealthcheckUrl('https://sync.example.com/'), isNull);
    expect(toConnectionCheckUrl('not-a-url'), isNull);
  });
}
