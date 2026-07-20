/// 播放器同步引擎:远端状态施加与本地播放广播的决策核心,移植自
/// Bili-SyncPlay 扩展 content 侧的纯决策函数
/// (playback-apply.ts / playback-reconcile.ts / playback-broadcast.ts)
/// 与 sync-controller.ts 的关键守卫窗口。
///
/// v1 相对浏览器端的显式简化(涉及行为差异的都在此声明):
/// - 无 soft-apply 速率追赶(soft-apply-controller.ts 430 行):reconcile 的
///   `rateOnly` 档按 ignore 处理(0.45–0.9s 漂移容忍,等下一拍),
///   `softApply` 档按 hardSeek 处理;
/// - 无远端 pause 防闪抖 debounce(REMOTE_PAUSE_DEBOUNCE_MS):直接施加;
/// - 无 buffer-pause 升级分类:宿主播放器(PlPlayer)有独立 buffering 信号;
/// - 无 festival/watchlater 特例:App 内路由不存在该形态。
library;

import 'common.dart';
import 'models.dart';
import 'video_ref.dart';

// ---- 时间窗口常量(extension/src/content/index.ts) ----
const int localIntentGuardMs = 1200;
const int programmaticApplyWindowMs = 700;
const int userGestureGraceMs = 1200;

/// playback-broadcast.ts: EXPLICIT_SEEK_BROADCAST_GRACE_MS
const int explicitSeekBroadcastGraceMs = 2500;

/// playback-binding-controller.ts onTimeUpdate:在播时距上次广播
/// 超过该值才随 timeupdate 补发周期心跳。
const int timeupdateBroadcastMinIntervalMs = 2000;

/// 共享视频自然播完后,多久之内加载的新视频才算"连播"
/// (extension/src/content/index.ts: INITIAL_ROOM_STATE_PAUSE_HOLD_MS)。
const int autoplayContinuationWindowMs = 3000;

/// 本地播放事件来源(runtime-state.ts: LocalPlaybackEventSource 的移动端子集)。
enum LocalPlaybackEventSource {
  play,
  playing,
  pause,
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
    this.log,
  }) : _nowMs = nowMs ?? (() => DateTime.now().millisecondsSinceEpoch);

  final PlayerSyncSessionApi session;
  final SyncPlayPlayerPort port;
  final num Function() _nowMs;
  void Function(String message)? log;

  BilibiliVideoRef? currentVideo;
  String? currentTitle;

  /// 当前视频为番剧集时的所属 seasonId(用于采纳 `ssN` 形态的共享身份)。
  int? currentSeasonId;

  /// 进房/换视频后,首个权威 room:state 施加前为 true(hydration 窗口)。
  bool pendingRoomStateHydration = false;

  ExplicitUserAction? lastExplicitUserAction;
  num lastUserGestureAt = 0;
  num lastForcedPauseAt = 0;
  num _programmaticApplyUntil = 0;
  PlaybackPlayState? _programmaticApplyPlayState;
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

  bool get isInProgrammaticApplyWindow => _nowMs() < _programmaticApplyUntil;

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
    if (_shouldSuppressAsEcho(eventSource, snapshot.playState)) {
      return;
    }
    _broadcastPlayback(eventSource, snapshot);
  }

  /// 位置心跳(PlPlayer 的 positionListener,约 500ms 一次):
  /// 在播且距上次广播超过 2s 才补发(playback-binding-controller.ts)。
  void onLocalPosition(LocalPlaybackSnapshot snapshot) {
    if (snapshot.playState != PlaybackPlayState.playing) {
      return;
    }
    if (_nowMs() - _lastBroadcastAt <= timeupdateBroadcastMinIntervalMs) {
      return;
    }
    _broadcastPlayback(LocalPlaybackEventSource.timeupdate, snapshot);
  }

  /// 用户拖动进度条(App 层从 seek UI 或非程序化 seekTo 调用)。
  void onLocalSeek(LocalPlaybackSnapshot snapshot) {
    if (isInProgrammaticApplyWindow) {
      return;
    }
    onUserGesture(ExplicitUserActionKind.seek);
    _broadcastPlayback(LocalPlaybackEventSource.seeked, snapshot);
  }

  void onLocalRateChanged(LocalPlaybackSnapshot snapshot) {
    if (isInProgrammaticApplyWindow) {
      return;
    }
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

  bool _shouldSuppressAsEcho(
    LocalPlaybackEventSource eventSource,
    PlaybackPlayState playState,
  ) {
    if (!isInProgrammaticApplyWindow) {
      return false;
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

    final syncIntent = derivePlaybackSyncIntent(
      eventSource: eventSource,
      lastExplicitUserAction: lastExplicitUserAction,
      lastForcedPauseAt: lastForcedPauseAt,
      now: now,
    );
    final userInitiated = deriveUserInitiatedPause(
      eventSource: eventSource,
      playState: snapshot.playState,
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
      playState: snapshot.playState,
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
    pendingRoomStateHydration = false;
    final playback = decision.playback;
    _lastAppliedVersion = (serverTime: playback.serverTime, seq: playback.seq);
    if (decision.isSelfPlayback) {
      // 自己的状态回流:只推进版本号,不施加
      return;
    }
    await _applyRemotePlayback(playback);
  }

  Future<void> _applyRemotePlayback(PlaybackState playback) async {
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

    await _applyProgrammatically(playback.playState, () async {
      if (lastKnownRate != null &&
          (lastKnownRate! - playback.playbackRate).abs() > 0.001) {
        await port.setRate(playback.playbackRate);
      }
      switch (reconcile.mode) {
        case PlaybackReconcileMode.ignore:
        case PlaybackReconcileMode.rateOnly:
          // v1:rateOnly 档漂移(0.45–0.9s)容忍,等下一拍收敛
          break;
        case PlaybackReconcileMode.softApply:
        case PlaybackReconcileMode.hardSeek:
          await port.seekTo(playback.currentTime);
      }
      switch (playback.playState) {
        case PlaybackPlayState.playing:
          await port.play();
        case PlaybackPlayState.paused:
        case PlaybackPlayState.buffering:
          await port.pause();
      }
    });
  }

  Future<void> _applyProgrammatically(
    PlaybackPlayState targetPlayState,
    Future<void> Function() apply,
  ) async {
    _programmaticApplyPlayState = targetPlayState;
    _programmaticApplyUntil = _nowMs() + programmaticApplyWindowMs;
    try {
      await apply();
    } finally {
      // 窗口按时间自然过期,保证施加动作触发的异步事件仍被覆盖
      _programmaticApplyUntil = _nowMs() + programmaticApplyWindowMs;
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
    _log('Sharing ${video.normalizedUrl}');
    session.shareVideo(shared, playback: playback);
  }

  /// 离房/会话被服务端终结时清理房间相关的本地判定状态。
  void resetRoomLocalState() {
    _lastOpenedSharedUrl = null;
    pendingRoomStateHydration = false;
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
