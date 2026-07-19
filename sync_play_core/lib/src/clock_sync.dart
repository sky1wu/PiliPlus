/// 对应 extension/src/background/clock-sync.ts 的 NTP 式对时纯函数。
library;

import 'dart:math' as math;

import 'common.dart';
import 'models.dart';

/// clock-sync.ts: CLOCK_SYNC_INTERVAL_MS
const int clockSyncIntervalMs = 15000;

/// JS Math.round 语义(-2.5 → -2,半数向正无穷取整);
/// Dart 的 round() 是半数远离零(-2.5 → -3),偏移量为负时会与 TS 端产生
/// 一毫秒级偏差,这里显式对齐。
double _jsRound(double value) => (value + 0.5).floorToDouble();

class ClockSample {
  const ClockSample({required this.rttMs, required this.clockOffsetMs});

  final double rttMs;
  final double clockOffsetMs;
}

/// clock-sync.ts: updateClockSample——首个样本原样采用,
/// 后续样本按 0.7/0.3 的 EWMA 平滑并取整。
ClockSample updateClockSample({
  required num clientSendTime,
  required num serverReceiveTime,
  required num serverSendTime,
  required num now,
  double? previousRttMs,
  double? previousClockOffsetMs,
}) {
  final sampleRtt =
      (now - clientSendTime - (serverSendTime - serverReceiveTime)).toDouble();
  final sampleOffset =
      ((serverReceiveTime - clientSendTime + (serverSendTime - now)) / 2)
          .toDouble();

  return ClockSample(
    rttMs: previousRttMs == null
        ? sampleRtt
        : _jsRound(previousRttMs * 0.7 + sampleRtt * 0.3),
    clockOffsetMs: previousClockOffsetMs == null
        ? sampleOffset
        : _jsRound(previousClockOffsetMs * 0.7 + sampleOffset * 0.3),
  );
}

/// clock-sync.ts: compensateRoomStateForClock——仅对 playing 状态按
/// 服务器时间流逝外推 currentTime;其余情况原样返回。
RoomState compensateRoomStateForClock(
  RoomState state,
  double? clockOffsetMs, {
  num? now,
}) {
  final playback = state.playback;
  if (playback == null ||
      clockOffsetMs == null ||
      playback.playState != PlaybackPlayState.playing) {
    return state;
  }

  final nowMs = now ?? DateTime.now().millisecondsSinceEpoch;
  final estimatedServerNow = nowMs + clockOffsetMs;
  final elapsedMs =
      math.max(0.0, estimatedServerNow - playback.serverTime.toDouble());
  return RoomState(
    roomCode: state.roomCode,
    sharedVideo: state.sharedVideo,
    playback: playback.copyWith(
      currentTime:
          playback.currentTime + (elapsedMs / 1000) * playback.playbackRate,
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
