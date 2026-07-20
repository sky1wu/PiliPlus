/// 房间会话状态机 + 连接管理,移植自 Bili-SyncPlay 浏览器扩展的
/// socket-controller.ts / room-session-controller.ts / socket-manager.ts。
///
/// 浏览器端为 MV3 service worker 特有问题(superseded socket、connect probe、
/// pending share marker 等)做的防御逻辑不在移植范围;协议语义(重连策略、
/// 重进房身份、bootstrap 期 member 增量排队、admin 踢人识别、错误码处理)
/// 逐项对齐,对应关系在各成员注释中标明。
library;

import 'dart:async';
import 'dart:convert' show jsonEncode;

import 'client_messages.dart';
import 'clock_sync.dart';
import 'common.dart';
import 'models.dart';
import 'player_sync.dart' show PlayerSyncSessionApi;
import 'server_messages.dart';
import 'transport.dart';

enum SyncPlayConnectionStatus { disconnected, connecting, connected }

enum JoinAttemptResult { joined, failed, timeout }

/// socket-controller.ts: ADMIN_SESSION_RESET_REASONS——服务端管理动作的
/// close reason,收到后清会话且不重连。
const Set<String> adminSessionResetReasons = {
  'Admin kicked member',
  'Admin disconnected session',
  'Admin closed room',
};

/// socket-manager.ts: shouldReconnect
bool shouldScheduleReconnect({
  required bool connected,
  required bool reconnectTimerActive,
  required String? roomCode,
  required bool pendingCreateRoom,
}) {
  if (connected || reconnectTimerActive) {
    return false;
  }
  return roomCode != null || pendingCreateRoom;
}

/// socket-manager.ts: getReconnectDelayMs——1s 起指数退避,封顶 30s,
/// 只要还有房间会话就无限重试(服务器重启常超过任何固定次数预算)。
Duration getReconnectDelay(int reconnectAttempt) {
  final exponent = (reconnectAttempt - 1).clamp(0, 62);
  final ms = 1000 * (1 << exponent);
  return Duration(milliseconds: ms > 30000 ? 30000 : ms);
}

/// server-url.ts 的最小移植:仅接受 ws/wss 且带主机名的 URL。
Uri? validateServerUrl(String url) {
  final parsed = Uri.tryParse(url.trim());
  if (parsed == null ||
      (parsed.scheme != 'ws' && parsed.scheme != 'wss') ||
      parsed.host.isEmpty) {
    return null;
  }
  return parsed;
}

typedef _MemberDelta = ({bool joined, String roomCode, RoomMember member});

class SyncPlayRoomSession implements PlayerSyncSessionApi {
  SyncPlayRoomSession({
    required this.serverUrl,
    SyncPlayTransportConnector? connector,
    this.displayName,
    this.bootstrapRoomStateTimeout = const Duration(seconds: 5),
    this.onChanged,
    this.onRoomState,
    this.onSessionEnded,
    this.onServerError,
    this.log,
  }) : _connector = connector ?? WebSocketSyncPlayTransport.connect;

  String serverUrl;
  final SyncPlayTransportConnector _connector;

  /// room-session-controller.ts: DEFAULT_BOOTSTRAP_ROOM_STATE_TIMEOUT_MS
  final Duration bootstrapRoomStateTimeout;

  /// 粗粒度状态变化通知(连接状态/房间字段变动),对应扩展端 notifyAll。
  void Function()? onChanged;

  /// 权威房间状态落地(member 增量合并后、时钟补偿后),
  /// player_bridge 在这里施加播放状态。
  void Function(RoomState state)? onRoomState;

  /// 会话被服务端终结(admin 踢人/关房、存量房间被拒),UI 提示用。
  void Function(String reason)? onSessionEnded;

  void Function(ServerErrorMessage error)? onServerError;
  void Function(String message)? log;

  // ---- 连接状态(runtime-state.ts: ConnectionState) ----
  SyncPlayConnectionStatus status = SyncPlayConnectionStatus.disconnected;
  String? lastError;
  SyncPlayTransport? _transport;
  StreamSubscription<String>? _messageSub;

  /// 权威清场(leave/admin reset)期间递增,使仍在 await 中的 connect 作废,
  /// 对应扩展端 connectEpoch。
  int _connectEpoch = 0;
  int _reconnectAttempt = 0;
  Timer? _reconnectTimer;
  DateTime? _reconnectDeadline;

  // ---- 会话状态(runtime-state.ts: RoomSessionState) ----
  @override
  String? roomCode;
  String? joinToken;
  String? memberToken;
  @override
  String? memberId;
  String? displayName;
  @override
  RoomState? roomState;
  bool pendingCreateRoom = false;
  String? pendingJoinRoomCode;
  String? pendingJoinToken;
  bool pendingJoinRequestSent = false;

  /// 已连接但本会话的权威 room:state 尚未到达(见 runtime-state.ts 同名注释):
  /// 此窗口内缓存的 roomState/memberToken 可能过期,自动分享类动作应推迟。
  @override
  bool awaitingFreshRoomState = false;

  // ---- 时钟(runtime-state.ts: ClockState) ----
  double? clockOffsetMs;
  @override
  double? rttMs;
  Timer? _clockTimer;

  // ---- bootstrap 期 member 增量排队(room-session-controller.ts) ----
  List<_MemberDelta> _pendingMemberDeltas = [];
  bool _waitingForBootstrapRoomState = false;
  int _bootstrapGeneration = 0;
  Timer? _bootstrapTimer;

  List<Completer<JoinAttemptResult>> _pendingJoinAttempts = [];

  bool get connected => status == SyncPlayConnectionStatus.connected;

  /// 距下次自动重连的剩余时间;无重连计划时为 null。
  Duration? get retryIn {
    final deadline = _reconnectDeadline;
    if (deadline == null) {
      return null;
    }
    final remaining = deadline.difference(DateTime.now());
    return remaining.isNegative ? Duration.zero : remaining;
  }

  /// 按时钟偏移外推后的房间状态(clock-controller.ts: compensateRoomState)。
  RoomState? get compensatedRoomState {
    final state = roomState;
    if (state == null) {
      return null;
    }
    return compensateRoomStateForClock(state, clockOffsetMs);
  }

  void _notify() => onChanged?.call();

  void _log(String message) => log?.call(message);

  // ---------------------------------------------------------------- 连接

  Future<void> connect() async {
    if (status != SyncPlayConnectionStatus.disconnected) {
      return;
    }
    final uri = validateServerUrl(serverUrl);
    if (uri == null) {
      lastError = 'invalid server url: $serverUrl';
      _stopClockTimer();
      _notify();
      return;
    }

    _cancelReconnectTimer();
    status = SyncPlayConnectionStatus.connecting;
    _log('Connecting to $uri');
    _notify();

    final epoch = _connectEpoch;
    final SyncPlayTransport transport;
    try {
      transport = await _connector(uri);
    } catch (error) {
      if (epoch != _connectEpoch) {
        return;
      }
      status = SyncPlayConnectionStatus.disconnected;
      lastError = 'connection failed: $error';
      _stopClockTimer();
      _scheduleReconnect();
      _notify();
      return;
    }
    if (epoch != _connectEpoch) {
      // 权威清场发生在握手期间:丢弃这个"幽灵连接"。
      unawaited(transport.close());
      return;
    }

    _transport = transport;
    status = SyncPlayConnectionStatus.connected;
    lastError = null;
    _reconnectAttempt = 0;
    _reconnectDeadline = null;
    _log('Socket connected');
    _messageSub = transport.messages.listen(
      _onFrame,
      onError: (Object _) => _onTransportClosed(transport),
      onDone: () => _onTransportClosed(transport),
    );
    _onOpen();
    _notify();
  }

  /// socket-controller.ts open 事件:按优先级冲刷待建房/待进房/存量重进房,
  /// 然后启动对时。
  void _onOpen() {
    if (pendingCreateRoom) {
      awaitingFreshRoomState = true;
      pendingCreateRoom = false;
      _send(ClientMessages.roomCreate(displayName: displayName));
    } else if (pendingJoinRoomCode != null &&
        pendingJoinToken != null &&
        !pendingJoinRequestSent) {
      awaitingFreshRoomState = true;
      _sendJoinRequest(pendingJoinRoomCode!, pendingJoinToken!);
    } else if (roomCode != null && joinToken != null) {
      awaitingFreshRoomState = true;
      _sendJoinRequest(roomCode!, joinToken!);
    }
    syncClock();
    _startClockTimer();
  }

  void _onTransportClosed(SyncPlayTransport transport) {
    if (_transport != transport) {
      return;
    }
    final reason = transport.closeReason;
    _log('Socket closed${reason != null ? ' reason=$reason' : ''}');
    _messageSub?.cancel();
    _messageSub = null;
    _transport = null;
    status = SyncPlayConnectionStatus.disconnected;
    _stopClockTimer();

    // socket-controller.ts close 事件:管理动作是权威的,清会话且不重连。
    if (reason != null && adminSessionResetReasons.contains(reason)) {
      _clearRoomContext(
        'admin session reset: $reason',
        errorMessage: reason,
        endedReason: reason,
      );
      return;
    }

    _scheduleReconnect();
    _notify();
  }

  /// 权威断开(leave/清场用):作废在途 connect,关闭当前连接。
  void _disconnectSocket() {
    _connectEpoch += 1;
    _cancelReconnectTimer();
    _stopClockTimer();
    _messageSub?.cancel();
    _messageSub = null;
    final transport = _transport;
    _transport = null;
    status = SyncPlayConnectionStatus.disconnected;
    if (transport != null) {
      unawaited(transport.close());
    }
  }

  void _scheduleReconnect() {
    if (!shouldScheduleReconnect(
      connected: connected,
      reconnectTimerActive: _reconnectTimer != null,
      roomCode: roomCode,
      pendingCreateRoom: pendingCreateRoom,
    )) {
      return;
    }
    _reconnectAttempt += 1;
    final delay = getReconnectDelay(_reconnectAttempt);
    _reconnectDeadline = DateTime.now().add(delay);
    _log('Reconnect scheduled in ${delay.inMilliseconds}ms');
    _reconnectTimer = Timer(delay, () {
      _reconnectTimer = null;
      _reconnectDeadline = null;
      unawaited(connect());
    });
  }

  void _cancelReconnectTimer() {
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _reconnectDeadline = null;
  }

  void _resetReconnectState() {
    _cancelReconnectTimer();
    _reconnectAttempt = 0;
  }

  void _send(Map<String, Object?> message) {
    final transport = _transport;
    if (transport == null || !connected) {
      return;
    }
    transport.send(jsonEncode(message));
  }

  void _onFrame(String frame) {
    final message = SyncPlayServerMessage.tryParseJson(frame);
    if (message == null) {
      _log('Received invalid or unrecognized server message');
      return;
    }
    _handleServerMessage(message);
  }

  // ---------------------------------------------------------------- 对时

  /// clock-controller.ts: syncClock
  void syncClock() {
    if (!connected) {
      return;
    }
    _send(
      ClientMessages.syncPing(
        clientSendTime: DateTime.now().millisecondsSinceEpoch,
      ),
    );
  }

  void _startClockTimer() {
    _stopClockTimer();
    _clockTimer = Timer.periodic(
      const Duration(milliseconds: clockSyncIntervalMs),
      (_) => syncClock(),
    );
  }

  void _stopClockTimer() {
    _clockTimer?.cancel();
    _clockTimer = null;
  }

  void _handleSyncPong(SyncPongMessage pong) {
    final sample = updateClockSample(
      clientSendTime: pong.clientSendTime,
      serverReceiveTime: pong.serverReceiveTime,
      serverSendTime: pong.serverSendTime,
      now: DateTime.now().millisecondsSinceEpoch,
      previousRttMs: rttMs,
      previousClockOffsetMs: clockOffsetMs,
    );
    rttMs = sample.rttMs;
    clockOffsetMs = sample.clockOffsetMs;
    _log('Clock sync offset=${clockOffsetMs}ms rtt=${rttMs}ms');
  }

  // ------------------------------------------------------ 服务端消息处理

  /// room-session-controller.ts: handleServerMessage
  void _handleServerMessage(SyncPlayServerMessage message) {
    switch (message) {
      case RoomCreatedMessage():
        _clearPendingMemberDeltas();
        _startWaitingForBootstrapRoomState();
        pendingJoinRoomCode = null;
        pendingJoinToken = null;
        roomCode = message.roomCode;
        joinToken = message.joinToken;
        memberToken = message.memberToken;
        memberId = message.memberId;
        lastError = null;
        _syncProfileAfterRoomEstablished();
        _notify();
      case RoomJoinedMessage():
        _pendingMemberDeltas.removeWhere(
          (delta) => delta.roomCode != message.roomCode,
        );
        _startWaitingForBootstrapRoomState();
        roomCode = message.roomCode;
        joinToken = pendingJoinToken ?? joinToken;
        memberToken = message.memberToken;
        memberId = message.memberId;
        pendingJoinRequestSent = false;
        pendingJoinRoomCode = null;
        pendingJoinToken = null;
        lastError = null;
        _settlePendingJoinAttempts(JoinAttemptResult.joined);
        _syncProfileAfterRoomEstablished();
        _notify();
      case RoomStateMessage():
        _handleRoomStateMessage(message.state);
      case RoomMemberJoinedMessage():
        _handleMemberDelta((
          joined: true,
          roomCode: message.roomCode,
          member: message.member,
        ));
      case RoomMemberLeftMessage():
        _handleMemberDelta((
          joined: false,
          roomCode: message.roomCode,
          member: message.member,
        ));
      case ServerErrorMessage():
        _handleServerError(message);
      case SyncPongMessage():
        _handleSyncPong(message);
    }
  }

  /// room-session-controller.ts error 分支:进房失败码清 pending 会话,
  /// 存量房间被拒清全部上下文,member_token_invalid 只作废身份令牌。
  void _handleServerError(ServerErrorMessage error) {
    lastError = error.message;
    const joinFailureCodes = {
      SyncPlayErrorCode.roomNotFound,
      SyncPlayErrorCode.joinTokenInvalid,
      SyncPlayErrorCode.invalidMessage,
      SyncPlayErrorCode.unsupportedProtocolVersion,
    };
    const storedRoomRejectedCodes = {
      SyncPlayErrorCode.roomNotFound,
      SyncPlayErrorCode.joinTokenInvalid,
      SyncPlayErrorCode.unsupportedProtocolVersion,
    };

    if (pendingJoinRoomCode != null && joinFailureCodes.contains(error.code)) {
      _log('Join failed for room $pendingJoinRoomCode');
      _stopWaitingForBootstrapRoomState();
      _settlePendingJoinAttempts(JoinAttemptResult.failed);
      pendingJoinRequestSent = false;
      pendingJoinRoomCode = null;
      pendingJoinToken = null;
      roomCode = null;
      joinToken = null;
      memberToken = null;
      memberId = null;
      roomState = null;
    }
    if (roomCode != null &&
        pendingJoinRoomCode == null &&
        storedRoomRejectedCodes.contains(error.code)) {
      _clearRoomContext(
        'server rejected stored room context: ${error.code}',
        errorMessage: error.message,
        endedReason: error.code,
      );
      onServerError?.call(error);
      return;
    }
    if (error.code == SyncPlayErrorCode.memberTokenInvalid) {
      memberToken = null;
    }
    onServerError?.call(error);
    _notify();
  }

  void _handleRoomStateMessage(RoomState nextState) {
    final resolvedState = _consumePendingMemberDeltas(nextState);
    _stopWaitingForBootstrapRoomState();
    roomState = resolvedState;
    roomCode = resolvedState.roomCode;
    lastError = null;
    onRoomState?.call(
      compensateRoomStateForClock(resolvedState, clockOffsetMs),
    );
    _notify();
  }

  void _handleMemberDelta(_MemberDelta delta) {
    if (_isAwaitingRoomBootstrapFor(delta.roomCode)) {
      _pendingMemberDeltas.add(delta);
      return;
    }
    final currentState = roomState;
    if (currentState == null || currentState.roomCode != delta.roomCode) {
      return;
    }
    final nextState = _applyMemberDelta(currentState, delta);
    roomState = nextState;
    roomCode = nextState.roomCode;
    lastError = null;
    onRoomState?.call(compensateRoomStateForClock(nextState, clockOffsetMs));
    _notify();
  }

  // --------------------------------------- bootstrap 期 member 增量排队

  RoomState _applyMemberDelta(RoomState currentState, _MemberDelta delta) {
    if (currentState.roomCode != delta.roomCode) {
      return currentState;
    }
    final List<RoomMember> members;
    if (!delta.joined) {
      members = [
        for (final candidate in currentState.members)
          if (candidate.id != delta.member.id) candidate,
      ];
    } else {
      final existingIndex = currentState.members.indexWhere(
        (candidate) => candidate.id == delta.member.id,
      );
      members = existingIndex == -1
          ? [...currentState.members, delta.member]
          : [
              for (var i = 0; i < currentState.members.length; i++)
                i == existingIndex ? delta.member : currentState.members[i],
            ];
    }
    return RoomState(
      roomCode: currentState.roomCode,
      sharedVideo: currentState.sharedVideo,
      playback: currentState.playback,
      members: members,
    );
  }

  RoomState _consumePendingMemberDeltas(RoomState nextState) {
    var resolvedState = nextState;
    final remaining = <_MemberDelta>[];
    for (final delta in _pendingMemberDeltas) {
      if (delta.roomCode == nextState.roomCode) {
        resolvedState = _applyMemberDelta(resolvedState, delta);
      } else {
        remaining.add(delta);
      }
    }
    _pendingMemberDeltas = remaining;
    return resolvedState;
  }

  bool _isAwaitingRoomBootstrapFor(String targetRoomCode) {
    if (_waitingForBootstrapRoomState && roomCode == targetRoomCode) {
      return true;
    }
    if (!pendingJoinRequestSent) {
      return false;
    }
    return roomCode == targetRoomCode || pendingJoinRoomCode == targetRoomCode;
  }

  void _startWaitingForBootstrapRoomState() {
    _stopWaitingForBootstrapRoomState();
    _waitingForBootstrapRoomState = true;
    awaitingFreshRoomState = true;
    _bootstrapGeneration += 1;
    final generation = _bootstrapGeneration;
    _bootstrapTimer = Timer(bootstrapRoomStateTimeout, () {
      _expireBootstrapRoomStateWait(generation);
    });
  }

  void _stopWaitingForBootstrapRoomState() {
    _waitingForBootstrapRoomState = false;
    awaitingFreshRoomState = false;
    _bootstrapGeneration += 1;
    _bootstrapTimer?.cancel();
    _bootstrapTimer = null;
  }

  /// room-session-controller.ts: expireBootstrapRoomStateWait——超时只兜底
  /// 排队的 member 增量,故意不清 awaitingFreshRoomState(见原注释:
  /// room:state 只是慢的话,提前放行会让延迟动作用上过期快照)。
  void _expireBootstrapRoomStateWait(int generation) {
    if (!_waitingForBootstrapRoomState || generation != _bootstrapGeneration) {
      return;
    }
    _waitingForBootstrapRoomState = false;
    _bootstrapTimer = null;
    final targetRoomCode = roomCode;
    if (targetRoomCode == null) {
      _clearPendingMemberDeltas();
      return;
    }
    if (!_pendingMemberDeltas.any(
      (delta) => delta.roomCode == targetRoomCode,
    )) {
      return;
    }
    final currentState = roomState;
    if (currentState == null || currentState.roomCode != targetRoomCode) {
      _pendingMemberDeltas.removeWhere(
        (delta) => delta.roomCode == targetRoomCode,
      );
      _log('Dropped member deltas after bootstrap timeout for $targetRoomCode');
      return;
    }
    final resolvedState = _consumePendingMemberDeltas(currentState);
    _log(
      'Applied queued member deltas after bootstrap timeout '
      'for $targetRoomCode',
    );
    roomState = resolvedState;
    lastError = null;
    onRoomState?.call(
      compensateRoomStateForClock(resolvedState, clockOffsetMs),
    );
    _notify();
  }

  void _clearPendingMemberDeltas() => _pendingMemberDeltas = [];

  // ------------------------------------------------------------ 生命周期

  void _sendJoinRequest(String targetRoomCode, String targetJoinToken) {
    pendingJoinRequestSent = true;
    _send(
      ClientMessages.roomJoin(
        roomCode: targetRoomCode,
        joinToken: targetJoinToken,
        memberToken: memberToken,
        displayName: displayName,
      ),
    );
  }

  /// room-session-controller.ts: syncProfileAfterRoomEstablished
  void _syncProfileAfterRoomEstablished() {
    final token = memberToken;
    final name = displayName;
    if (!connected || token == null || name == null) {
      return;
    }
    _send(ClientMessages.profileUpdate(memberToken: token, displayName: name));
  }

  void _settlePendingJoinAttempts(JoinAttemptResult result) {
    if (_pendingJoinAttempts.isEmpty) {
      return;
    }
    final completers = _pendingJoinAttempts;
    _pendingJoinAttempts = [];
    for (final completer in completers) {
      if (!completer.isCompleted) {
        completer.complete(result);
      }
    }
  }

  /// room-session-controller.ts: waitForJoinAttemptResult
  Future<JoinAttemptResult> waitForJoinAttemptResult({
    Duration timeout = const Duration(seconds: 3),
  }) {
    final completer = Completer<JoinAttemptResult>();
    _pendingJoinAttempts.add(completer);
    Timer(timeout, () {
      if (!completer.isCompleted) {
        _pendingJoinAttempts.remove(completer);
        completer.complete(JoinAttemptResult.timeout);
      }
    });
    return completer.future;
  }

  /// room-session-controller.ts: requestCreateRoom。与扩展端"连上后立即发"
  /// 的双路径不同:统一置 pendingCreateRoom 后走 _onOpen/立即冲刷,语义等价
  /// 且避免 await connect 后的连接状态竞争。
  Future<void> requestCreateRoom() async {
    _resetReconnectState();
    _clearPendingMemberDeltas();
    _stopWaitingForBootstrapRoomState();
    roomCode = null;
    joinToken = null;
    memberToken = null;
    memberId = null;
    roomState = null;
    pendingJoinRoomCode = null;
    pendingJoinToken = null;
    pendingJoinRequestSent = false;
    pendingCreateRoom = true;
    _notify();
    if (connected) {
      awaitingFreshRoomState = true;
      pendingCreateRoom = false;
      _send(ClientMessages.roomCreate(displayName: displayName));
      return;
    }
    await connect();
  }

  /// room-session-controller.ts: requestJoinRoom
  Future<void> requestJoinRoom(
    String targetRoomCode,
    String targetJoinToken,
  ) async {
    _resetReconnectState();
    _clearPendingMemberDeltas();
    _stopWaitingForBootstrapRoomState();
    pendingCreateRoom = false;
    pendingJoinRoomCode = targetRoomCode.trim().toUpperCase();
    pendingJoinToken = targetJoinToken.trim();
    pendingJoinRequestSent = false;
    _log('Join requested for $pendingJoinRoomCode');
    roomCode = null;
    joinToken = null;
    memberToken = null;
    memberId = null;
    roomState = null;
    lastError = null;
    _notify();
    if (connected) {
      awaitingFreshRoomState = true;
      _sendJoinRequest(pendingJoinRoomCode!, pendingJoinToken!);
      return;
    }
    await connect();
  }

  /// room-session-controller.ts: requestLeaveRoom
  void requestLeaveRoom() {
    _clearPendingMemberDeltas();
    _stopWaitingForBootstrapRoomState();
    _log('Leave requested for ${roomCode ?? 'none'}');
    if (connected) {
      _send(ClientMessages.roomLeave(memberToken: memberToken));
    }
    roomCode = null;
    joinToken = null;
    memberToken = null;
    memberId = null;
    roomState = null;
    pendingJoinRoomCode = null;
    pendingJoinToken = null;
    pendingJoinRequestSent = false;
    pendingCreateRoom = false;
    _resetReconnectState();
    _disconnectSocket();
    _notify();
  }

  /// room-session-controller.ts: clearCurrentRoomContext
  void _clearRoomContext(
    String reason, {
    String? errorMessage,
    String? endedReason,
  }) {
    _clearPendingMemberDeltas();
    _stopWaitingForBootstrapRoomState();
    _log('Clearing current room context ($reason)');
    roomCode = null;
    joinToken = null;
    memberToken = null;
    memberId = null;
    roomState = null;
    pendingCreateRoom = false;
    pendingJoinRoomCode = null;
    pendingJoinToken = null;
    pendingJoinRequestSent = false;
    lastError = errorMessage;
    _resetReconnectState();
    if (endedReason != null) {
      onSessionEnded?.call(endedReason);
    }
    _notify();
  }

  // ------------------------------------------------------------ 出站动作

  /// 更新显示名并同步到服务端(对应扩展端设置名字后的 profile:update)。
  void updateDisplayName(String name) {
    displayName = name;
    _syncProfileAfterRoomEstablished();
    _notify();
  }

  @override
  void shareVideo(SharedVideo video, {PlaybackState? playback}) {
    final token = memberToken;
    if (!connected || token == null) {
      return;
    }
    _send(
      ClientMessages.videoShare(
        memberToken: token,
        video: video,
        playback: playback,
      ),
    );
  }

  @override
  void sendPlaybackUpdate(PlaybackState playback) {
    final token = memberToken;
    if (!connected || token == null) {
      return;
    }
    _send(
      ClientMessages.playbackUpdate(memberToken: token, playback: playback),
    );
  }

  void requestSync() {
    final token = memberToken;
    if (!connected || token == null) {
      return;
    }
    _send(ClientMessages.syncRequest(memberToken: token));
  }

  /// 释放全部资源;释放后实例不可再用。
  void dispose() {
    _settlePendingJoinAttempts(JoinAttemptResult.timeout);
    _stopWaitingForBootstrapRoomState();
    _disconnectSocket();
  }
}
