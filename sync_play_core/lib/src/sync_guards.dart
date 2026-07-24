/// 同步守卫,移植自 sync-guards.ts。
///
/// 这些都是纯判定:引擎在施加远端状态与广播本地状态的两条路径上各调用一
/// 部分,用来把"我们自己刚造成的动静"与"用户/对端的真实意图"区分开。
///
/// 移植前 Dart 侧只有一条按 playState 比对的粗略回声判定,位置和倍速完全
/// 不看,导致施加动作引起的回流经常漏网、又被当成新状态播回房间。
library;

import 'common.dart';
import 'models.dart';

// ---- 时间窗口(extension/src/content/index.ts) ----

/// 远端停止意图的默认持续时间。
const int pauseHoldMs = 1200;

/// 首个权威房间状态的停止意图持续时间(进房/切页后放宽)。
const int initialRoomStatePauseHoldMs = 3000;

/// 施加远端状态后,本地回流事件按回声抑制的时长。
const int remoteEchoSuppressionMs = 700;

/// 施加远端"播放"后,本地伪暂停被压制的时长。
const int remotePlayTransitionGuardMs = 1800;

/// 刚施加下去的远端状态,用于识别它引起的本地回流。
typedef SuppressedRemotePlayback = ({
  num until,
  String url,
  PlaybackPlayState playState,
  double currentTime,
  double playbackRate,
});

/// 刚施加下去的远端"播放"意图,用于压制随之而来的伪暂停。
typedef RecentRemotePlayingIntent = ({
  num until,
  String url,
  double currentTime,
});

/// 程序化施加的动作签名(runtime-state.ts: ProgrammaticPlaybackSignature)。
typedef ProgrammaticPlaybackSignature = ({
  String url,
  PlaybackPlayState playState,
  double currentTime,
  double playbackRate,
});

/// 本地显式播放/暂停动作(runtime-state.ts: ExplicitPlaybackAction)。
typedef ExplicitPlaybackAction = ({PlaybackPlayState playState, num at});

// ------------------------------------------------------------ 状态兼容判定

/// 缓冲是"正在努力播放"的一种,可以匹配远端的 playing。
bool _localEchoStateCompatible(
  PlaybackPlayState local,
  PlaybackPlayState remote,
) =>
    local == remote ||
    (local == PlaybackPlayState.buffering &&
        remote == PlaybackPlayState.playing);

/// sync-guards.ts: getProgrammaticEventThreshold
///
/// 不同事件源与施加动作之间的位置误差量级不同:seek 类事件紧跟施加、
/// 误差小;timeupdate/ratechange 可能隔了几拍,要放宽。
double programmaticEventThreshold(
  LocalPlaybackEventSource eventSource,
  PlaybackPlayState playState,
) {
  switch (eventSource) {
    case LocalPlaybackEventSource.seeking:
    case LocalPlaybackEventSource.seeked:
    case LocalPlaybackEventSource.canplay:
      return 0.6;
    case LocalPlaybackEventSource.timeupdate:
      return 1;
    case LocalPlaybackEventSource.ratechange:
      return 1.2;
    default:
      return playState == PlaybackPlayState.playing ? 0.9 : 0.25;
  }
}

/// sync-guards.ts: mapEventSourceToExplicitAction
ExplicitUserActionKind? explicitActionForEventSource(
  LocalPlaybackEventSource eventSource,
) => switch (eventSource) {
  LocalPlaybackEventSource.play ||
  LocalPlaybackEventSource.playing => ExplicitUserActionKind.play,
  LocalPlaybackEventSource.pause => ExplicitUserActionKind.pause,
  LocalPlaybackEventSource.seeking ||
  LocalPlaybackEventSource.seeked => ExplicitUserActionKind.seek,
  LocalPlaybackEventSource.ratechange => ExplicitUserActionKind.ratechange,
  _ => null,
};

// ------------------------------------------------------------ 施加侧

/// sync-guards.ts: shouldForcePauseWhileWaitingForInitialRoomState
///
/// 在房间里、首个权威状态还没到、本地却在播:必须先停住。跟随导航是强制
/// 起播的,不停的话本地会一路播下去,而 hydration 一结束广播守卫就失效,
/// 本地的 playing 会把房间状态翻掉。
bool shouldForcePauseWhileWaitingForInitialRoomState({
  required String? activeRoomCode,
  required bool pendingRoomStateHydration,
  required bool isLocalPaused,
}) =>
    activeRoomCode != null && pendingRoomStateHydration && !isLocalPaused;

/// sync-guards.ts: rememberRemotePlaybackForSuppression
///
/// 施加远端状态后记下它,用于随后识别本地回流。
({
  SuppressedRemotePlayback? suppressed,
  RecentRemotePlayingIntent? playingIntent,
})
rememberRemotePlaybackForSuppression({
  required PlaybackState playback,
  required String? normalizedUrl,
  required num now,
  int echoSuppressionMs = remoteEchoSuppressionMs,
  int playTransitionGuardMs = remotePlayTransitionGuardMs,
}) {
  if (normalizedUrl == null) {
    return (suppressed: null, playingIntent: null);
  }
  return (
    suppressed: (
      until: now + echoSuppressionMs,
      url: normalizedUrl,
      playState: playback.playState,
      currentTime: playback.currentTime,
      playbackRate: playback.playbackRate,
    ),
    playingIntent: playback.playState == PlaybackPlayState.playing
        ? (
            until: now + playTransitionGuardMs,
            url: normalizedUrl,
            currentTime: playback.currentTime,
          )
        : null,
  );
}

/// sync-guards.ts: shouldApplySelfPlayback
///
/// 自己的状态回流通常不必再施加,但本地实际状态可能已经和它对不上了
/// (该停没停、该播没播、位置或倍速偏了)——那种情况必须施加,否则本地
/// 会和房间静默失配。
bool shouldApplySelfPlayback({
  required bool isLocalPaused,
  required double localCurrentTime,
  required double localPlaybackRate,
  required PlaybackState playback,
}) {
  if ((playback.playState == PlaybackPlayState.paused ||
          playback.playState == PlaybackPlayState.buffering) &&
      !isLocalPaused) {
    return true;
  }
  if (playback.playState == PlaybackPlayState.playing && isLocalPaused) {
    return true;
  }
  return (localCurrentTime - playback.currentTime).abs() > 0.6 ||
      (localPlaybackRate - playback.playbackRate).abs() > 0.01;
}

/// sync-guards.ts: hasRecentRemoteStopIntent
///
/// 远端的停止意图是否仍在生效。生效期间本地不应自作主张恢复播放。
bool hasRecentRemoteStopIntent({
  required num now,
  required num pauseHoldUntil,
  required String? normalizedCurrentUrl,
  required String? activeSharedUrl,
  required PlaybackPlayState? intendedPlayState,
  required SuppressedRemotePlayback? suppressedRemotePlayback,
}) {
  if (now >= pauseHoldUntil || normalizedCurrentUrl == null) {
    return false;
  }
  if (activeSharedUrl != null && normalizedCurrentUrl != activeSharedUrl) {
    return false;
  }
  if (intendedPlayState == PlaybackPlayState.paused) {
    return true;
  }
  if (suppressedRemotePlayback == null ||
      normalizedCurrentUrl != suppressedRemotePlayback.url) {
    return false;
  }
  return suppressedRemotePlayback.playState == PlaybackPlayState.paused;
}

// ------------------------------------------------------------ 广播侧

/// sync-guards.ts: shouldSuppressLocalEcho
///
/// 刚施加的远端状态会让播放器回流一串事件。四维比对(URL、播放态、
/// 倍速、位置)都吻合才算回声——只比播放态的话,施加之外的真实变化会被
/// 一起吞掉。
({bool shouldSuppress, SuppressedRemotePlayback? next}) shouldSuppressLocalEcho({
  required SuppressedRemotePlayback? suppressedRemotePlayback,
  required String? normalizedCurrentUrl,
  required PlaybackPlayState playState,
  required double currentTime,
  required double playbackRate,
  required num now,
}) {
  final suppressed = suppressedRemotePlayback;
  if (suppressed == null || now >= suppressed.until) {
    return (shouldSuppress: false, next: null);
  }
  if (normalizedCurrentUrl != suppressed.url ||
      !_localEchoStateCompatible(playState, suppressed.playState) ||
      (playbackRate - suppressed.playbackRate).abs() > 0.01) {
    return (shouldSuppress: false, next: suppressed);
  }
  final delta = (currentTime - suppressed.currentTime).abs();
  // 双方都在播时位置本来就会走,阈值放宽
  final threshold =
      playState == PlaybackPlayState.playing &&
          suppressed.playState == PlaybackPlayState.playing
      ? 0.9
      : 0.2;
  return (shouldSuppress: delta <= threshold, next: suppressed);
}

/// sync-guards.ts: shouldSuppressProgrammaticEvent
///
/// 程序化施加窗口内、与施加签名吻合的事件是回声。位置阈值按事件源分档
/// (见 [programmaticEventThreshold]);窗口内出现的用户手势会让位:
/// 那是真实意图,不能当回声吞掉。
({bool shouldSuppress, bool clearWindow}) shouldSuppressProgrammaticEvent({
  required num programmaticApplyUntil,
  required num programmaticApplyAt,
  required ProgrammaticPlaybackSignature? programmaticApplySignature,
  required String? normalizedCurrentUrl,
  required PlaybackPlayState playState,
  required double currentTime,
  required double playbackRate,
  required LocalPlaybackEventSource eventSource,
  required ExplicitUserAction? lastExplicitUserAction,
  required num now,
  int gestureGraceMs = 1200,
}) {
  final signature = programmaticApplySignature;
  if (signature == null || now >= programmaticApplyUntil) {
    return (shouldSuppress: false, clearWindow: true);
  }
  // 窗口内的用户手势优先:它不是回声。但仅限窗口开始之后发生的手势——
  // 窗口开始之前记下的动作(例如用户在远端状态到达前片刻拖过进度条)不能
  // 作为窗口内事件的证据,否则施加自身的 seeking/play 回声会借这条陈旧记录
  // 通过放行,被原样广播回房间。
  final matched = explicitActionForEventSource(eventSource);
  if (matched != null &&
      lastExplicitUserAction != null &&
      lastExplicitUserAction.kind == matched &&
      lastExplicitUserAction.at >= programmaticApplyAt &&
      now - lastExplicitUserAction.at < gestureGraceMs) {
    return (shouldSuppress: false, clearWindow: true);
  }
  if (normalizedCurrentUrl != signature.url ||
      !_localEchoStateCompatible(playState, signature.playState) ||
      (playbackRate - signature.playbackRate).abs() > 0.01) {
    return (shouldSuppress: false, clearWindow: false);
  }
  final delta = (currentTime - signature.currentTime).abs();
  return (
    shouldSuppress: delta <= programmaticEventThreshold(eventSource, playState),
    clearWindow: false,
  );
}

/// sync-guards.ts: shouldSuppressRemoteFollowupBroadcast
///
/// 跟随远端播放之后,本地会回流一串 playing/canplay/waiting。把它们播回
/// 房间是纯噪音(对端本来就是发起者)。用户自己的手势不受压制。
({bool shouldSuppress, num nextUntil, String? nextUrl})
shouldSuppressRemoteFollowupBroadcast({
  required num remoteFollowPlayingUntil,
  required String? remoteFollowPlayingUrl,
  required String? normalizedCurrentUrl,
  required PlaybackPlayState playState,
  required LocalPlaybackEventSource eventSource,
  required ExplicitUserAction? lastExplicitUserAction,
  required num now,
  int gestureGraceMs = 1200,
}) {
  const cleared = (shouldSuppress: false, nextUntil: 0, nextUrl: null);
  if (remoteFollowPlayingUrl == null || remoteFollowPlayingUntil <= 0) {
    return cleared;
  }
  if (now >= remoteFollowPlayingUntil) {
    return cleared;
  }
  if (normalizedCurrentUrl == null ||
      normalizedCurrentUrl != remoteFollowPlayingUrl) {
    return cleared;
  }
  // 暂停是需要上报的真实变化,窗口就此作废
  if (playState == PlaybackPlayState.paused) {
    return cleared;
  }
  final keep = (
    nextUntil: remoteFollowPlayingUntil,
    nextUrl: remoteFollowPlayingUrl,
  );
  if (playState == PlaybackPlayState.buffering) {
    return (
      shouldSuppress: eventSource == LocalPlaybackEventSource.waiting,
      nextUntil: keep.nextUntil,
      nextUrl: keep.nextUrl,
    );
  }

  final matched = explicitActionForEventSource(eventSource);
  final hasRecentSeek =
      lastExplicitUserAction != null &&
      lastExplicitUserAction.kind == ExplicitUserActionKind.seek &&
      now - lastExplicitUserAction.at < gestureGraceMs;
  final matchesGesture =
      matched != null &&
      lastExplicitUserAction != null &&
      lastExplicitUserAction.kind == matched &&
      now - lastExplicitUserAction.at < gestureGraceMs;
  // seek 之后的播放类事件也是用户意图的一部分
  final seekCarried =
      hasRecentSeek &&
      (eventSource == LocalPlaybackEventSource.play ||
          eventSource == LocalPlaybackEventSource.playing ||
          eventSource == LocalPlaybackEventSource.canplay);
  if (matchesGesture || seekCarried) {
    return (
      shouldSuppress: false,
      nextUntil: keep.nextUntil,
      nextUrl: keep.nextUrl,
    );
  }
  return (
    shouldSuppress: true,
    nextUntil: keep.nextUntil,
    nextUrl: keep.nextUrl,
  );
}

/// sync-guards.ts: shouldSuppressRemotePlayTransition
///
/// 施加远端"播放"之后,播放器常会先冒一下暂停再真正播起来。把那个瞬时
/// 暂停播回房间会让对端跟着停。用户自己按的暂停不受压制。
({bool shouldSuppress, RecentRemotePlayingIntent? next})
shouldSuppressRemotePlayTransition({
  required RecentRemotePlayingIntent? recentRemotePlayingIntent,
  required String? normalizedCurrentUrl,
  required PlaybackPlayState playState,
  required double currentTime,
  required ExplicitPlaybackAction? lastExplicitPlaybackAction,
  required num now,
  int gestureGraceMs = 1200,
}) {
  final intent = recentRemotePlayingIntent;
  if (intent == null || now >= intent.until) {
    return (shouldSuppress: false, next: null);
  }
  if (normalizedCurrentUrl != intent.url ||
      playState == PlaybackPlayState.playing) {
    return (shouldSuppress: false, next: intent);
  }
  final hasRecentExplicitPause =
      lastExplicitPlaybackAction != null &&
      lastExplicitPlaybackAction.playState == PlaybackPlayState.paused &&
      playState == PlaybackPlayState.paused &&
      now - lastExplicitPlaybackAction.at < gestureGraceMs;
  if (hasRecentExplicitPause) {
    return (shouldSuppress: false, next: intent);
  }
  return (
    shouldSuppress: (currentTime - intent.currentTime).abs() <= 1.5,
    next: intent,
  );
}
