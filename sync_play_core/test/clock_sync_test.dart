/// 对时纯函数测试,数值断言与 extension/src/background/clock-sync.ts 的
/// 实现语义逐项对照(含 JS Math.round 的负半数取整行为),
/// 用例与 extension/test/clock-sync.test.ts 对齐。
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

/// clock-sync.test.ts: pingRoundTrip——一次耗时 rttMs 的往返,服务端钟快
/// offsetMs,时延在两个方向上均分(估计器对这种情形是精确的)。
({num clientSendTime, num serverReceiveTime, num serverSendTime, num now})
_pingRoundTrip({
  required num clientSendTime,
  required num offsetMs,
  required num rttMs,
  num serverProcessingMs = 0,
}) {
  final oneWay = rttMs / 2;
  return (
    clientSendTime: clientSendTime,
    serverReceiveTime: clientSendTime + oneWay + offsetMs,
    serverSendTime: clientSendTime + oneWay + offsetMs + serverProcessingMs,
    now: clientSendTime + rttMs + serverProcessingMs,
  );
}

/// clock-sync.test.ts: runSamples——把一串样本喂进估计器并串起它的状态。
({double? clockOffsetMs, double? rttMs, List<ClockSample> window}) _runSamples(
  List<({num offsetMs, num rttMs, num atMs})> samples,
) {
  double? clockOffsetMs;
  double? rttMs;
  var window = const <ClockSample>[];

  for (final sample in samples) {
    final trip = _pingRoundTrip(
      clientSendTime: sample.atMs,
      offsetMs: sample.offsetMs,
      rttMs: sample.rttMs,
    );
    final result = updateClockSample(
      clientSendTime: trip.clientSendTime,
      serverReceiveTime: trip.serverReceiveTime,
      serverSendTime: trip.serverSendTime,
      now: trip.now,
      previousRttMs: rttMs,
      previousClockOffsetMs: clockOffsetMs,
      previousSamples: window,
    );
    clockOffsetMs = result.clockOffsetMs;
    rttMs = result.rttMs;
    window = result.samples;
  }

  return (clockOffsetMs: clockOffsetMs, rttMs: rttMs, window: window);
}

List<({num offsetMs, num rttMs, num atMs})> _steady({
  required int count,
  required num offsetMs,
  num rttMs = 10,
  int startIndex = 0,
}) => [
  for (var i = 0; i < count; i++)
    (offsetMs: offsetMs, rttMs: rttMs, atMs: 1000 + (startIndex + i) * 15000),
];

void main() {
  test('recovers the clock offset and round trip from a single sample', () {
    final trip = _pingRoundTrip(clientSendTime: 1000, offsetMs: 200, rttMs: 40);
    final result = updateClockSample(
      clientSendTime: trip.clientSendTime,
      serverReceiveTime: trip.serverReceiveTime,
      serverSendTime: trip.serverSendTime,
      now: trip.now,
    );

    expect(result.clockOffsetMs, 200);
    expect(result.rttMs, 40);
    expect(result.sample.offsetMs, 200);
    expect(result.samples.length, 1);
  });

  test('server processing time is excluded from the round trip', () {
    final trip = _pingRoundTrip(
      clientSendTime: 1000,
      offsetMs: 0,
      rttMs: 30,
      serverProcessingMs: 500,
    );
    final result = updateClockSample(
      clientSendTime: trip.clientSendTime,
      serverReceiveTime: trip.serverReceiveTime,
      serverSendTime: trip.serverSendTime,
      now: trip.now,
    );

    expect(result.rttMs, 30);
    expect(result.sample.offsetMs, 0);
  });

  test('subsequent round trips apply the 0.7/0.3 EWMA and round', () {
    final result = updateClockSample(
      clientSendTime: 900,
      serverReceiveTime: 950,
      serverSendTime: 960,
      now: 1000,
      previousRttMs: 100,
      previousClockOffsetMs: -10,
    );
    // sampleRtt = (950-900) - (960-1000) = 90 → 100*0.7 + 90*0.3 = 97
    expect(result.rttMs, 97);
  });

  test('an isolated wild sample does not move the published offset', () {
    final steady = _steady(count: 5, offsetMs: 200);
    expect(_runSamples(steady).clockOffsetMs, 200);

    final withOutlier = _runSamples([
      ...steady,
      (offsetMs: 900, rttMs: 10, atMs: 1000 + 5 * 15000),
    ]);
    expect(withOutlier.clockOffsetMs, 200);
  });

  test('alternating noise leaves the published offset still', () {
    // 实测的故障形态:往返时延平稳,样本却在几百毫秒间摆动。这些值过去会被直接
    // 混进 EWMA,并给每个外推目标重新计时。
    final noisy = [-200, 550, 120, 480, 210, 330, 150, 520, 190];
    final published = <double?>[];
    double? clockOffsetMs;
    var window = const <ClockSample>[];
    for (var i = 0; i < noisy.length; i++) {
      final trip = _pingRoundTrip(
        clientSendTime: 1000 + i * 15000,
        offsetMs: noisy[i],
        rttMs: 10,
      );
      final result = updateClockSample(
        clientSendTime: trip.clientSendTime,
        serverReceiveTime: trip.serverReceiveTime,
        serverSendTime: trip.serverSendTime,
        now: trip.now,
        previousClockOffsetMs: clockOffsetMs,
        previousSamples: window,
      );
      clockOffsetMs = result.clockOffsetMs;
      window = result.samples;
      published.add(clockOffsetMs);
    }

    // 窗口一旦有多数可依,已发布的偏移就不再动:对称散布的中位数不会从落点走出
    // 一整个死区,于是外推目标始终按 1x 前进。
    final settled = published.sublist(clockSampleMinTrustedSize);
    expect(settled.length, greaterThanOrEqualTo(5));
    expect(settled.toSet(), {settled.first}, reason: 'published=$published');
  });

  test('follows a sustained offset change once the window turns over', () {
    final base = _steady(count: clockSampleWindowSize, offsetMs: 100);
    expect(_runSamples(base).clockOffsetMs, 100);

    final shifted = _runSamples([
      ...base,
      ..._steady(
        count: clockSampleWindowSize,
        offsetMs: 900,
        startIndex: clockSampleWindowSize,
      ),
    ]);
    expect(shifted.clockOffsetMs, 900);
  });

  test('a slow round trip loses to the faster samples in the window', () {
    final result = _runSamples([
      (offsetMs: 100, rttMs: 8, atMs: 1000),
      (offsetMs: 100, rttMs: 8, atMs: 16000),
      // 不对称时延:600ms 的往返最多能把样本拉偏 300ms。
      (offsetMs: 400, rttMs: 600, atMs: 31000),
    ]);

    expect(result.clockOffsetMs, 100);
  });

  test('an impossible round trip cannot disqualify the honest samples', () {
    final settled = _runSamples(_steady(count: 3, offsetMs: 100));
    expect(settled.clockOffsetMs, 100);

    // 服务端报告的处理耗时(800ms)超过客户端量到的整个往返(0ms),推出的往返
    // 时延为负。
    final withImpossible = updateClockSample(
      clientSendTime: 46000,
      serverReceiveTime: 46100,
      serverSendTime: 46900,
      now: 46000,
      previousRttMs: 10,
      previousClockOffsetMs: settled.clockOffsetMs,
      previousSamples: settled.window,
    );

    expect(withImpossible.sample.rttMs, lessThan(0));
    expect(withImpossible.clockOffsetMs, 100);
  });

  test(
    'negative round trips cannot carry the estimate even in the majority',
    () {
      // 把竞争门槛下限压到 0 是不够的:负往返永远满足 `0 + tolerance`,一旦这类样本
      // 成为多数就会直接赢下中位数,发布一个由自相矛盾时刻拼出来的偏移。
      double? clockOffsetMs;
      var window = const <ClockSample>[];
      ClockSampleResult feed(num offsetMs, num rttMs, num atMs) {
        final result = updateClockSample(
          clientSendTime: atMs,
          // 直接构造这对时刻,好让往返时延为负:报告的服务端处理耗时超过客户端量到
          // 的往返。
          serverReceiveTime: atMs + offsetMs + rttMs / 2,
          serverSendTime:
              atMs + offsetMs + rttMs / 2 + (rttMs < 0 ? -rttMs : 0),
          now: atMs + (rttMs < 0 ? 0 : rttMs),
          previousClockOffsetMs: clockOffsetMs,
          previousSamples: window,
        );
        clockOffsetMs = result.clockOffsetMs;
        window = result.samples;
        return result;
      }

      feed(100, 10, 1000);
      feed(100, 10, 16000);
      feed(100, 10, 31000);
      expect(clockOffsetMs, 100);

      // 四个自相矛盾却一致给出野值的样本:窗口里的多数,且每个都比诚实样本"更快"。
      for (final atMs in [46000, 61000, 76000, 91000]) {
        final result = feed(5000, -800, atMs);
        expect(result.sample.rttMs, lessThan(0));
      }

      expect(clockOffsetMs, 100);
    },
  );

  test(
    'keeps the published offset when nothing in the window is believable',
    () {
      final first = updateClockSample(
        clientSendTime: 1000,
        serverReceiveTime: 1205,
        serverSendTime: 1205,
        now: 1010,
      );
      expect(first.clockOffsetMs, 200);

      // 窗口里只剩一个不可能的样本:从它发布任何数字都是凭空捏造。
      final second = updateClockSample(
        clientSendTime: 2000,
        serverReceiveTime: 2100,
        serverSendTime: 2900,
        now: 2000,
        previousRttMs: first.rttMs,
        previousClockOffsetMs: first.clockOffsetMs,
      );

      expect(second.sample.rttMs, lessThan(0));
      expect(second.clockOffsetMs, 200);
    },
  );

  test('samples older than the retention window are dropped', () {
    final trip = _pingRoundTrip(
      clientSendTime: 10000000,
      offsetMs: 300,
      rttMs: 10,
    );
    final result = updateClockSample(
      clientSendTime: trip.clientSendTime,
      serverReceiveTime: trip.serverReceiveTime,
      serverSendTime: trip.serverSendTime,
      now: trip.now,
      previousRttMs: 10,
      previousClockOffsetMs: 100,
      previousSamples: [
        ClockSample(
          offsetMs: 100,
          rttMs: 10,
          atMs: 10000000 - clockSampleMaxAgeMs - 1,
        ),
        ClockSample(
          offsetMs: 100,
          rttMs: 10,
          atMs: 10000000 - clockSampleMaxAgeMs - 2,
        ),
      ],
    );

    expect(result.samples.length, 1);
    expect(result.clockOffsetMs, 300);
  });

  test('the window is bounded', () {
    final result = _runSamples(
      _steady(count: clockSampleWindowSize + 6, offsetMs: 50),
    );
    expect(result.window.length, clockSampleWindowSize);
  });

  test('a move just inside the deadband is ignored, just outside is taken', () {
    final base = _steady(count: clockSampleWindowSize, offsetMs: 0);
    double? shiftBy(num delta) => _runSamples([
      ...base,
      ..._steady(
        count: clockSampleWindowSize,
        offsetMs: delta,
        startIndex: clockSampleWindowSize,
      ),
    ]).clockOffsetMs;

    expect(shiftBy(clockOffsetDeadbandMs), 0);
    expect(shiftBy(clockOffsetDeadbandMs + 1), clockOffsetDeadbandMs + 1);
  });

  test('extrapolates a playing snapshot by the elapsed time', () {
    final advanced = extrapolatePlayingRoomState(
      _roomState(
        _playback(playState: PlaybackPlayState.playing, currentTime: 100),
      ),
      1200,
    );
    expect(advanced.playback!.currentTime, closeTo(101.2, 1e-9));
    expect(advanced.roomCode, 'ABC123');
    expect(advanced.playback!.playState, PlaybackPlayState.playing);
  });

  test('scales the extrapolation by the room playback rate', () {
    final advanced = extrapolatePlayingRoomState(
      _roomState(
        _playback(
          playState: PlaybackPlayState.playing,
          currentTime: 100,
          playbackRate: 2,
        ),
      ),
      1000,
    );
    expect(advanced.playback!.currentTime, closeTo(102, 1e-9));
  });

  test('never rewinds the room on a negative elapsed time', () {
    final advanced = extrapolatePlayingRoomState(
      _roomState(
        _playback(playState: PlaybackPlayState.playing, currentTime: 100),
      ),
      -5000,
    );
    expect(advanced.playback!.currentTime, 100);
  });

  test('ignores serverTime entirely', () {
    // 这就是 #210 的判据:两份快照只有服务端打戳不同,外推结果必须一致。
    double advanceWith(num serverTime) => extrapolatePlayingRoomState(
      _roomState(
        _playback(
          playState: PlaybackPlayState.playing,
          currentTime: 100,
          serverTime: serverTime,
        ),
      ),
      1000,
    ).playback!.currentTime;

    expect(advanceWith(5000), advanceWith(5000 + 900000));
  });

  test('leaves non-playing states untouched', () {
    final paused = _roomState(_playback(playState: PlaybackPlayState.paused));
    expect(
      identical(extrapolatePlayingRoomState(paused, 4000), paused),
      isTrue,
    );

    final empty = _roomState(null);
    expect(identical(extrapolatePlayingRoomState(empty, 4000), empty), isTrue);
  });

  test('a reported snapshot age moves the anchor back before arrival', () {
    // 中途加入的情形:服务端交来的快照已经旧了一个广播周期,即它在到达前 2.1s
    // 才是当前的。
    expect(resolvePlaybackAnchorAtMs(10000, 2100), 7900);
  });

  test('a legacy server without an age anchors at arrival', () {
    expect(resolvePlaybackAnchorAtMs(10000, null), 10000);
  });

  test('a zero age anchors at arrival', () {
    expect(resolvePlaybackAnchorAtMs(10000, 0), 10000);
  });

  test('a negative age cannot push the anchor forward', () {
    // 只有坏掉或恶意的服务端才到得了这里(守卫已经拒了),但把锚点推到到达之后
    // 会让每次回放都把房间往回拨。
    expect(resolvePlaybackAnchorAtMs(10000, -5000), 10000);
  });

  test('a non-finite age is ignored rather than poisoning the anchor', () {
    expect(resolvePlaybackAnchorAtMs(10000, double.nan), 10000);
    expect(resolvePlaybackAnchorAtMs(10000, double.infinity), 10000);
  });

  test('an age past the trust bound falls back to anchoring at arrival', () {
    expect(
      resolvePlaybackAnchorAtMs(10000, maxTrustedPlaybackAgeMs),
      10000 - maxTrustedPlaybackAgeMs,
    );
    expect(
      resolvePlaybackAnchorAtMs(10000, maxTrustedPlaybackAgeMs + 1),
      10000,
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
