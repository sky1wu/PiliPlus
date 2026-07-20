import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/http/video.dart';
import 'package:PiliPlus/models/common/video/video_type.dart';
import 'package:PiliPlus/plugin/pl_player/controller.dart';
import 'package:PiliPlus/plugin/pl_player/models/play_status.dart';
import 'package:PiliPlus/sync_play/piliplus_player_port.dart';
import 'package:PiliPlus/sync_play/sync_play_messages.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:sync_play_core/sync_play_core.dart';

/// Bili-SyncPlay 全局服务:持有会话与同步引擎,负责把 PlPlayer 的
/// 事件桥接进引擎、把引擎的施加动作发回播放器。
///
/// 生命周期:惰性单例,首次访问(播放器同步按钮/service_locator)时初始化;
/// 对 PlPlayerController 的静态钩子只注册一次,实例级 position/status
/// 监听在每次 dataSource 变化时重新挂载(播放器实例随页面销毁重建)。
class SyncPlayService extends ChangeNotifier {
  SyncPlayService._() {
    session = SyncPlayRoomSession(
      serverUrl: serverUrl,
      displayName: _accountDisplayName,
      onChanged: _onSessionChanged,
      onRoomState: _onRoomState,
      onSessionEnded: (reason) {
        engine.resetRoomLocalState();
        _resetToastState();
        SmartDialog.showToast(
          SyncPlayMessages.localizeSessionEndReason(reason),
        );
      },
      onServerError: (error) => SmartDialog.showToast(
        SyncPlayMessages.localizeServerError(error.code, error.message),
      ),
      log: _debugLog,
    );
    engine = PlayerSyncEngine(session: session, port: port, log: _debugLog);
    PlPlayerController.syncPlayDataSourceListeners.add(_onDataSource);
    PlPlayerController.syncPlaySeekListeners.add(_onSeek);
    PlPlayerController.syncPlayUserToggleListeners.add(_onUserToggle);
    PlPlayerController.syncPlayPlayerDisposeListeners.add(_onPlayerDisposed);
  }

  static SyncPlayService? _instance;
  static SyncPlayService get to => _instance ??= SyncPlayService._();

  static const String _keyServerUrl = 'syncPlayServerUrl';

  late final SyncPlayRoomSession session;
  late final PlayerSyncEngine engine;
  final PiliPlusPlayerPort port = PiliPlusPlayerPort();

  final Map<String, String> _titleCache = {};
  bool _playerAttached = false;

  // 房间事件 toast 的 diff 基线(对应扩展端 ToastCoordinatorState)
  RoomState? _lastToastRoomState;
  Map<String, num> _lastSeekToastByActor = {};

  bool get inRoom => session.roomCode != null;

  String get serverUrl =>
      GStorage.setting.get(_keyServerUrl, defaultValue: '') as String;

  /// 昵称与浏览器扩展一致(content/user-reporter.ts):登录用 B 站昵称,
  /// 空则 UID-{mid};未登录返回 null(不传 displayName),由服务端分配
  /// Guest-xxx(server: ws-session-handler.ts)。不提供用户输入。
  String? get _accountDisplayName {
    final info = Pref.userInfoCache;
    final uname = info?.uname?.trim();
    if (uname != null && uname.isNotEmpty) {
      return uname;
    }
    final mid = info?.mid;
    return mid == null ? null : 'UID-$mid';
  }

  void setServerUrl(String value) {
    final trimmed = value.trim();
    GStorage.setting.put(_keyServerUrl, trimmed);
    session.serverUrl = trimmed;
    notifyListeners();
  }

  void _debugLog(String message) {
    if (kDebugMode) {
      debugPrint('[sync_play] $message');
    }
  }

  /// 权威房间状态:先按施加前的引擎状态算出 toast 事件
  /// (hydration/当前视频判定要用施加前的快照),施加后再弹出。
  void _onRoomState(RoomState state) {
    final sharedVideo = state.sharedVideo;
    final normalizedSharedUrl = sharedVideo == null
        ? null
        : normalizeBilibiliUrl(sharedVideo.url);
    final plan = buildRoomStateToastPlan(
      previousState: _lastToastRoomState,
      nextState: state,
      localMemberId: session.memberId,
      pendingRoomStateHydration: engine.pendingRoomStateHydration,
      isCurrentPageShowingSharedVideo:
          normalizedSharedUrl != null &&
          engine.currentVideo?.normalizedUrl == normalizedSharedUrl,
      now: DateTime.now().millisecondsSinceEpoch,
      lastSeekToastByActor: _lastSeekToastByActor,
    );
    _lastToastRoomState = state;
    _lastSeekToastByActor = plan.nextSeekToastByActor;

    engine.applyRoomState(state);

    for (final event in plan.events) {
      SmartDialog.showToast(SyncPlayMessages.localizeRoomToast(event));
    }
  }

  void _resetToastState() {
    _lastToastRoomState = null;
    _lastSeekToastByActor = {};
  }

  /// v1 边界:普通视频与番剧参与同步(直播/课堂不挂)。
  static bool _isSyncableVideo(PlPlayerController player) =>
      !player.isLive &&
      (player.videoType == VideoType.ugc || player.videoType == VideoType.pgc);

  void _onSessionChanged() {
    // 进房成功后把正在播的视频挂进引擎(创建/加入时通常已在视频页)
    if (inRoom && !_playerAttached) {
      final player = PlPlayerController.instance;
      if (player != null && _isSyncableVideo(player)) {
        _onDataSource(player);
      }
    }
    if (!inRoom) {
      _playerAttached = false;
    }
    notifyListeners();
  }

  // ------------------------------------------------------ 播放器事件桥接

  void _onDataSource(PlPlayerController player) {
    if (!inRoom) {
      return;
    }
    if (!_isSyncableVideo(player)) {
      return;
    }
    final bvid = player.bvidOrNull;
    final cid = player.cid;
    final isPgc = player.videoType == VideoType.pgc;
    final epid = player.epidOrNull;
    if (isPgc ? epid == null : (bvid == null || cid == null)) {
      return;
    }
    // 播放器实例可能是新建的:重新挂实例级监听(Set 幂等)
    player
      ..addPositionListener(_onPosition)
      ..addStatusLister(_onStatus);
    _playerAttached = true;

    engine.onVideoLoaded(
      bvid: bvid,
      cid: cid,
      epId: isPgc ? epid : null,
      seasonId: isPgc ? player.seasonIdOrNull : null,
      title: bvid == null ? null : _titleCache[bvid],
    );
    // 番剧集的 bvid 同样能换取集标题(x/web-interface/view 支持)
    if (bvid != null && _titleCache[bvid] == null) {
      _fetchTitle(bvid);
    }
    // 拉一次权威房间状态:处理跟随切页后的进度/暂停施加
    session.requestSync();
  }

  Future<void> _fetchTitle(String bvid) async {
    final videoId = engine.currentVideo?.videoId;
    final res = await VideoHttp.videoIntro(bvid: bvid);
    if (res case Success(:final response)) {
      final title = response.title;
      if (title != null) {
        _titleCache[bvid] = title;
        // 期间可能已切页:仅当仍是发起时的视频才回写标题
        if (videoId != null && engine.currentVideo?.videoId == videoId) {
          // 引擎可能在等标题补发连播分享,走 onTitleResolved
          engine.onTitleResolved(title);
        }
      }
    }
  }

  /// 分享前确保标题就绪:标题随视频详情异步到达,刚进页面就点分享时
  /// 可能还没到,直接分享会把 videoId 当标题发给房间。
  Future<void> _ensureTitle() async {
    if (engine.currentTitle != null) {
      return;
    }
    final bvid = PlPlayerController.instance?.bvidOrNull;
    if (bvid == null) {
      return;
    }
    final cached = _titleCache[bvid];
    if (cached != null) {
      engine.currentTitle = cached;
      return;
    }
    await _fetchTitle(bvid);
  }

  LocalPlaybackSnapshot _snapshot({double? positionSeconds}) {
    final player = PlPlayerController.instance;
    final status = player?.playerStatus.value ?? PlayerStatus.paused;
    return (
      positionSeconds:
          positionSeconds ??
          (player == null ? 0 : player.positionInMilliseconds / 1000),
      playState: status == PlayerStatus.playing
          ? PlaybackPlayState.playing
          : PlaybackPlayState.paused,
      playbackRate: player?.playbackSpeed ?? 1,
    );
  }

  void _onPosition(Duration position) {
    if (!inRoom) {
      return;
    }
    final seconds = position.inMilliseconds / 1000;
    engine.lastKnownPositionSeconds = seconds;
    engine.lastKnownRate = PlPlayerController.instance?.playbackSpeed;
    engine.onLocalPosition(_snapshot(positionSeconds: seconds));
  }

  void _onStatus(PlayerStatus status) {
    if (!inRoom) {
      return;
    }
    switch (status) {
      case PlayerStatus.playing:
        engine.onLocalPlayStateChanged(
          LocalPlaybackEventSource.playing,
          _snapshot(),
        );
      case PlayerStatus.paused:
        engine.onLocalPlayStateChanged(
          LocalPlaybackEventSource.pause,
          _snapshot(),
        );
      case PlayerStatus.completed:
        engine.onLocalEnded(_snapshot());
    }
  }

  void _onSeek(PlPlayerController player, Duration position) {
    if (!inRoom) {
      return;
    }
    // 引擎在程序化施加窗口内会忽略这次 seek(施加回声)
    engine.onLocalSeek(
      _snapshot(positionSeconds: position.inMilliseconds / 1000),
    );
  }

  /// 播放器随视频页销毁(回到首页等非视频页面):清引擎的视频上下文,
  /// 后续收到新共享 URL 时才能正确触发跟随导航。
  void _onPlayerDisposed() {
    _playerAttached = false;
    engine.onPlayerDetached();
  }

  void _onUserToggle(PlPlayerController player) {
    if (!inRoom) {
      return;
    }
    // 统一手势入口(播放/暂停按钮、双击):切换意图与当前状态相反
    engine.onUserGesture(
      player.playerStatus.value.isPlaying
          ? ExplicitUserActionKind.pause
          : ExplicitUserActionKind.play,
    );
  }

  // ------------------------------------------------------------ UI 动作

  Future<void> createRoom() async {
    session
      ..serverUrl = serverUrl
      ..displayName = _accountDisplayName;
    await session.requestCreateRoom();
  }

  Future<JoinAttemptResult> joinRoom(String roomCode, String joinToken) async {
    session
      ..serverUrl = serverUrl
      ..displayName = _accountDisplayName;
    final result = session.waitForJoinAttemptResult();
    await session.requestJoinRoom(roomCode, joinToken);
    return result;
  }

  void leaveRoom() {
    final player = PlPlayerController.instance;
    player?.removePositionListener(_onPosition);
    player?.removeStatusLister(_onStatus);
    _playerAttached = false;
    engine.resetRoomLocalState();
    _resetToastState();
    session.requestLeaveRoom();
  }

  /// 手动打开当前共享视频(房间面板点击共享视频条目)。
  void openSharedVideo() {
    engine.openSharedVideoManually();
  }

  Future<void> shareCurrentVideo() async {
    if (engine.currentVideo == null) {
      final player = PlPlayerController.instance;
      if (player != null && _isSyncableVideo(player)) {
        _onDataSource(player);
      }
    }
    if (engine.currentVideo == null) {
      SmartDialog.showToast('当前页面没有可播放的视频。');
      return;
    }
    await _ensureTitle();
    if (engine.currentVideo == null) {
      // 等标题期间用户已离开视频页
      return;
    }
    engine.shareCurrentVideo(snapshot: _snapshot());
    SmartDialog.showToast(SyncPlayMessages.pageShareSuccess);
  }
}
