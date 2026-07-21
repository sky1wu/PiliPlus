/// 播放器同步引擎:远端状态施加与本地播放广播的决策核心,移植自
/// Bili-SyncPlay 扩展 content 侧的纯决策函数
/// (playback-apply.ts / playback-reconcile.ts / playback-broadcast.ts)
/// 与 sync-controller.ts 的关键守卫窗口。
///
/// v1 相对浏览器端的显式简化(涉及行为差异的都在此声明):
/// - 无 buffer-pause 升级分类:宿主播放器(PlPlayer)有独立 buffering 信号,
///   由桥接层映射成 `buffering` 播放态与 `waiting` 事件源传入;
/// - 无 festival/watchlater 特例:App 内路由不存在该形态。
///
/// 相对浏览器端的移动端专属处理:
/// - 程序化 seek 的回声窗口按"位置真正到位"关闭(见
///   [programmaticSeekSettleTimeoutMs]),不是浏览器端够用的固定 700ms;
/// - soft-apply 追平期间本地开始缓冲即放弃追平(浏览器端没有这一档:
///   那边 seek 近乎瞬时,不存在"追平时播不动"的情况);
/// - 远端处于 buffering 时不对齐进度(浏览器端会 seek 过去):缓冲中的
///   currentTime 是冻结值,移动端照做会让两端互相拽回、锁死在同一小段
///   (见 [_applyRemotePlayback])。seek 引起的缓冲不会走到这里——广播侧
///   已按扩展端语义改报 playing(见 [broadcastPlayStateForSeek])。
library;

import 'dart:async';

import 'common.dart';
import 'models.dart';
import 'pending_local_override.dart';
import 'soft_apply.dart';
import 'video_ref.dart';

// ---- 时间窗口常量(extension/src/content/index.ts) ----
const int localIntentGuardMs = 1200;
const int programmaticApplyWindowMs = 700;

/// 程序化 seek 后等待播放器真正到位的上限。
///
/// 浏览器端 seek 几乎瞬时落地,700ms 的回声窗口够用;移动端 `seekTo()`
/// 返回时解码往往还没跟上,位置要过 1–3s 才推进。窗口一过就恢复心跳,
/// 播的还是 seek 前的旧位置——服务端 derivePlaybackAuthorityKind 的
/// "位置差 ≥2.5s 即 seek" 兜底会把它当成一次新 seek,把整个房间拽回旧
/// 进度,对端随之 seek+缓冲,再对称地把这边拽回去,形成来回抖动。
const int programmaticSeekSettleTimeoutMs = 6000;

/// 判定程序化 seek 已到位的位置容差(秒)。
const double programmaticSeekSettleToleranceSeconds = 0.6;

/// index.ts: REMOTE_PAUSE_DEBOUNCE_MS
///
/// 远端 paused 延迟这么久再施加。缓冲抖动、状态回声都会瞬时产生 paused,
/// 立刻施加会把本地拉停;延迟期间被更新的状态取代就整个丢弃。用户主动
/// 暂停(userInitiated)走快速通道立即施加,不吃这 250ms 可见延迟。
const int remotePauseDebounceMs = 250;

const int userGestureGraceMs = 1200;

/// playback-broadcast.ts: EXPLICIT_SEEK_BROADCAST_GRACE_MS
const int explicitSeekBroadcastGraceMs = 2500;

/// playback-binding-controller.ts onTimeUpdate:在播时距上次广播
/// 超过该值才随 timeupdate 补发周期心跳。
const int timeupdateBroadcastMinIntervalMs = 2000;

/// 共享视频自然播完后,多久之内加载的新视频才算"连播"
/// (extension/src/content/index.ts: INITIAL_ROOM_STATE_PAUSE_HOLD_MS)。
const int autoplayContinuationWindowMs = 3000;

/// 延迟执行钩子,返回取消函数。测试注入假实现以免依赖真实时钟。
typedef SyncPlayDelayScheduler =
    void Function() Function(Duration delay, void Function() task);

void Function() _defaultDelayScheduler(Duration delay, void Function() task) {
  final timer = Timer(delay, task);
  return timer.cancel;
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
typedef PlaybackVersion = ({num serverTime, num seq});

// ------------------------------------------------------------ 广播侧决策

/// playback-broadcast.ts: shouldSkipBroadcastWhileHydrating
bool shouldSkipBroadcastWhileHydrating({
  required bool pendingRoomStateHydration,
  required num now,
  required num lastUserGestureAt,
  int gestureGraceMs = userGestureGraceMs,
}) {
  if (!pendingRoomStateHydration) {
    return false;
  }
  return now - lastUserGestureAt >= gestureGraceMs;
}

/// playback-broadcast.ts: shouldPauseForNonSharedBroadcast——房间内在播
/// 非共享视频且非用户明确点播时,应强制暂停(PR #140 语义)。
bool shouldPauseForNonSharedBroadcast({
  required String? activeRoomCode,
  required String? activeSharedUrl,
  required String? normalizedCurrentVideoUrl,
  required String? explicitNonSharedPlaybackUrl,
  required PlaybackPlayState playState,
  required ExplicitUserAction? lastExplicitPlaybackAction,
  required num now,
  int gestureGraceMs = userGestureGraceMs,
}) {
  if (activeRoomCode == null ||
      activeSharedUrl == null ||
      normalizedCurrentVideoUrl == activeSharedUrl) {
    return false;
  }
  if (playState != PlaybackPlayState.playing ||
      explicitNonSharedPlaybackUrl == normalizedCurrentVideoUrl) {
    return false;
  }
  return !(lastExplicitPlaybackAction != null &&
      lastExplicitPlaybackAction.kind == ExplicitUserActionKind.play &&
      now - lastExplicitPlaybackAction.at < gestureGraceMs);
}

/// playback-broadcast.ts: deriveUserInitiatedPause——保守判定:任何可能由
/// 缓冲/程序化施加导致的暂停都不得标记为用户主动。
bool deriveUserInitiatedPause({
  required LocalPlaybackEventSource eventSource,
  required PlaybackPlayState playState,
  required ExplicitUserAction? lastExplicitUserAction,
  required num lastForcedPauseAt,
  required num programmaticApplyUntil,
  required PlaybackPlayState? programmaticApplyPlayState,
  required num now,
  int gestureGraceMs = userGestureGraceMs,
}) {
  if (eventSource != LocalPlaybackEventSource.pause ||
      playState != PlaybackPlayState.paused) {
    return false;
  }
  if (lastExplicitUserAction == null ||
      lastExplicitUserAction.kind != ExplicitUserActionKind.pause ||
      lastExplicitUserAction.at <= lastForcedPauseAt ||
      now - lastExplicitUserAction.at >= gestureGraceMs) {
    return false;
  }
  if (programmaticApplyPlayState == PlaybackPlayState.paused &&
      now < programmaticApplyUntil) {
    return false;
  }
  return true;
}

/// sync-controller.ts: getBroadcastPlayState 的 seek 覆盖分支。
///
/// 刚发生过显式 seek 且意图仍是播放时,seek/暂停/缓冲类事件一律改报
/// `playing`。seek 途中播放器必然短暂 readyState 不足、甚至先 pause 再
/// resume,把那些瞬时状态如实播出去会让对端以为发起端停了:轻则跟着停,
/// 重则拿那个冻结位置反过来对齐,两端互相拽。上游用这一条把"seek 引起的
/// 停顿"整个挡在广播之前,所以协议上根本不存在 buffering + explicit-seek
/// 的组合(服务端 derivePlaybackAuthorityKind 里 buffering 抢在
/// explicit-seek 之前判 pause,也因此从未被触发)。
PlaybackPlayState broadcastPlayStateForSeek({
  required LocalPlaybackEventSource eventSource,
  required PlaybackPlayState playState,
  required PlaybackPlayState? intendedPlayState,
  required ExplicitUserAction? lastExplicitUserAction,
  required num now,
  int gestureGraceMs = userGestureGraceMs,
}) {
  const seekStallSources = {
    LocalPlaybackEventSource.seeking,
    LocalPlaybackEventSource.seeked,
    LocalPlaybackEventSource.pause,
    LocalPlaybackEventSource.waiting,
  };
  final hasRecentExplicitSeek =
      lastExplicitUserAction != null &&
      lastExplicitUserAction.kind == ExplicitUserActionKind.seek &&
      now - lastExplicitUserAction.at < gestureGraceMs;
  if (hasRecentExplicitSeek &&
      intendedPlayState == PlaybackPlayState.playing &&
      seekStallSources.contains(eventSource)) {
    return PlaybackPlayState.playing;
  }
  return playState;
}

/// playback-broadcast.ts: derivePlaybackSyncIntent
PlaybackSyncIntent? derivePlaybackSyncIntent({
  required LocalPlaybackEventSource eventSource,
  required ExplicitUserAction? lastExplicitUserAction,
  required num lastForcedPauseAt,
  required num now,
  int gestureGraceMs = userGestureGraceMs,
}) {
  if (lastExplicitUserAction == null ||
      lastExplicitUserAction.at <= lastForcedPauseAt) {
    return null;
  }

  if (eventSource == LocalPlaybackEventSource.ratechange &&
      lastExplicitUserAction.kind == ExplicitUserActionKind.ratechange &&
      now - lastExplicitUserAction.at < gestureGraceMs) {
    return PlaybackSyncIntent.explicitRatechange;
  }

  const seekCarrierSources = {
    LocalPlaybackEventSource.seeking,
    LocalPlaybackEventSource.seeked,
    LocalPlaybackEventSource.play,
    LocalPlaybackEventSource.playing,
    LocalPlaybackEventSource.canplay,
    LocalPlaybackEventSource.timeupdate,
  };
  final seekGraceMs = gestureGraceMs > explicitSeekBroadcastGraceMs
      ? gestureGraceMs
      : explicitSeekBroadcastGraceMs;
  if (!seekCarrierSources.contains(eventSource) ||
      lastExplicitUserAction.kind != ExplicitUserActionKind.seek ||
      now - lastExplicitUserAction.at >= seekGraceMs) {
    return null;
  }
  return PlaybackSyncIntent.explicitSeek;
}

// ------------------------------------------------------------ 施加侧决策

sealed class PlaybackApplyDecision {
  const PlaybackApplyDecision();
}

final class ApplyEmptyRoom extends PlaybackApplyDecision {
  const ApplyEmptyRoom({required this.acceptedHydration});

  final bool acceptedHydration;
}

final class ApplyNoCurrentVideo extends PlaybackApplyDecision {
  const ApplyNoCurrentVideo();
}

final class ApplyIgnoreNonShared extends PlaybackApplyDecision {
  const ApplyIgnoreNonShared({
    required this.acceptedHydration,
    required this.shouldPauseNonSharedVideo,
  });

  final bool acceptedHydration;
  final bool shouldPauseNonSharedVideo;
}

final class ApplyIgnoreLocalGuard extends PlaybackApplyDecision {
  const ApplyIgnoreLocalGuard();
}

final class ApplyIgnoreStalePlayback extends PlaybackApplyDecision {
  const ApplyIgnoreStalePlayback();
}

final class ApplyIgnoreSelfPlaybackVersion extends PlaybackApplyDecision {
  const ApplyIgnoreSelfPlaybackVersion();
}

final class ApplyPlayback extends PlaybackApplyDecision {
  const ApplyPlayback({required this.isSelfPlayback, required this.playback});

  final bool isSelfPlayback;
  final PlaybackState playback;
}

/// playback-apply.ts: decidePlaybackApplication。
/// 简化:isConfirmedDifferentSharedVideo 的 festival 快照特判不适用,
/// 直接以规范化 URL 是否已知不同来判定(两 URL 均非空且不相等)。
PlaybackApplyDecision decidePlaybackApplication({
  required RoomState roomState,
  required BilibiliVideoRef? currentVideo,
  required String? normalizedCurrentUrl,
  required bool pendingRoomStateHydration,
  required String? explicitNonSharedPlaybackUrl,
  required num now,
  required num lastLocalIntentAt,
  required PlaybackPlayState? lastLocalIntentPlayState,
  required PlaybackVersion? lastAppliedVersion,
  required PlaybackVersion? lastLocalPlaybackVersion,
  required String? localMemberId,
  int intentGuardMs = localIntentGuardMs,
}) {
  final sharedVideo = roomState.sharedVideo;
  final playback = roomState.playback;
  if (sharedVideo == null || playback == null) {
    return ApplyEmptyRoom(acceptedHydration: pendingRoomStateHydration);
  }

  if (currentVideo == null) {
    return const ApplyNoCurrentVideo();
  }

  final normalizedSharedUrl = normalizeBilibiliUrl(sharedVideo.url);
  final normalizedPlaybackUrl = normalizeBilibiliUrl(playback.url);
  if (normalizedSharedUrl == null ||
      normalizedCurrentUrl != normalizedSharedUrl ||
      normalizedPlaybackUrl != normalizedSharedUrl) {
    final confirmedDifferent =
        normalizedCurrentUrl != null &&
        normalizedSharedUrl != null &&
        normalizedCurrentUrl != normalizedSharedUrl;
    final shouldPauseNonSharedVideo =
        pendingRoomStateHydration &&
        (playback.playState == PlaybackPlayState.paused ||
            playback.playState == PlaybackPlayState.buffering) &&
        !confirmedDifferent;
    return ApplyIgnoreNonShared(
      acceptedHydration: pendingRoomStateHydration,
      shouldPauseNonSharedVideo: shouldPauseNonSharedVideo,
    );
  }

  if (lastLocalIntentPlayState != null &&
      now - lastLocalIntentAt < intentGuardMs &&
      (lastLocalIntentPlayState == PlaybackPlayState.paused ||
          lastLocalIntentPlayState == PlaybackPlayState.buffering) &&
      playback.playState == PlaybackPlayState.playing) {
    return const ApplyIgnoreLocalGuard();
  }

  if (lastAppliedVersion != null &&
      (playback.serverTime < lastAppliedVersion.serverTime ||
          (playback.serverTime == lastAppliedVersion.serverTime &&
              playback.seq <= lastAppliedVersion.seq))) {
    return const ApplyIgnoreStalePlayback();
  }

  if (localMemberId != null &&
      playback.actorId == localMemberId &&
      lastLocalPlaybackVersion != null &&
      playback.seq <= lastLocalPlaybackVersion.seq) {
    return const ApplyIgnoreSelfPlaybackVersion();
  }

  return ApplyPlayback(
    isSelfPlayback: localMemberId != null && playback.actorId == localMemberId,
    playback: playback,
  );
}

// ------------------------------------------------------ 进度对齐档位决策

enum PlaybackReconcileMode { ignore, rateOnly, softApply, hardSeek }

/// playback-reconcile.ts 阈值常量
const double pausedHardSeekThresholdSeconds = 0.15;
const double playingIgnoreThresholdSeconds = 0.45;
const double playingRateOnlyThresholdSeconds = 0.9;
const double playingSoftApplyThresholdSeconds = 1.2;

typedef PlaybackReconcileDecision = ({
  PlaybackReconcileMode mode,
  double delta,
});

/// playback-reconcile.ts: decidePlaybackReconcileMode(含随倍速放宽的阈值)。
PlaybackReconcileDecision decidePlaybackReconcileMode({
  required double localCurrentTime,
  required double targetTime,
  required PlaybackPlayState playState,
  bool isExplicitSeek = false,
  double playbackRate = 1,
}) {
  final delta = (targetTime - localCurrentTime).abs();

  if (playState != PlaybackPlayState.playing) {
    return (
      mode: delta > pausedHardSeekThresholdSeconds
          ? PlaybackReconcileMode.hardSeek
          : PlaybackReconcileMode.ignore,
      delta: delta,
    );
  }

  if (isExplicitSeek) {
    return (mode: PlaybackReconcileMode.hardSeek, delta: delta);
  }

  final rateMultiplier = playbackRate > 1 ? playbackRate : 1;
  final extraRate = rateMultiplier - 1;
  final ignoreThreshold =
      playingIgnoreThresholdSeconds * (1 + extraRate * 0.35);
  final rateOnlyThreshold =
      playingRateOnlyThresholdSeconds * (1 + extraRate * 0.7);
  final softApplyThreshold =
      playingSoftApplyThresholdSeconds * (1 + extraRate * 0.55);

  return (
    mode: delta <= ignoreThreshold
        ? PlaybackReconcileMode.ignore
        : delta <= rateOnlyThreshold
        ? PlaybackReconcileMode.rateOnly
        : delta <= softApplyThreshold
        ? PlaybackReconcileMode.softApply
        : PlaybackReconcileMode.hardSeek,
    delta: delta,
  );
}

/// playback-reconcile.ts: shouldTreatAsExplicitSeek
bool shouldTreatAsExplicitSeek({
  required PlaybackSyncIntent? syncIntent,
  required PlaybackPlayState playState,
}) =>
    playState == PlaybackPlayState.playing &&
    syncIntent == PlaybackSyncIntent.explicitSeek;

// ------------------------------------------------------------ 视频身份

typedef _VideoIdParts = ({String base, int? cid, int? page});

_VideoIdParts _parseVideoId(String videoId) {
  final parts = videoId.split(':');
  final suffix = parts.length > 1 ? parts[1] : null;
  int? cid;
  int? page;
  if (suffix != null) {
    if (suffix.startsWith('p')) {
      page = int.tryParse(suffix.substring(1));
    } else {
      cid = int.tryParse(suffix);
    }
  }
  return (base: parts.first, cid: cid, page: page);
}

/// 两个协议 videoId(`BVxx[:cid|:pN]`、`epN`、`ssN` 等)是否可能指向
/// 同一视频。
///
/// 浏览器扩展的"当前视频身份"取自地址栏,导航到共享 URL 后与房间身份
/// 逐字相等;移动端身份由 bvid/cid 构造,与共享 URL 的形态(带不带
/// cid/分P)可能不同。比对必须宽容:同 bvid 且无法确认 cid/分P 不同时
/// 一律视为同一视频,否则会反复导航(video-identity.ts:
/// isConfirmedDifferentSharedVideo 的"confirmed"语义)。
/// `epN`/`ssN` 直接按 base 比较;`ssN` 与 `epX` 的归属关系无法从 id
/// 判定,由引擎结合本地 seasonId 另行采纳(见 _mayAdoptSharedIdentity)。
bool videoIdsMayReferToSameVideo(String a, String b) {
  final pa = _parseVideoId(a);
  final pb = _parseVideoId(b);
  if (pa.base != pb.base) {
    return false;
  }
  if (pa.cid != null && pb.cid != null && pa.cid != pb.cid) {
    return false;
  }
  if (pa.page != null && pb.page != null && pa.page != pb.page) {
    return false;
  }
  return true;
}

// ---------------------------------------------------------------- 引擎

/// 引擎对会话层的窄依赖(SyncPlayRoomSession 实现它)。
abstract interface class PlayerSyncSessionApi {
  String? get memberId;
  String? get roomCode;

  /// 对时得到的往返时延,拉长 softApply 超时用(未对时前为空)。
  double? get rttMs;
  bool get awaitingFreshRoomState;
  RoomState? get roomState;
  void sendPlaybackUpdate(PlaybackState playback);
  void shareVideo(SharedVideo video, {PlaybackState? playback});
}

/// 引擎对播放器的控制端口(App 层由 PlPlayerController + 路由实现)。
/// 引擎在程序化施加窗口内调用这些方法;期间回流的播放器事件由
/// [PlayerSyncEngine.isInProgrammaticApplyWindow] 判定为回声并抑制。
abstract interface class SyncPlayPlayerPort {
  Future<void> seekTo(double seconds);
  Future<void> play();
  Future<void> pause();
  Future<void> setRate(double rate);

  /// 切到共享视频(导航);[startPaused] 为真时目标页加载后不自动播。
  Future<void> openVideo(
    BilibiliVideoRef ref, {
    required double initialSeconds,
    required bool startPaused,
  });
}

/// 本地播放快照,App 桥接层随事件传入。
typedef LocalPlaybackSnapshot = ({
  double positionSeconds,
  PlaybackPlayState playState,
  double playbackRate,
});

class PlayerSyncEngine {
  PlayerSyncEngine({
    required this.session,
    required this.port,
    num Function()? nowMs,
    SyncPlayDelayScheduler? scheduleDelayed,
    this.log,
  }) : _nowMs = nowMs ?? (() => DateTime.now().millisecondsSinceEpoch),
       _scheduleDelayed = scheduleDelayed ?? _defaultDelayScheduler;

  final PlayerSyncSessionApi session;
  final SyncPlayPlayerPort port;
  final num Function() _nowMs;
  final SyncPlayDelayScheduler _scheduleDelayed;
  void Function(String message)? log;

  BilibiliVideoRef? currentVideo;
  String? currentTitle;

  /// 当前视频为番剧集时的所属 seasonId(用于采纳 `ssN` 形态的共享身份)。
  int? currentSeasonId;

  /// 进房/换视频后,首个权威 room:state 施加前为 true(hydration 窗口)。
  bool pendingRoomStateHydration = false;

  ExplicitUserAction? lastExplicitUserAction;

  /// 当前"应该处于"的播放状态(runtime-state.ts: intendedPlayState):
  /// 本地手势与远端施加都会写入。用于把 seek 途中的瞬时停顿改报 playing。
  PlaybackPlayState? intendedPlayState;
  num lastUserGestureAt = 0;
  num lastForcedPauseAt = 0;
  num _programmaticApplyUntil = 0;
  PlaybackPlayState? _programmaticApplyPlayState;

  /// 已下发但尚未在播放器上落地的程序化 seek 目标(秒)。非空期间
  /// 回声窗口一直有效,直到位置到位或 [_pendingProgrammaticSeekDeadline]。
  double? _pendingProgrammaticSeekTarget;
  num _pendingProgrammaticSeekDeadline = 0;

  /// 最近一次**我们下发过**的 seek 目标。到位后仍保留,让常规回声窗口
  /// 内回流的 seek 事件能被认出来;没有下发过 seek 时为 null。
  double? _programmaticSeekTarget;

  /// 登记中的本地显式操作(见 pending_local_override.dart)。
  PendingLocalOverride? _pendingLocalOverride;

  /// 去抖中、尚未施加的远端暂停(见 [remotePauseDebounceMs])。
  PlaybackState? _deferredRemotePause;
  void Function()? _cancelDeferredRemotePause;

  // ---- soft-apply 追平会话(soft_apply.dart 给出参数,这里是状态机) ----
  String? _softApplyUrl;
  double? _softApplyTargetTime;

  /// 会话开始前的基准倍速,结束时调回它。
  double? _softApplyRestoreRate;

  /// 我们实际写下去的追平倍速。恢复前要确认播放器上仍是这个值——
  /// 移动端的倍速变更目前不经过引擎(App 层没有 onLocalRateChanged 的
  /// 调用点),对不上就说明是用户或别处改的,不能覆盖。
  double? _softApplyAppliedRate;
  bool _softApplyArmCooldown = false;
  bool _softApplyConvergeByTime = false;
  num _softApplyDeadline = 0;
  void Function()? _cancelSoftApplyTimer;
  String? _softApplyCooldownUrl;
  num _softApplyCooldownUntil = 0;
  num _lastLocalIntentAt = 0;
  PlaybackPlayState? _lastLocalIntentPlayState;
  PlaybackVersion? _lastAppliedVersion;
  PlaybackVersion? _lastLocalPlaybackVersion;

  /// 用户明确选择在房间内播放的非共享视频 URL(不预授权,见 PR #140)。
  String? explicitNonSharedPlaybackUrl;

  /// 防重导航守卫(share-controller 的 lastOpenedSharedUrl 语义):
  /// 已为该共享 URL 发起过导航就不再重复,等目标页 onVideoLoaded。
  String? _lastOpenedSharedUrl;

  // ---- 连播判定标记(playback-binding-controller.ts:
  // markSharedVideoNaturalEnd;共享 URL 变化/离房/播放器销毁时清除) ----
  String? _sharedVideoNaturalEndUrl;
  num _sharedVideoNaturalEndAt = 0;

  /// 连播条件已满足但标题尚未就绪,等 [onTitleResolved] 补发分享。
  bool _pendingAutoShareOnTitle = false;

  /// 桥接层随位置回调持续写入的本地播放快照(施加时的对齐基准)。
  double? lastKnownPositionSeconds;
  double? lastKnownRate;

  num _lastBroadcastAt = 0;
  int _seq = 0;

  bool get isInProgrammaticApplyWindow {
    final now = _nowMs();
    if (now < _programmaticApplyUntil) {
      return true;
    }
    return _pendingProgrammaticSeekTarget != null &&
        now < _pendingProgrammaticSeekDeadline;
  }

  void _log(String message) => log?.call(message);

  static final RegExp _seasonVideoIdPattern = RegExp(r'^ss(\d+)$');

  /// 共享身份能否被本地视频采纳。`ssN`(浏览器在番剧季页分享)不含集数,
  /// 是不稳定身份(video-identity.ts: hasStableSharedVideoIdentity),
  /// 不能据以确认不同;本地已知所属 [currentSeasonId] 相符即采纳。
  bool _mayAdoptSharedIdentity(String localVideoId, String sharedVideoId) {
    if (videoIdsMayReferToSameVideo(localVideoId, sharedVideoId)) {
      return true;
    }
    final ssMatch = _seasonVideoIdPattern.firstMatch(sharedVideoId);
    if (ssMatch == null) {
      return false;
    }
    return currentSeasonId != null &&
        int.parse(ssMatch.group(1)!) == currentSeasonId;
  }

  // ------------------------------------------------------------ 本地事件

  /// 播放器加载了新视频(App 层在 setDataSource 完成时调用)。
  /// 番剧集传 [epId](可带 [seasonId]),身份用 `epN` 形态;
  /// 普通视频传 [bvid](可带 cid/page)。
  void onVideoLoaded({
    String? bvid,
    int? cid,
    int? page,
    int? epId,
    int? seasonId,
    String? title,
  }) {
    final ref = epId != null
        ? buildBilibiliEpisodeRef(epId: epId)
        : bvid != null
        ? buildBilibiliVideoRef(bvid: bvid, cid: cid, page: page)
        : null;
    if (ref == null) {
      _log('onVideoLoaded: unsupported video id ${bvid ?? 'ep$epId'}');
      return;
    }
    currentSeasonId = epId != null ? seasonId : null;
    // 换源:旧视频的 seek 目标与新视频的位置不可比,留着会误判到位
    _clearPendingProgrammaticSeek();
    _clearDeferredRemotePause();
    _cancelSoftApply('reset');
    _pendingLocalOverride = null;
    // 加载的视频与房间共享视频指向同一目标时,采纳房间身份
    // (URL/videoId 逐字对齐),施加/广播/导航判定即与其他端一致。
    final shared = session.roomState?.sharedVideo;
    final normalizedShared = shared == null
        ? null
        : normalizeBilibiliUrl(shared.url);
    if (shared != null &&
        normalizedShared != null &&
        _mayAdoptSharedIdentity(ref.videoId, shared.videoId)) {
      currentVideo = BilibiliVideoRef(
        videoId: shared.videoId,
        normalizedUrl: normalizedShared,
      );
      currentTitle = title ?? shared.title;
    } else {
      currentVideo = ref;
      currentTitle = title;
    }
    if (session.roomCode != null) {
      pendingRoomStateHydration = true;
      _maybeAutoShareAsSharer();
    }
    // 已经在共享视频上(自己就是分享者,或采纳了房间身份)就登记防重导航记录。
    // 只在导航路径里登记的话,从未导航过的一端(分享者)这个值一直是 null,
    // 之后手动打开别的视频时,下一个 room:state 会把共享视频重新压回栈顶。
    if (normalizedShared != null &&
        currentVideo?.normalizedUrl == normalizedShared) {
      _lastOpenedSharedUrl = normalizedShared;
    }
  }

  /// 播放器随视频页销毁(用户离开视频页回到非视频页面):清除本地
  /// 视频上下文,后续 room:state 的导航/施加判定不再被过期身份误导
  /// (过期身份会错误吸收采纳与"同一视频"判定,把新共享当成正在看)。
  /// 有意不清 [_lastOpenedSharedUrl]:与扩展端 tab-controller 一致,
  /// 用户主动离开共享视频后同一 URL 不再拉回,共享 URL 变化才重新导航。
  void onPlayerDetached() {
    currentVideo = null;
    currentTitle = null;
    currentSeasonId = null;
    pendingRoomStateHydration = false;
    // 播放器没了,等不到位置心跳确认到位,否则窗口会一直挂到超时
    _clearPendingProgrammaticSeek();
    _clearDeferredRemotePause();
    _cancelSoftApply('reset');
    _pendingLocalOverride = null;
    // 连播是同一播放器实例内换源;播放器销毁说明用户离开了视频页,
    // 之后打开的任何视频都是手动选片,不得自动分享
    _clearSharedVideoNaturalEnd();
  }

  /// 手动打开当前共享视频(房间面板入口,对应扩展端 popup 的
  /// openSharedVideoFromPopup):不受防重导航记录限制,无条件导航。
  Future<void> openSharedVideoManually() async {
    final state = session.roomState;
    final shared = state?.sharedVideo;
    if (shared == null) {
      return;
    }
    if (currentVideo != null && currentVideo!.videoId == shared.videoId) {
      // 已在共享视频页:拉一次权威状态对齐即可
      return;
    }
    final targetRef = parseBilibiliVideoRef(shared.url);
    if (targetRef == null) {
      return;
    }
    _lastOpenedSharedUrl = normalizeBilibiliUrl(shared.url);
    final playback = state?.playback;
    _log('Manually opening shared video ${targetRef.normalizedUrl}');
    pendingRoomStateHydration = true;
    await port.openVideo(
      targetRef,
      initialSeconds: playback?.currentTime ?? 0,
      startPaused:
          playback == null || playback.playState != PlaybackPlayState.playing,
    );
  }

  /// 用户手势(UI 层能确定是用户操作时调用,如控制条按钮)。
  void onUserGesture(ExplicitUserActionKind kind) {
    final now = _nowMs();
    lastUserGestureAt = now;
    lastExplicitUserAction = (kind: kind, at: now);
    if (kind == ExplicitUserActionKind.play ||
        kind == ExplicitUserActionKind.pause) {
      _lastLocalIntentAt = now;
      _lastLocalIntentPlayState = kind == ExplicitUserActionKind.play
          ? PlaybackPlayState.playing
          : PlaybackPlayState.paused;
      intendedPlayState = _lastLocalIntentPlayState;
      // 用户在非共享视频上明确点播:授权该 URL 本地播放
      if (kind == ExplicitUserActionKind.play) {
        final sharedUrl = _normalizedSharedUrl();
        final currentUrl = currentVideo?.normalizedUrl;
        if (sharedUrl != null &&
            currentUrl != null &&
            currentUrl != sharedUrl) {
          explicitNonSharedPlaybackUrl = currentUrl;
        }
      }
    }
  }

  /// 播放器状态变化(playing/paused/ended/buffering→映射后传入)。
  void onLocalPlayStateChanged(
    LocalPlaybackEventSource eventSource,
    LocalPlaybackSnapshot snapshot,
  ) {
    // 移动端专属:追平期间又开始缓冲就放弃追平。缓冲时本来就播不快,
    // 硬扛着加速会在恢复后冲过头(浏览器端没有这一档,seek 近乎瞬时)。
    if (eventSource == LocalPlaybackEventSource.waiting) {
      _cancelSoftApply('local-buffering');
    } else if (snapshot.playState == PlaybackPlayState.paused) {
      _cancelSoftApply('local-paused');
    }
    if (_shouldSuppressAsEcho(eventSource, snapshot.playState)) {
      return;
    }
    _broadcastPlayback(eventSource, snapshot);
  }

  /// 位置心跳(PlPlayer 的 positionListener,约 500ms 一次):
  /// 在播且距上次广播超过 2s 才补发(playback-binding-controller.ts)。
  void onLocalPosition(LocalPlaybackSnapshot snapshot) {
    _settleProgrammaticSeek(snapshot.positionSeconds);
    _maintainSoftApply(snapshot.positionSeconds);
    if (snapshot.playState != PlaybackPlayState.playing) {
      return;
    }
    // 施加尚未落地时位置还停在旧值,广播出去会被服务端当成一次新 seek
    if (isInProgrammaticApplyWindow) {
      return;
    }
    if (_nowMs() - _lastBroadcastAt <= timeupdateBroadcastMinIntervalMs) {
      return;
    }
    _broadcastPlayback(LocalPlaybackEventSource.timeupdate, snapshot);
  }

  /// 用户拖动进度条(App 层从 seek UI 或非程序化 seekTo 调用)。
  void onLocalSeek(LocalPlaybackSnapshot snapshot) {
    if (_shouldSuppressSeekAsEcho(snapshot.positionSeconds)) {
      return;
    }
    onUserGesture(ExplicitUserActionKind.seek);
    _broadcastPlayback(LocalPlaybackEventSource.seeked, snapshot);
  }

  void onLocalRateChanged(LocalPlaybackSnapshot snapshot) {
    if (isInProgrammaticApplyWindow) {
      return;
    }
    // 用户接管了倍速:放弃追平,且不要把基准倍速覆盖回去
    _cancelSoftApply('user-ratechange');
    onUserGesture(ExplicitUserActionKind.ratechange);
    _broadcastPlayback(LocalPlaybackEventSource.ratechange, snapshot);
  }

  /// 共享视频自然播完。记录自然结束标记:紧随其后加载的视频才算连播,
  /// 是自动分享的唯一入口(playback-binding-controller.ts:
  /// markSharedVideoNaturalEnd)。
  void onLocalEnded(LocalPlaybackSnapshot snapshot) {
    _markSharedVideoNaturalEnd();
    _broadcastPlayback(LocalPlaybackEventSource.ended, (
      positionSeconds: snapshot.positionSeconds,
      playState: PlaybackPlayState.paused,
      playbackRate: snapshot.playbackRate,
    ), naturalEnd: true);
  }

  void _markSharedVideoNaturalEnd() {
    final sharedUrl = _normalizedSharedUrl();
    // 播完的必须就是房间共享的那个视频
    if (session.roomCode == null ||
        sharedUrl == null ||
        currentVideo?.normalizedUrl != sharedUrl) {
      return;
    }
    _sharedVideoNaturalEndUrl = sharedUrl;
    _sharedVideoNaturalEndAt = _nowMs();
  }

  void _clearSharedVideoNaturalEnd() {
    _sharedVideoNaturalEndUrl = null;
    _sharedVideoNaturalEndAt = 0;
    _pendingAutoShareOnTitle = false;
  }

  /// 标题异步就绪(App 层取回视频标题后回调)。若连播自动分享因标题
  /// 未就绪而推迟,这里补发——否则房间里会显示成 videoId。
  void onTitleResolved(String title) {
    currentTitle = title;
    if (!_pendingAutoShareOnTitle) {
      return;
    }
    _pendingAutoShareOnTitle = false;
    // 连播条件在推迟时已判定通过,此处只补标题就绪后的分享
    if (session.awaitingFreshRoomState) {
      return;
    }
    shareCurrentVideo();
  }

  /// 位置心跳驱动的程序化 seek 到位判定:到位后收敛回常规回声窗口,
  /// 超时后放弃等待(seek 落空/换源等),避免无限抑制本地广播。
  void _settleProgrammaticSeek(double positionSeconds) {
    final target = _pendingProgrammaticSeekTarget;
    if (target == null) {
      return;
    }
    final now = _nowMs();
    if ((positionSeconds - target).abs() <=
        programmaticSeekSettleToleranceSeconds) {
      // 只清 pending:_programmaticSeekTarget 留给随后的常规回声窗口
      _pendingProgrammaticSeekTarget = null;
      // 到位瞬间仍会回流 playing/canplay 等事件,留常规窗口盖住
      _programmaticApplyUntil = now + programmaticApplyWindowMs;
      _log('Programmatic seek settled at ${positionSeconds.toStringAsFixed(2)}');
    } else if (now >= _pendingProgrammaticSeekDeadline) {
      _pendingProgrammaticSeekTarget = null;
      _log('Programmatic seek settle timed out at ${target.toStringAsFixed(2)}');
    }
  }

  void _clearPendingProgrammaticSeek() {
    _pendingProgrammaticSeekTarget = null;
    _pendingProgrammaticSeekDeadline = 0;
    _programmaticSeekTarget = null;
  }

  /// seek 回声判定。等待程序化 seek 落地期间用户又拖了进度条时,新位置
  /// 会明显偏离目标——那不是回声,放弃等待并按用户意图广播,否则用户的
  /// 拖动会被最长 [programmaticSeekSettleTimeoutMs] 的窗口吞掉。
  bool _shouldSuppressSeekAsEcho(double positionSeconds) {
    if (!isInProgrammaticApplyWindow) {
      return false;
    }
    final target = _programmaticSeekTarget;
    // 我们没下发过 seek,回流的 seek 就不可能是它的回声 —— 必须放行。
    // 回声窗口在每次远端施加后都会续 700ms,包括 ignore/rateOnly 这些
    // 根本不 seek 的档;稳态下房间状态约 2s 一拍,无条件吞掉的话用户
    // 拖进度条有很大概率被整条吃掉:手势不记录、广播不发出,之后的心跳
    // 带着已跳变的位置和空 syncIntent 发出去,对端只当成普通漂移慢慢追。
    if (target == null) {
      return false;
    }
    if ((positionSeconds - target).abs() >
        programmaticSeekSettleToleranceSeconds) {
      _clearPendingProgrammaticSeek();
      _programmaticApplyUntil = 0;
      return false;
    }
    return true;
  }

  bool _shouldSuppressAsEcho(
    LocalPlaybackEventSource eventSource,
    PlaybackPlayState playState,
  ) {
    if (!isInProgrammaticApplyWindow) {
      return false;
    }
    // 施加引起的缓冲不上报:此时位置还停在施加前的旧值,广播出去会让
    // 服务端按旧位置把房间打成 stop-like(authorityKind: "pause")
    if (eventSource == LocalPlaybackEventSource.waiting) {
      _log('Suppressed buffering echo while applying remote playback');
      return true;
    }
    // 程序化施加窗口内、与施加目标一致的状态回流是回声
    if (_programmaticApplyPlayState == playState) {
      _log('Suppressed echo $eventSource playState=${playState.wire}');
      return true;
    }
    return false;
  }

  // ------------------------------------------------------------ 广播

  void _broadcastPlayback(
    LocalPlaybackEventSource eventSource,
    LocalPlaybackSnapshot snapshot, {
    bool naturalEnd = false,
  }) {
    final video = currentVideo;
    final memberId = session.memberId;
    if (video == null || session.roomCode == null || memberId == null) {
      return;
    }
    final now = _nowMs();
    // 追平期间本地进度/倍速是故意调偏的,播出去会污染房间
    if (_shouldSuppressBroadcastDuringSoftApply()) {
      _log('Skip broadcast during soft-apply catch-up');
      return;
    }
    if (shouldSkipBroadcastWhileHydrating(
      pendingRoomStateHydration: pendingRoomStateHydration,
      now: now,
      lastUserGestureAt: lastUserGestureAt,
    )) {
      _log('Skip broadcast while waiting for initial room state');
      return;
    }

    final sharedUrl = _normalizedSharedUrl();
    if (shouldPauseForNonSharedBroadcast(
      activeRoomCode: session.roomCode,
      activeSharedUrl: sharedUrl,
      normalizedCurrentVideoUrl: video.normalizedUrl,
      explicitNonSharedPlaybackUrl: explicitNonSharedPlaybackUrl,
      playState: snapshot.playState,
      lastExplicitPlaybackAction: lastExplicitUserAction,
      now: now,
    )) {
      lastForcedPauseAt = now;
      _log('Force-pausing non-shared playback of ${video.normalizedUrl}');
      _forcePause();
      return;
    }
    // 非共享视频的状态不广播(房间状态只关于共享视频)
    if (sharedUrl != null && video.normalizedUrl != sharedUrl) {
      return;
    }

    final playState = broadcastPlayStateForSeek(
      eventSource: eventSource,
      playState: snapshot.playState,
      intendedPlayState: intendedPlayState,
      lastExplicitUserAction: lastExplicitUserAction,
      now: now,
    );
    final syncIntent = derivePlaybackSyncIntent(
      eventSource: eventSource,
      lastExplicitUserAction: lastExplicitUserAction,
      lastForcedPauseAt: lastForcedPauseAt,
      now: now,
    );
    final userInitiated = deriveUserInitiatedPause(
      eventSource: eventSource,
      playState: playState,
      lastExplicitUserAction: lastExplicitUserAction,
      lastForcedPauseAt: lastForcedPauseAt,
      programmaticApplyUntil: _programmaticApplyUntil,
      programmaticApplyPlayState: _programmaticApplyPlayState,
      now: now,
    );

    _seq += 1;
    final payload = PlaybackState(
      url: video.normalizedUrl,
      currentTime: snapshot.positionSeconds,
      playState: playState,
      syncIntent: syncIntent,
      userInitiated: userInitiated ? true : null,
      naturalEnd: naturalEnd ? true : null,
      playbackRate: snapshot.playbackRate,
      updatedAt: now,
      serverTime: 0,
      actorId: memberId,
      seq: _seq,
    );
    _lastBroadcastAt = now;
    _lastLocalPlaybackVersion = (serverTime: 0, seq: _seq);
    // 显式 seek/改倍速要挂守卫:本地落地前,房间里还在流转操作之前的状态
    final pending = rememberPendingLocalOverride(
      payload: payload,
      now: now,
      followsUserRatechange:
          lastExplicitUserAction != null &&
          lastExplicitUserAction!.kind == ExplicitUserActionKind.ratechange &&
          now - lastExplicitUserAction!.at < userGestureGraceMs,
    );
    if (pending != null) {
      _pendingLocalOverride = pending;
      _log('Pending local override ${pending.kind.name} seq=${pending.seq}');
    }
    session.sendPlaybackUpdate(payload);
  }

  void _forcePause() {
    port.pause().ignore();
  }

  // ------------------------------------------------------------ 施加

  /// 权威房间状态到达(桥接层把 session.onRoomState 接到这里,
  /// 传入的是时钟补偿后的状态)。
  Future<void> applyRoomState(RoomState state) async {
    final sharedVideo = state.sharedVideo;
    final normalizedSharedUrl = sharedVideo == null
        ? null
        : normalizeBilibiliUrl(sharedVideo.url);

    // 共享视频换了:上一个视频的自然结束标记作废,不能用来把之后的
    // 手动切页认成连播(room-state-controller.ts 的同名清理)
    if (_sharedVideoNaturalEndUrl != null &&
        _sharedVideoNaturalEndUrl != normalizedSharedUrl) {
      _clearSharedVideoNaturalEnd();
    }

    if (sharedVideo != null && normalizedSharedUrl != null) {
      final current = currentVideo;
      // 加载早于进房时错过了 onVideoLoaded 的身份采纳:补一次
      if (current != null &&
          current.videoId != sharedVideo.videoId &&
          _mayAdoptSharedIdentity(current.videoId, sharedVideo.videoId)) {
        currentVideo = BilibiliVideoRef(
          videoId: sharedVideo.videoId,
          normalizedUrl: normalizedSharedUrl,
        );
        currentTitle ??= sharedVideo.title;
      }
      // 确认是不同视频(或当前无视频)才导航;同一共享 URL 只发起一次,
      // 后续 room:state 等待目标页加载,防止导航循环堆叠页面。
      final needsNavigation =
          currentVideo == null ||
          (currentVideo!.videoId != sharedVideo.videoId &&
              currentVideo!.normalizedUrl != normalizedSharedUrl);
      if (needsNavigation) {
        if (_lastOpenedSharedUrl != normalizedSharedUrl) {
          final targetRef = parseBilibiliVideoRef(sharedVideo.url);
          if (targetRef != null) {
            _lastOpenedSharedUrl = normalizedSharedUrl;
            final playback = state.playback;
            _log('Opening shared video ${targetRef.normalizedUrl}');
            pendingRoomStateHydration = true;
            await port.openVideo(
              targetRef,
              initialSeconds: playback?.currentTime ?? 0,
              startPaused:
                  playback == null ||
                  playback.playState != PlaybackPlayState.playing,
            );
          }
        }
        return;
      }
    }

    final decision = decidePlaybackApplication(
      roomState: state,
      currentVideo: currentVideo,
      normalizedCurrentUrl: currentVideo?.normalizedUrl,
      pendingRoomStateHydration: pendingRoomStateHydration,
      explicitNonSharedPlaybackUrl: explicitNonSharedPlaybackUrl,
      now: _nowMs(),
      lastLocalIntentAt: _lastLocalIntentAt,
      lastLocalIntentPlayState: _lastLocalIntentPlayState,
      lastAppliedVersion: _lastAppliedVersion,
      lastLocalPlaybackVersion: _lastLocalPlaybackVersion,
      localMemberId: session.memberId,
    );

    switch (decision) {
      case ApplyEmptyRoom(:final acceptedHydration) ||
              ApplyIgnoreNonShared(:final acceptedHydration)
          when acceptedHydration:
        pendingRoomStateHydration = false;
      case ApplyEmptyRoom() || ApplyNoCurrentVideo():
        return;
      case ApplyIgnoreLocalGuard() ||
          ApplyIgnoreStalePlayback() ||
          ApplyIgnoreSelfPlaybackVersion():
        return;
      case ApplyIgnoreNonShared():
        break;
      case ApplyPlayback():
        break;
    }

    if (decision is ApplyIgnoreNonShared) {
      if (decision.shouldPauseNonSharedVideo) {
        lastForcedPauseAt = _nowMs();
        _log('Pausing non-shared video on hydration');
        await _applyProgrammatically(PlaybackPlayState.paused, () async {
          await port.pause();
        });
      }
      return;
    }

    if (decision is! ApplyPlayback) {
      return;
    }
    final playback = decision.playback;
    _lastAppliedVersion = (serverTime: playback.serverTime, seq: playback.seq);
    if (decision.isSelfPlayback) {
      // 自己的状态回流:只推进版本号,不施加
      pendingRoomStateHydration = false;
      return;
    }
    final overrideDecision = decidePendingLocalOverride(
      pending: _pendingLocalOverride,
      playback: playback,
      localMemberId: session.memberId,
      now: _nowMs(),
    );
    _pendingLocalOverride = overrideDecision.nextPending;
    if (overrideDecision.shouldIgnore) {
      // 本地显式操作尚未落地:此刻的远端状态是操作之前的,施加会把用户
      // 刚跳到的位置拽回去
      _log('Ignored remote playback: ${overrideDecision.reason}');
      pendingRoomStateHydration = false;
      return;
    }

    if (_shouldDeferRemotePause(playback)) {
      // hydration 有意保持 true 到延迟的快照真正施加为止
      // (room-state-apply-controller.ts 同一处的注释):否则这 250ms 里
      // 本地播放器的状态会绕过广播守卫播出去。跟随导航是强制 autoPlay 的,
      // 那正好会把房间的"暂停"翻成"播放"。
      _deferRemotePause(playback);
      return;
    }
    final hydrating = pendingRoomStateHydration;
    pendingRoomStateHydration = false;
    // 有更新的状态要施加:待施加的暂停已被取代,丢弃
    // (_lastAppliedVersion 已推进,更旧的状态在上面就被判 stale 了)
    _clearDeferredRemotePause();
    await _applyRemotePlayback(playback, hydrating: hydrating);
  }

  /// room-state-apply-controller.ts 的远端 pause 去抖判定。
  /// 只针对 paused:buffering 不再走暂停路径(见 [_applyRemotePlayback])。
  bool _shouldDeferRemotePause(PlaybackState playback) =>
      playback.playState == PlaybackPlayState.paused &&
      playback.userInitiated != true;

  void _deferRemotePause(PlaybackState playback) {
    _cancelDeferredRemotePause?.call();
    _deferredRemotePause = playback;
    _log('Deferred remote paused seq=${playback.seq} for ${remotePauseDebounceMs}ms');
    _cancelDeferredRemotePause = _scheduleDelayed(
      const Duration(milliseconds: remotePauseDebounceMs),
      () {
        _cancelDeferredRemotePause = null;
        final pending = _deferredRemotePause;
        _deferredRemotePause = null;
        if (pending == null) {
          return;
        }
        final wasHydrating = pendingRoomStateHydration;
        pendingRoomStateHydration = false;
        _applyRemotePlayback(pending, hydrating: wasHydrating).ignore();
      },
    );
  }

  void _clearDeferredRemotePause() {
    _cancelDeferredRemotePause?.call();
    _cancelDeferredRemotePause = null;
    _deferredRemotePause = null;
  }

  Future<void> _applyRemotePlayback(
    PlaybackState playback, {
    bool hydrating = false,
  }) async {
    if (playback.playState == PlaybackPlayState.buffering) {
      if (hydrating) {
        // 首个权威状态就是 buffering:房间还没真正开始播,本地必须停住。
        // 跟随导航是强制 autoPlay 的,这里不停就会一路播下去,而且
        // hydration 一清广播守卫就失效,本地的 playing 会翻掉房间状态。
        // 位置仍然不对齐(理由见下),只停播放。
        _log('Pausing on buffering initial room state');
        await _applyProgrammatically(
          PlaybackPlayState.paused,
          () => port.pause(),
        );
        return;
      }
      // 移动端专属:稳态下对端缓冲时,它的 currentTime 按定义是冻结的过期
      // 值,不是可用的对齐目标。而非 playing 状态的对齐阈值只有 0.15s,
      // 照做就会 seek 到那个冻结位置 —— 移动端一次 seek 就是一轮缓冲,本地
      // 随即广播自己的冻结位置,对端恢复后再把我们拽回去,两端锁死在同一
      // 小段反复重播。浏览器端 seek 近乎瞬时才承受得起这种对齐。
      //
      // 保持现状即可:对端缓冲结束会广播新的 playing 状态,那时再对齐。
      _log('Holding position: remote actor is buffering');
      return;
    }

    // v1 简化:施加时以远端快照的 currentTime 为目标,本地当前位置由
    // App 桥接层在调用前写入 lastKnownPosition。
    final localSeconds = lastKnownPositionSeconds ?? 0;
    final reconcile = decidePlaybackReconcileMode(
      localCurrentTime: localSeconds,
      targetTime: playback.currentTime,
      playState: playback.playState,
      isExplicitSeek: shouldTreatAsExplicitSeek(
        syncIntent: playback.syncIntent,
        playState: playback.playState,
      ),
      playbackRate: playback.playbackRate,
    );
    _log(
      'Reconcile mode=${reconcile.mode.name} '
      'delta=${reconcile.delta.toStringAsFixed(2)}',
    );

    // 追平会话进行中被冷却压制:刚追平完不再响应中间档,否则会立刻被
    // 下一拍重新触发(soft-apply-controller.ts: shouldSuppressByCooldown)
    if (_shouldSuppressByCooldown(playback, reconcile.mode)) {
      _log('Suppressed ${reconcile.mode.name} by soft-apply cooldown');
      return;
    }
    if (_cancelReasonForPlayback(playback) case final reason?) {
      _cancelSoftApply(reason);
    }

    // rateOnly 只动倍速;softApply 的进度修正是一小步(≤0.4s),不是跳帧
    final softApplied = reconcile.mode == PlaybackReconcileMode.softApply
        ? softApplySignature(
            localCurrentTime: localSeconds,
            targetTime: playback.currentTime,
            basePlaybackRate: playback.playbackRate,
          )
        : null;
    final catchUpRate = switch (reconcile.mode) {
      PlaybackReconcileMode.rateOnly => rateAdjustedPlaybackRate(
        localCurrentTime: localSeconds,
        targetTime: playback.currentTime,
        basePlaybackRate: playback.playbackRate,
      ),
      PlaybackReconcileMode.softApply => softApplied!.playbackRate,
      _ => playback.playbackRate,
    };

    intendedPlayState = playback.playState;
    final willSeek =
        reconcile.mode == PlaybackReconcileMode.softApply ||
        reconcile.mode == PlaybackReconcileMode.hardSeek;
    await _applyProgrammatically(playback.playState, () async {
      if (lastKnownRate != null &&
          (lastKnownRate! - catchUpRate).abs() > 0.001) {
        await port.setRate(catchUpRate);
      }
      switch (reconcile.mode) {
        case PlaybackReconcileMode.ignore:
          break;
        case PlaybackReconcileMode.rateOnly:
          // 只调速率(上面已写),不碰进度
          break;
        case PlaybackReconcileMode.softApply:
          await port.seekTo(softApplied!.currentTime);
        case PlaybackReconcileMode.hardSeek:
          await port.seekTo(playback.currentTime);
      }
      switch (playback.playState) {
        case PlaybackPlayState.playing:
          await port.play();
        case PlaybackPlayState.buffering:
          // 上面已提前返回,这里到不了
          break;
        case PlaybackPlayState.paused:
          await port.pause();
      }
    }, seekTarget: willSeek
        ? (softApplied?.currentTime ?? playback.currentTime)
        : null);

    // 中间两档要留一个会话:倍速被调高过,必须有东西负责把它调回去
    switch (reconcile.mode) {
      case PlaybackReconcileMode.rateOnly:
        _startSoftApply(
          playback: playback,
          basePlaybackRate: playback.playbackRate,
          isRealSoftApply: false,
          appliedRate: catchUpRate,
          // rateOnly 追不到快照目标(远端也在走),按相对漂移消化完计时恢复
          restoreDelayMs: relativeDriftCloseMs(
            driftSeconds: reconcile.delta,
            rateOffsetSeconds: catchUpRate - playback.playbackRate,
          ),
        );
      case PlaybackReconcileMode.softApply:
        _startSoftApply(
          playback: playback,
          basePlaybackRate: playback.playbackRate,
          isRealSoftApply: true,
          appliedRate: catchUpRate,
          restoreDelayMs: softApplyTimeoutMs(
            remainingDriftSeconds:
                (playback.currentTime - softApplied!.currentTime).abs(),
            rttMs: session.rttMs,
          ),
        );
      case PlaybackReconcileMode.ignore:
      case PlaybackReconcileMode.hardSeek:
        _cancelSoftApply('apply-${reconcile.mode.name}');
    }
  }

  // -------------------------------------------------- soft-apply 追平会话

  /// 开一个追平会话(soft-apply-controller.ts: upsertActiveSoftApply)。
  ///
  /// 同一视频上重复 upsert 会沿用最初的 [_softApplyRestoreRate]——中途的
  /// playback.playbackRate 已经是被我们调过的值,拿它当基准会越调越偏。
  /// [isRealSoftApply] 是 sticky 的:真 softApply 写过进度,收敛时要上冷却;
  /// 纯 rateOnly 不上冷却,否则会压制下一次真正需要的远端对齐。
  void _startSoftApply({
    required PlaybackState playback,
    required double basePlaybackRate,
    required bool isRealSoftApply,
    required double appliedRate,
    required int restoreDelayMs,
  }) {
    final url = normalizeBilibiliUrl(playback.url);
    if (url == null) {
      return;
    }
    final sameSession = _softApplyUrl == url;
    _cancelSoftApplyTimer?.call();
    _softApplyUrl = url;
    _softApplyTargetTime = playback.currentTime;
    _softApplyRestoreRate = sameSession
        ? _softApplyRestoreRate
        : basePlaybackRate;
    _softApplyArmCooldown = (sameSession && _softApplyArmCooldown) ||
        isRealSoftApply;
    // rateOnly 按经过时间恢复,softApply 按追到目标收敛(见 _maintainSoftApply)
    _softApplyConvergeByTime = !isRealSoftApply;
    _softApplyAppliedRate = appliedRate;
    _softApplyDeadline = _nowMs() + restoreDelayMs;
    _cancelSoftApplyTimer = _scheduleDelayed(
      Duration(milliseconds: restoreDelayMs),
      () {
        _cancelSoftApplyTimer = null;
        _cancelSoftApply(_softApplyConvergeByTime ? 'drift-closed' : 'timeout');
      },
    );
    _log(
      'Soft apply started url=$url '
      'target=${playback.currentTime.toStringAsFixed(2)} '
      'restoreRate=${_softApplyRestoreRate!.toStringAsFixed(2)} '
      'timeout=$restoreDelayMs cooldown=$_softApplyArmCooldown',
    );
  }

  bool get _hasActiveSoftApply => _softApplyUrl != null;

  /// 结束会话:把倍速调回基准,必要时上冷却
  /// (soft-apply-controller.ts: cancelActiveSoftApply)。
  void _cancelSoftApply(String reason) {
    if (!_hasActiveSoftApply) {
      return;
    }
    final url = _softApplyUrl!;
    final restoreRate = _softApplyRestoreRate;
    final appliedRate = _softApplyAppliedRate;
    final armCooldown = _softApplyArmCooldown;
    _cancelSoftApplyTimer?.call();
    _cancelSoftApplyTimer = null;
    _softApplyUrl = null;
    _softApplyTargetTime = null;
    _softApplyRestoreRate = null;
    _softApplyArmCooldown = false;
    _softApplyConvergeByTime = false;
    _softApplyAppliedRate = null;
    _softApplyDeadline = 0;

    // 只有播放器上仍是我们写下去的追平倍速时才恢复:对不上说明期间
    // 被用户改过,覆盖回去等于吞掉用户的操作
    final rateIsStillOurs =
        appliedRate != null &&
        lastKnownRate != null &&
        (lastKnownRate! - appliedRate).abs() <= 0.01;
    if (reason != 'user-ratechange' &&
        rateIsStillOurs &&
        restoreRate != null &&
        (lastKnownRate! - restoreRate).abs() > 0.01) {
      // 恢复动作本身会回流 ratechange,包进程序化窗口免得当成用户操作广播
      _applyProgrammatically(
        _programmaticApplyPlayState ?? PlaybackPlayState.playing,
        () => port.setRate(restoreRate),
      ).ignore();
    }
    if (armCooldown &&
        const {'converged', 'timeout', 'drift-closed'}.contains(reason)) {
      _softApplyCooldownUrl = url;
      _softApplyCooldownUntil = _nowMs() + softApplyCooldownMs;
    } else if (_softApplyCooldownUrl == url) {
      _softApplyCooldownUrl = null;
      _softApplyCooldownUntil = 0;
    }
    _log('Soft apply ended url=$url result=$reason');
  }

  /// 位置心跳驱动的收敛判定(soft-apply-controller.ts: maintainActiveSoftApply)。
  void _maintainSoftApply(double positionSeconds) {
    if (!_hasActiveSoftApply) {
      return;
    }
    if (_nowMs() >= _softApplyDeadline) {
      _cancelSoftApply(_softApplyConvergeByTime ? 'drift-closed' : 'timeout');
      return;
    }
    // rateOnly 会话永远追不到那个快照目标,只按时间恢复
    if (_softApplyConvergeByTime) {
      return;
    }
    if ((positionSeconds - _softApplyTargetTime!).abs() <=
        softApplyRecoveryThresholdSeconds) {
      _cancelSoftApply('converged');
    }
  }

  /// 远端状态是否让本次追平失去意义
  /// (soft-apply-controller.ts: shouldCancelActiveSoftApplyForPlayback)。
  String? _cancelReasonForPlayback(PlaybackState playback) {
    if (!_hasActiveSoftApply) {
      return null;
    }
    final url = normalizeBilibiliUrl(playback.url);
    if (url == null || url != _softApplyUrl) {
      return 'url-changed';
    }
    if (playback.playState != PlaybackPlayState.playing) {
      return 'play-state-changed';
    }
    if (shouldTreatAsExplicitSeek(
      syncIntent: playback.syncIntent,
      playState: playback.playState,
    )) {
      return 'explicit-seek';
    }
    if (_softApplyRestoreRate != null &&
        (playback.playbackRate - _softApplyRestoreRate!).abs() > 0.01) {
      return 'rate-changed';
    }
    if ((playback.currentTime - _softApplyTargetTime!).abs() >
        softApplyTargetShiftCancelThresholdSeconds) {
      return 'target-shifted';
    }
    return null;
  }

  /// 冷却期内压制中间档(soft-apply-controller.ts: shouldSuppressByCooldown)。
  bool _shouldSuppressByCooldown(
    PlaybackState playback,
    PlaybackReconcileMode mode,
  ) {
    if (_softApplyCooldownUntil <= _nowMs() || _softApplyCooldownUrl == null) {
      return false;
    }
    if (normalizeBilibiliUrl(playback.url) != _softApplyCooldownUrl ||
        playback.playState != PlaybackPlayState.playing ||
        playback.syncIntent != null) {
      return false;
    }
    return mode == PlaybackReconcileMode.rateOnly ||
        mode == PlaybackReconcileMode.softApply;
  }

  /// 追平期间不广播本地状态:此时进度和倍速都是我们故意调偏的,
  /// 播出去会污染房间(soft-apply-controller.ts:
  /// shouldSuppressActiveSoftApplyBroadcast)。用户刚有手势时不压制。
  bool _shouldSuppressBroadcastDuringSoftApply() {
    if (!_hasActiveSoftApply || _nowMs() >= _softApplyDeadline) {
      return false;
    }
    final action = lastExplicitUserAction;
    if (action != null && _nowMs() - action.at < userGestureGraceMs) {
      return false;
    }
    return true;
  }

  Future<void> _applyProgrammatically(
    PlaybackPlayState targetPlayState,
    Future<void> Function() apply, {
    double? seekTarget,
  }) async {
    _programmaticApplyPlayState = targetPlayState;
    _programmaticApplyUntil = _nowMs() + programmaticApplyWindowMs;
    // 施加期间不做到位判定:目标先记下,窗口在 apply 返回后才开始计时
    _clearPendingProgrammaticSeek();
    try {
      await apply();
    } finally {
      // 窗口按时间自然过期,保证施加动作触发的异步事件仍被覆盖
      final now = _nowMs();
      _programmaticApplyUntil = now + programmaticApplyWindowMs;
      if (seekTarget != null) {
        // seekTo() 返回不代表播放器已到位,继续等位置心跳确认
        _pendingProgrammaticSeekTarget = seekTarget;
        _pendingProgrammaticSeekDeadline = now + programmaticSeekSettleTimeoutMs;
        _programmaticSeekTarget = seekTarget;
      }
    }
  }

  // ------------------------------------------------------------ 分享

  String? _normalizedSharedUrl() {
    final url = session.roomState?.sharedVideo?.url;
    return url == null ? null : normalizeBilibiliUrl(url);
  }

  /// 手动分享当前视频。
  void shareCurrentVideo({LocalPlaybackSnapshot? snapshot}) {
    final video = currentVideo;
    final memberId = session.memberId;
    if (video == null || memberId == null) {
      return;
    }
    final shared = SharedVideo(
      videoId: video.videoId,
      url: video.normalizedUrl,
      title: currentTitle ?? video.videoId,
    );
    PlaybackState? playback;
    if (snapshot != null) {
      _seq += 1;
      playback = PlaybackState(
        url: video.normalizedUrl,
        currentTime: snapshot.positionSeconds,
        playState: snapshot.playState,
        playbackRate: snapshot.playbackRate,
        updatedAt: _nowMs(),
        serverTime: 0,
        actorId: memberId,
        seq: _seq,
      );
      _lastLocalPlaybackVersion = (serverTime: 0, seq: _seq);
    }
    // 分享者本来就在这个视频上,同样要登记,否则之后切走会被拉回来
    _lastOpenedSharedUrl = video.normalizedUrl;
    _log('Sharing ${video.normalizedUrl}');
    session.shareVideo(shared, playback: playback);
  }

  /// 离房/会话被服务端终结时清理房间相关的本地判定状态。
  void resetRoomLocalState() {
    _lastOpenedSharedUrl = null;
    pendingRoomStateHydration = false;
    _clearPendingProgrammaticSeek();
    _clearDeferredRemotePause();
    _cancelSoftApply('reset');
    _pendingLocalOverride = null;
    explicitNonSharedPlaybackUrl = null;
    _lastAppliedVersion = null;
    _lastLocalPlaybackVersion = null;
    _clearSharedVideoNaturalEnd();
  }

  /// 共享者的**连播**自动跟进分享(navigation-controller.ts:
  /// shouldTreatAsAutoplay && isLocalSharedSource)。
  ///
  /// 手动切视频一律不自动分享——扩展端任何 genuine navigation 都会
  /// cancelAutoShareNextVideo,只有从共享视频自然播完接上的下一个视频
  /// 才调度。awaitingFreshRoomState 窗口内推迟,避免用过期快照断言
  /// 共享者身份(见 runtime-state.ts 注释)。
  void _maybeAutoShareAsSharer() {
    if (session.awaitingFreshRoomState) {
      return;
    }
    final sharerId = session.roomState?.sharedVideo?.sharedByMemberId;
    final memberId = session.memberId;
    if (sharerId == null || memberId == null || sharerId != memberId) {
      return;
    }
    final sharedUrl = _normalizedSharedUrl();
    if (sharedUrl == null || currentVideo?.normalizedUrl == sharedUrl) {
      return;
    }
    if (!_isAutoplayContinuationFrom(sharedUrl)) {
      _log('Skip auto-share: not an autoplay continuation of $sharedUrl');
      return;
    }
    // 标题随视频详情异步到达,早于它分享会把 videoId 当标题发给房间
    if (currentTitle == null) {
      _log('Deferring auto-share until the title resolves');
      _pendingAutoShareOnTitle = true;
      return;
    }
    shareCurrentVideo();
  }

  /// 本次视频加载是否接在共享视频的自然播完之后(即连播)。
  bool _isAutoplayContinuationFrom(String previousSharedUrl) {
    if (_sharedVideoNaturalEndUrl != previousSharedUrl) {
      return false;
    }
    if (_nowMs() - _sharedVideoNaturalEndAt >= autoplayContinuationWindowMs) {
      return false;
    }
    // 播完后用户又操作了播放器 = 手动选片,不是连播
    // (拖到末尾触发的结束,其 seek 手势早于结束时刻,不受此门阻断)
    return lastUserGestureAt <= _sharedVideoNaturalEndAt;
  }
}
