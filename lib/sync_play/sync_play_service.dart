import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/http/video.dart';
import 'package:PiliPlus/models/common/video/video_type.dart';
import 'package:PiliPlus/plugin/pl_player/controller.dart';
import 'package:PiliPlus/plugin/pl_player/models/play_status.dart';
import 'package:PiliPlus/sync_play/piliplus_player_port.dart';
import 'package:PiliPlus/utils/storage.dart';
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
      displayName: displayName.isEmpty ? null : displayName,
      onChanged: _onSessionChanged,
      onRoomState: (state) => engine.applyRoomState(state),
      onSessionEnded: (reason) => SmartDialog.showToast('一起看会话已结束:$reason'),
      onServerError: (error) => SmartDialog.showToast('一起看:${error.message}'),
      log: _debugLog,
    );
    engine = PlayerSyncEngine(session: session, port: port, log: _debugLog);
    PlPlayerController.syncPlayDataSourceListeners.add(_onDataSource);
    PlPlayerController.syncPlaySeekListeners.add(_onSeek);
    PlPlayerController.syncPlayUserToggleListeners.add(_onUserToggle);
  }

  static SyncPlayService? _instance;
  static SyncPlayService get to => _instance ??= SyncPlayService._();

  static const String _keyServerUrl = 'syncPlayServerUrl';
  static const String _keyDisplayName = 'syncPlayDisplayName';

  late final SyncPlayRoomSession session;
  late final PlayerSyncEngine engine;
  final PiliPlusPlayerPort port = PiliPlusPlayerPort();

  final Map<String, String> _titleCache = {};
  bool _playerAttached = false;

  bool get inRoom => session.roomCode != null;

  String get serverUrl =>
      GStorage.setting.get(_keyServerUrl, defaultValue: '') as String;

  String get displayName =>
      GStorage.setting.get(_keyDisplayName, defaultValue: '') as String;

  void setServerUrl(String value) {
    final trimmed = value.trim();
    GStorage.setting.put(_keyServerUrl, trimmed);
    session.serverUrl = trimmed;
    notifyListeners();
  }

  void setDisplayName(String value) {
    final trimmed = value.trim();
    GStorage.setting.put(_keyDisplayName, trimmed);
    if (trimmed.isNotEmpty) {
      session.updateDisplayName(trimmed);
    }
    notifyListeners();
  }

  void _debugLog(String message) {
    if (kDebugMode) {
      debugPrint('[sync_play] $message');
    }
  }

  void _onSessionChanged() {
    // 进房成功后把正在播的视频挂进引擎(创建/加入时通常已在视频页)
    if (inRoom && !_playerAttached) {
      final player = PlPlayerController.instance;
      if (player != null && player.videoType == VideoType.ugc) {
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
    // v1 边界:仅普通视频参与同步(直播/番剧/课堂不挂)
    if (player.isLive || player.videoType != VideoType.ugc) {
      return;
    }
    final bvid = player.bvid;
    final cid = player.cid;
    if (bvid == null || cid == null) {
      return;
    }
    // 播放器实例可能是新建的:重新挂实例级监听(Set 幂等)
    player.addPositionListener(_onPosition);
    player.addStatusLister(_onStatus);
    _playerAttached = true;

    engine.onVideoLoaded(bvid: bvid, cid: cid, title: _titleCache[bvid]);
    if (_titleCache[bvid] == null) {
      _fetchTitle(bvid);
    }
    // 拉一次权威房间状态:处理跟随切页后的进度/暂停施加
    session.requestSync();
  }

  Future<void> _fetchTitle(String bvid) async {
    final res = await VideoHttp.videoIntro(bvid: bvid);
    if (res case Success(:final response)) {
      final title = response.title;
      if (title != null) {
        _titleCache[bvid] = title;
        if (engine.currentVideo?.videoId.startsWith(bvid) ?? false) {
          engine.currentTitle = title;
        }
      }
    }
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
      ..displayName = displayName.isEmpty ? null : displayName;
    await session.requestCreateRoom();
  }

  Future<JoinAttemptResult> joinRoom(String roomCode, String joinToken) async {
    session
      ..serverUrl = serverUrl
      ..displayName = displayName.isEmpty ? null : displayName;
    final result = session.waitForJoinAttemptResult();
    await session.requestJoinRoom(roomCode, joinToken);
    return result;
  }

  void leaveRoom() {
    final player = PlPlayerController.instance;
    player?.removePositionListener(_onPosition);
    player?.removeStatusLister(_onStatus);
    _playerAttached = false;
    session.requestLeaveRoom();
  }

  void shareCurrentVideo() {
    if (engine.currentVideo == null) {
      final player = PlPlayerController.instance;
      if (player != null && player.videoType == VideoType.ugc) {
        _onDataSource(player);
      }
    }
    if (engine.currentVideo == null) {
      SmartDialog.showToast('一起看:当前没有可分享的视频');
      return;
    }
    engine.shareCurrentVideo(snapshot: _snapshot());
    SmartDialog.showToast('已分享当前视频');
  }
}
