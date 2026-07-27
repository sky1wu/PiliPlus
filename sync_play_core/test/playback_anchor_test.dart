/// 播放快照锚点测试,与 extension/test/clock-controller.test.ts 的锚点用例对齐
/// (该文件里 ping 定时器/诊断偏移的用例在本移植里属 session/clock_sync)。
library;

import 'package:sync_play_core/sync_play_core.dart';
import 'package:test/test.dart';

RoomState _roomState({
  required int seq,
  required double currentTime,
  required num serverTime,
  PlaybackPlayState playState = PlaybackPlayState.playing,
  double playbackRate = 1,
  String actorId = 'actor',
}) => RoomState(
  roomCode: 'ABC123',
  sharedVideo: null,
  playback: PlaybackState(
    url: 'https://www.bilibili.com/video/BV1xx411c7mD',
    currentTime: currentTime,
    playState: playState,
    playbackRate: playbackRate,
    updatedAt: serverTime,
    serverTime: serverTime,
    actorId: actorId,
    seq: seq,
  ),
  members: const [],
);

({PlaybackAnchorTracker tracker, void Function(double) setNow}) _harness() {
  var now = 0.0;
  final tracker = PlaybackAnchorTracker(() => now);
  return (tracker: tracker, setNow: (double value) => now = value);
}

void main() {
  test('a freshly arrived snapshot is passed through as reported', () {
    final h = _harness();
    final state = _roomState(seq: 1, currentTime: 42, serverTime: 1000);
    expect(h.tracker.compensateRoomState(state).playback!.currentTime, 42);
  });

  test(
    'replaying the same snapshot advances it by the time since it arrived',
    () {
      final h = _harness();
      final state = _roomState(seq: 1, currentTime: 42, serverTime: 1000);
      h.tracker.compensateRoomState(state);

      h.setNow(2000);
      expect(
        h.tracker.compensateRoomState(state).playback!.currentTime,
        closeTo(44, 1e-9),
      );
    },
  );

  test('anchors on the supplied arrival stamp, not on the call', () {
    final h = _harness();
    final state = _roomState(seq: 1, currentTime: 42, serverTime: 1000);

    h.setNow(3000);
    // 到达发生在 1000,处理到这一行已是 3000:那 2s 房间照样在播。
    expect(
      h.tracker
          .compensateRoomState(state, anchorAtMs: 1000)
          .playback!
          .currentTime,
      closeTo(44, 1e-9),
    );
  });

  test('keeps extrapolating from the arrival stamp on later replays', () {
    final h = _harness();
    final state = _roomState(seq: 1, currentTime: 42, serverTime: 1000);
    h.tracker.compensateRoomState(state, anchorAtMs: 1000);

    h.setNow(5000);
    expect(
      h.tracker.compensateRoomState(state).playback!.currentTime,
      closeTo(46, 1e-9),
    );
  });

  test('each new snapshot re-anchors instead of accumulating', () {
    final h = _harness();
    h.tracker.compensateRoomState(
      _roomState(seq: 1, currentTime: 42, serverTime: 1000),
    );

    h.setNow(10000);
    final next = _roomState(seq: 2, currentTime: 50, serverTime: 11000);
    expect(h.tracker.compensateRoomState(next).playback!.currentTime, 50);
  });

  test('scales the advance by the room playback rate', () {
    final h = _harness();
    final state = _roomState(
      seq: 1,
      currentTime: 42,
      serverTime: 1000,
      playbackRate: 2,
    );
    h.tracker.compensateRoomState(state, anchorAtMs: 0);

    h.setNow(1000);
    expect(
      h.tracker.compensateRoomState(state).playback!.currentTime,
      closeTo(44, 1e-9),
    );
  });

  test('paused snapshots are never extrapolated', () {
    final h = _harness();
    final paused = _roomState(
      seq: 1,
      currentTime: 42,
      serverTime: 1000,
      playState: PlaybackPlayState.paused,
    );
    h.tracker.compensateRoomState(paused, anchorAtMs: 0);

    h.setNow(60000);
    expect(h.tracker.compensateRoomState(paused).playback!.currentTime, 42);
  });

  test('a reused seq at a repeated position is still a new snapshot', () {
    // seq 每次播放器会话都从头开始,身份不能只靠它:重载后恰好停在早期 seq 快照
    // 报过的位置的成员,否则会命中见过的 key 并继承那个锚点。
    final h = _harness();
    h.tracker.compensateRoomState(
      _roomState(seq: 1, currentTime: 42, serverTime: 1000),
    );

    h.setNow(120000);
    final afterReload = h.tracker.compensateRoomState(
      _roomState(seq: 1, currentTime: 42, serverTime: 500000),
    );
    expect(afterReload.playback!.currentTime, 42);
  });

  test('a pause drops the anchor so nothing extrapolates across it', () {
    final h = _harness();
    final playing = _roomState(seq: 1, currentTime: 42, serverTime: 1000);
    h.tracker.compensateRoomState(playing);

    h.tracker.compensateRoomState(
      _roomState(
        seq: 2,
        currentTime: 42,
        serverTime: 2000,
        playState: PlaybackPlayState.paused,
      ),
    );
    h.setNow(120000);

    // 与暂停前同一份快照:不丢锚点的话,它会被推进整段暂停区间。
    expect(h.tracker.compensateRoomState(playing).playback!.currentTime, 42);
  });

  test('an explicit arrival corrects an anchor a reader established late', () {
    // 快照在它自己的处理走完之前就可被读到,于是某个读取方可能不带到达时刻先来
    // 一次,把锚点立在请求时刻。
    final h = _harness();
    final state = _roomState(seq: 1, currentTime: 42, serverTime: 1000);

    h.setNow(2500);
    h.tracker.compensateRoomState(state); // 读取方,锚在 2500
    h.setNow(3000);
    h.tracker.compensateRoomState(state, anchorAtMs: 1000); // 处理方:它 1000 到的

    h.setNow(4000);
    // 距真实到达 3s,而不是距首次被读 1.5s。
    expect(
      h.tracker.compensateRoomState(state).playback!.currentTime,
      closeTo(45, 1e-9),
    );
  });

  test('a later arrival stamp never pushes an anchor forward', () {
    final h = _harness();
    final state = _roomState(seq: 1, currentTime: 42, serverTime: 1000);
    h.tracker.compensateRoomState(state, anchorAtMs: 1000);

    h.setNow(3000);
    h.tracker.compensateRoomState(state, anchorAtMs: 2500);

    expect(
      h.tracker.compensateRoomState(state).playback!.currentTime,
      closeTo(44, 1e-9),
    );
  });

  test('an arrival marked at ingress survives a reader compensating first', () {
    // 成员增量与 UI 读取路径不带到达时刻;锚点已在入口记好,它们就不会重启它。
    final h = _harness();
    final state = _roomState(seq: 1, currentTime: 42, serverTime: 1000);

    h.tracker.markPlaybackArrival(state.playback, 1000);
    h.setNow(3000);

    expect(
      h.tracker.compensateRoomState(state).playback!.currentTime,
      closeTo(44, 1e-9),
    );
  });

  test('marking a non-playing arrival drops the anchor', () {
    final h = _harness();
    final playing = _roomState(seq: 1, currentTime: 42, serverTime: 1000);
    h.tracker.markPlaybackArrival(playing.playback, 1000);

    h.tracker.markPlaybackArrival(
      _roomState(
        seq: 2,
        currentTime: 42,
        serverTime: 2000,
        playState: PlaybackPlayState.paused,
      ).playback,
      2000,
    );
    h.setNow(120000);

    expect(h.tracker.compensateRoomState(playing).playback!.currentTime, 42);
  });

  test('a repeated arrival of one snapshot keeps the earliest', () {
    final h = _harness();
    final state = _roomState(seq: 1, currentTime: 42, serverTime: 1000);

    h.tracker.markPlaybackArrival(state.playback, 1000);
    h.tracker.markPlaybackArrival(state.playback, 2500);
    h.setNow(3000);

    expect(
      h.tracker.compensateRoomState(state).playback!.currentTime,
      closeTo(44, 1e-9),
    );
  });

  test('reset drops the anchor for the next room session', () {
    final h = _harness();
    final state = _roomState(seq: 1, currentTime: 42, serverTime: 1000);
    h.tracker.markPlaybackArrival(state.playback, 1000);

    h.tracker.reset();
    h.setNow(120000);
    expect(h.tracker.compensateRoomState(state).playback!.currentTime, 42);
  });
}
