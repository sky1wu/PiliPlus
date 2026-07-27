/// 对应 extension/src/background/clock-sync.ts 的 NTP 式对时纯函数。
library;

import 'dart:math' as math;

import 'common.dart';
import 'models.dart';

/// clock-sync.ts: CLOCK_SYNC_INTERVAL_MS
const int clockSyncIntervalMs = 15000;

/// clock-sync.ts: CLOCK_SAMPLE_WINDOW_SIZE——稳健偏移估计取样的窗口长度
/// (按 [clockSyncIntervalMs] 约两分钟)。
const int clockSampleWindowSize = 8;

/// clock-sync.ts: CLOCK_SAMPLE_MAX_AGE_MS——超龄样本先剔除。也是真实钟步进的
/// 恢复路径:休眠/唤醒等长于此的间隔会让整个窗口老化清空,估计从新样本重新起步。
const int clockSampleMaxAgeMs = 150000;

/// clock-sync.ts: CLOCK_SAMPLE_RTT_TOLERANCE_MS——只有往返时延与窗口内最快样本
/// 相差不超过此值的样本才参与估计(慢往返多为不对称,偏移最多被拉偏半个多余时延)。
const int clockSampleRttToleranceMs = 20;

/// clock-sync.ts: CLOCK_SAMPLE_MIN_TRUSTED_SIZE——窗口样本少于此值时死区不生效,
/// 否则第一个野值会被发布之后再被死区本身"锁住"。
const int clockSampleMinTrustedSize = 3;

/// clock-sync.ts: CLOCK_OFFSET_DEADBAND_MS——稳健估计移动超过此值,已发布的偏移
/// 才跟随。
///
/// 此处偏移只是诊断量,不参与播放:位置外推改以本地单调锚点为准
/// (见 [extrapolatePlayingRoomState]),正因为任何滤波都无法让跨两台机器的比较
/// 变得可信。仍做滤波而非平滑,是为了让 UI 上的数字反映钟的真实状态,而不是每来
/// 一个样本就跳一次。
const int clockOffsetDeadbandMs = 120;

/// JS Math.round 语义(-2.5 → -2,半数向正无穷取整);
/// Dart 的 round() 是半数远离零(-2.5 → -3),偏移量为负时会与 TS 端产生
/// 一毫秒级偏差,这里显式对齐。
double _jsRound(double value) => (value + 0.5).floorToDouble();

/// clock-sync.ts: ClockSample——窗口内保留的单次 ping 样本。
class ClockSample {
  const ClockSample({
    required this.offsetMs,
    required this.rttMs,
    required this.atMs,
  });

  final double offsetMs;
  final double rttMs;

  /// 采样时刻(与 updateClockSample 的 now 同一时基)。
  final double atMs;
}

/// clock-sync.ts: ClockSampleResult.sample——本次原始样本,仅供诊断。
///
/// [outboundMs] 与 [inboundMs] 各自是"钟差 + 单向时延",符号相反:半和为钟差、
/// 差为往返时延。两者很大而往返时延很小,说明四个时刻里有一个打戳偏晚,而不是
/// 两台机器的钟真的差这么多。
class ClockRawSample {
  const ClockRawSample({
    required this.offsetMs,
    required this.rttMs,
    required this.outboundMs,
    required this.inboundMs,
  });

  final double offsetMs;
  final double rttMs;
  final double outboundMs;
  final double inboundMs;
}

/// clock-sync.ts: ClockSampleResult
class ClockSampleResult {
  const ClockSampleResult({
    required this.rttMs,
    required this.clockOffsetMs,
    required this.samples,
    required this.sample,
  });

  final double rttMs;

  /// 尚无可信样本时为 null。
  final double? clockOffsetMs;

  /// 保留下来的窗口,最旧在前;下次作为 previousSamples 传回。
  final List<ClockSample> samples;

  final ClockRawSample sample;
}

double _median(List<double> values) {
  final sorted = [...values]..sort();
  final middle = sorted.length ~/ 2;
  return sorted.length.isOdd
      ? sorted[middle]
      : (sorted[middle - 1] + sorted[middle]) / 2;
}

/// clock-sync.ts: estimateOffsetMs——窗口认可的偏移:往返时延有竞争力的那些样本
/// 的中位数,既丢掉慢(多半不对称)的往返,也丢掉孤立野值。窗口内无可信样本时
/// 返回 null。
({double offsetMs, int usableCount})? _estimateOffsetMs(
  List<ClockSample> samples,
) {
  // 往返时延为负说明四个时刻自相矛盾,该样本携带的偏移不构成任何证据,直接剔除
  // ——把门槛下限压到 0 是不够的:负往返永远满足 `0 + tolerance`,会继续参与中位数
  // 竞争,等这类样本成为多数时还会直接赢下。它们仍留在原始日志里,不可能的往返
  // 时延本身就是诊断信息。
  final usable = samples.where((sample) => sample.rttMs >= 0).toList();
  if (usable.isEmpty) {
    return null;
  }

  final fastestRtt = usable
      .map((sample) => sample.rttMs)
      .reduce((left, right) => math.min(left, right));
  final competing = usable.where(
    (sample) => sample.rttMs <= fastestRtt + clockSampleRttToleranceMs,
  );
  return (
    offsetMs: _median(competing.map((sample) => sample.offsetMs).toList()),
    usableCount: usable.length,
  );
}

/// clock-sync.ts: updateClockSample——往返时延按 0.7/0.3 的 EWMA 平滑;
/// 偏移改由窗口内的稳健估计给出,并经死区过滤后才发布。
ClockSampleResult updateClockSample({
  required num clientSendTime,
  required num serverReceiveTime,
  required num serverSendTime,
  required num now,
  double? previousRttMs,
  double? previousClockOffsetMs,
  List<ClockSample> previousSamples = const [],
}) {
  final outboundMs = (serverReceiveTime - clientSendTime).toDouble();
  final inboundMs = (serverSendTime - now).toDouble();
  final sampleRtt = outboundMs - inboundMs;
  final sampleOffset = (outboundMs + inboundMs) / 2;

  final retained = [
    for (final sample in previousSamples)
      if (now - sample.atMs <= clockSampleMaxAgeMs) sample,
    ClockSample(offsetMs: sampleOffset, rttMs: sampleRtt, atMs: now.toDouble()),
  ];
  final samples = retained.length > clockSampleWindowSize
      ? retained.sublist(retained.length - clockSampleWindowSize)
      : retained;

  final estimate = _estimateOffsetMs(samples);
  // 只有估计移出死区,已发布的偏移才跟随,常规采样噪声不动它。窗口里没有可信样本
  // 时保留已发布值,不凭空造一个数。
  final double? clockOffsetMs;
  if (estimate == null) {
    clockOffsetMs = previousClockOffsetMs;
  } else if (previousClockOffsetMs == null ||
      estimate.usableCount < clockSampleMinTrustedSize ||
      (estimate.offsetMs - previousClockOffsetMs).abs() >
          clockOffsetDeadbandMs) {
    clockOffsetMs = _jsRound(estimate.offsetMs);
  } else {
    clockOffsetMs = previousClockOffsetMs;
  }

  return ClockSampleResult(
    rttMs: previousRttMs == null
        ? sampleRtt
        : _jsRound(previousRttMs * 0.7 + sampleRtt * 0.3),
    clockOffsetMs: clockOffsetMs,
    samples: samples,
    sample: ClockRawSample(
      offsetMs: sampleOffset,
      rttMs: sampleRtt,
      outboundMs: outboundMs,
      inboundMs: inboundMs,
    ),
  );
}

/// clock-sync.ts: MAX_TRUSTED_PLAYBACK_AGE_MS——仍可当作"房间此刻正在播"的最大
/// 快照年龄,约五个广播周期(播放中的成员每约 2.1s 重播一次)。
///
/// 超过这个值,说明久无广播刷新快照,最简单的解释不是"加入慢",而是房间已经没人
/// 在播(最后一个成员在状态还是 playing 时关掉了页面),或服务端在打戳与下发之间
/// 发生了钟步进。此时把整段间隔都算进去会把位置猛推向前,于是退回保守读法:按下发
/// 的位置原样采用,即 #212 之前的行为。房间真的活着时,这个上界远远碰不到。
const int maxTrustedPlaybackAgeMs = 10000;

/// clock-sync.ts: resolvePlaybackAnchorAtMs——由"到达时刻"与"服务端声明的快照
/// 年龄"求出该快照位置为真的本地单调时刻。
///
/// 年龄正是中途加入能落在正确位置的关键:服务端交给新成员的是最后一次广播的快照,
/// 最坏已旧了一个广播周期,没有它接收端会当作当前值而起播偏后。跨机只能以**时长**
/// 形式传递——时刻会迫使接收端拿服务端时刻减本地时刻,而那正是
/// [extrapolatePlayingRoomState] 要消除的跨钟比较。
///
/// 缺失(旧服务端)、非有限、非正、超过 [maxTrustedPlaybackAgeMs] 一律退回到达时刻。
double resolvePlaybackAnchorAtMs(double receivedAtMs, num? playbackAgeMs) {
  if (playbackAgeMs == null ||
      !playbackAgeMs.isFinite ||
      playbackAgeMs <= 0 ||
      playbackAgeMs > maxTrustedPlaybackAgeMs) {
    return receivedAtMs;
  }
  return receivedAtMs - playbackAgeMs;
}

/// clock-sync.ts: extrapolatePlayingRoomState——把 playing 快照按其打戳以来
/// 真正流逝的时间向前推。
///
/// [elapsedMs] 由本地单调时钟量得(见 PlaybackAnchorTracker.compensateRoomState),
/// 而不是由 serverTime 与时钟偏移推出。拿服务端时刻与本地时刻相比跨了两台机器的钟,
/// 它们的分歧会直接落到外推位置上:钟差 500ms 的客户端就对着偏 500ms 的目标追,
/// 且钟差每移动一次目标就被踢一次。漂移控制器无法把它与真实漂移区分,只能以改倍速
/// 作答,于是一台游走的钟会造成永久的倍速抖动。
///
/// 在同一个钟上量流逝时间就取消了这个比较,连带整类故障一起消失。实测:服务端在
/// WSL、浏览器在 Windows 宿主(同一台机器两个钟,由 hypervisor 重同步),1ms 回环
/// 往返下样本在一分钟内横跨 -893ms ~ +1264ms——不存在可估计的稳定偏移,任何滤波
/// 都救不回来。
RoomState extrapolatePlayingRoomState(RoomState state, double elapsedMs) {
  final playback = state.playback;
  if (playback == null || playback.playState != PlaybackPlayState.playing) {
    return state;
  }

  // 用来测量的这个钟不会倒流,出现负值只可能是调用方的 bug;忽略它,而不是把房间
  // 往回拨。
  final advanceMs = math.max(0.0, elapsedMs);
  return RoomState(
    roomCode: state.roomCode,
    sharedVideo: state.sharedVideo,
    playback: playback.copyWith(
      currentTime:
          playback.currentTime + (advanceMs / 1000) * playback.playbackRate,
    ),
    members: state.members,
  );
}

/// clock-sync.ts: toHealthcheckUrl
String? toHealthcheckUrl(String url) => _toHttpUrl(url, '/');

/// clock-sync.ts: toConnectionCheckUrl
String? toConnectionCheckUrl(String url) =>
    _toHttpUrl(url, '/api/connection-check');

String? _toHttpUrl(String url, String path) {
  final Uri parsed;
  try {
    parsed = Uri.parse(url);
  } on FormatException {
    return null;
  }
  final String scheme;
  if (parsed.scheme == 'ws') {
    scheme = 'http';
  } else if (parsed.scheme == 'wss') {
    scheme = 'https';
  } else {
    return null;
  }
  return Uri(
    scheme: scheme,
    userInfo: parsed.userInfo.isEmpty ? null : parsed.userInfo,
    host: parsed.host,
    port: parsed.hasPort ? parsed.port : null,
    path: path,
  ).toString();
}
