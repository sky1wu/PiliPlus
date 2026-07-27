/// 对应 packages/protocol/src/types/common.ts 与 domain.ts 的公共类型。
library;

/// 协议版本(packages/protocol: PROTOCOL_VERSION)。
const int syncPlayProtocolVersion = 4;

/// 播放状态(wire 值与 TS 端字面量一致)。
enum PlaybackPlayState {
  playing('playing'),
  paused('paused'),
  buffering('buffering');

  const PlaybackPlayState(this.wire);

  final String wire;

  static PlaybackPlayState? tryParse(Object? value) {
    if (value is! String) return null;
    for (final state in values) {
      if (state.wire == value) return state;
    }
    return null;
  }
}

/// 播放同步意图(domain.ts: PLAYBACK_SYNC_INTENTS)。
enum PlaybackSyncIntent {
  explicitSeek('explicit-seek'),
  explicitRatechange('explicit-ratechange');

  const PlaybackSyncIntent(this.wire);

  final String wire;

  static PlaybackSyncIntent? tryParse(Object? value) {
    if (value is! String) return null;
    for (final intent in values) {
      if (intent.wire == value) return intent;
    }
    return null;
  }
}

/// domain.ts: isExplicitControlSyncIntent——现有两种 intent 均为显式控制。
bool isExplicitControlSyncIntent(PlaybackSyncIntent? syncIntent) =>
    syncIntent != null;

/// 服务端错误码(common.ts: ErrorCode)。wire 上是字符串,服务端可能新增
/// 未知码,因此消息模型保留 String,这里只提供已知常量。
abstract final class SyncPlayErrorCode {
  static const String originNotAllowed = 'origin_not_allowed';
  static const String roomNotFound = 'room_not_found';
  static const String joinTokenInvalid = 'join_token_invalid';
  static const String memberTokenInvalid = 'member_token_invalid';
  static const String notInRoom = 'not_in_room';
  static const String rateLimited = 'rate_limited';
  static const String invalidMessage = 'invalid_message';
  static const String payloadTooLarge = 'payload_too_large';
  static const String roomFull = 'room_full';
  static const String unsupportedProtocolVersion =
      'unsupported_protocol_version';
  static const String internalError = 'internal_error';
}

/// 本地播放事件来源(runtime-state.ts: LocalPlaybackEventSource 的移动端子集)。
enum LocalPlaybackEventSource {
  play,
  playing,
  pause,
  /// 播放中断流缓冲(浏览器端的 `waiting` 事件;移动端由宿主播放器的
  /// isBuffering 信号驱动)。
  waiting,
  seeking,
  seeked,
  canplay,
  ratechange,
  timeupdate,
  ended,
  manual,
}

enum ExplicitUserActionKind { play, pause, seek, ratechange }

typedef ExplicitUserAction = ({ExplicitUserActionKind kind, num at});
