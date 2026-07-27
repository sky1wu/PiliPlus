/// 服务端入站消息的解析,对应 packages/protocol/src/types/server-message.ts
/// 与 guards/server-message.ts:tryParse 等价于 isServerMessage 守卫通过后
/// 直接产出类型化对象,守卫不通过返回 null。
library;

import 'dart:convert' show jsonDecode;

import 'models.dart';
import 'validation.dart';

sealed class SyncPlayServerMessage {
  const SyncPlayServerMessage();

  /// guards/server-message.ts: isServerMessage
  static SyncPlayServerMessage? tryParse(Object? value) {
    final map = asRecord(value);
    if (map == null) {
      return null;
    }
    return switch (map['type']) {
      'room:created' => _parseRoomCreated(map),
      'room:joined' => _parseRoomJoined(map),
      'room:state' => _parseRoomState(map),
      'room:member-joined' => _parseMemberDelta(map, joined: true),
      'room:member-left' => _parseMemberDelta(map, joined: false),
      'error' => _parseError(map),
      'sync:pong' => _parseSyncPong(map),
      _ => null,
    };
  }

  /// 单条 wire 文本(JSON)解析;非法 JSON 或非法消息返回 null。
  static SyncPlayServerMessage? tryParseJson(String text) {
    try {
      return tryParse(jsonDecode(text));
    } on FormatException {
      return null;
    }
  }

  static RoomCreatedMessage? _parseRoomCreated(Map<String, Object?> map) {
    final payload = asRecord(map['payload']);
    if (payload == null) {
      return null;
    }
    final serverProtocolVersion = payload['serverProtocolVersion'];
    final valid =
        isRoomCode(payload['roomCode']) &&
        isActorId(payload['memberId']) &&
        isToken(payload['joinToken']) &&
        isToken(payload['memberToken']) &&
        isOptionalPositiveInteger(serverProtocolVersion);
    if (!valid) {
      return null;
    }
    return RoomCreatedMessage(
      roomCode: payload['roomCode'] as String,
      memberId: payload['memberId'] as String,
      joinToken: payload['joinToken'] as String,
      memberToken: payload['memberToken'] as String,
      serverProtocolVersion: (serverProtocolVersion as num?)?.toInt(),
    );
  }

  static RoomJoinedMessage? _parseRoomJoined(Map<String, Object?> map) {
    final payload = asRecord(map['payload']);
    if (payload == null) {
      return null;
    }
    final serverProtocolVersion = payload['serverProtocolVersion'];
    final valid =
        isRoomCode(payload['roomCode']) &&
        isActorId(payload['memberId']) &&
        isToken(payload['memberToken']) &&
        isOptionalPositiveInteger(serverProtocolVersion);
    if (!valid) {
      return null;
    }
    return RoomJoinedMessage(
      roomCode: payload['roomCode'] as String,
      memberId: payload['memberId'] as String,
      memberToken: payload['memberToken'] as String,
      serverProtocolVersion: (serverProtocolVersion as num?)?.toInt(),
    );
  }

  /// guards/server-message.ts: isRoomStatePayload——房间状态本体之外,可选携带
  /// 服务端下发时该播放快照已有的年龄。
  static RoomStateMessage? _parseRoomState(Map<String, Object?> map) {
    final state = RoomState.tryParse(map['payload']);
    if (state == null) {
      return null;
    }
    final payload = asRecord(map['payload']);
    final playbackAgeMs = payload?['playbackAgeMs'];
    // 负年龄不是时长;在这里拒掉,接收端就不必去定义"快照来自未来"是什么意思。
    if (playbackAgeMs != null &&
        !(isFiniteNumber(playbackAgeMs) && (playbackAgeMs as num) >= 0)) {
      return null;
    }
    return RoomStateMessage(state: state, playbackAgeMs: playbackAgeMs as num?);
  }

  static SyncPlayServerMessage? _parseMemberDelta(
    Map<String, Object?> map, {
    required bool joined,
  }) {
    final payload = asRecord(map['payload']);
    if (payload == null || !isRoomCode(payload['roomCode'])) {
      return null;
    }
    final member = RoomMember.tryParse(payload['member']);
    if (member == null) {
      return null;
    }
    final roomCode = payload['roomCode'] as String;
    return joined
        ? RoomMemberJoinedMessage(roomCode: roomCode, member: member)
        : RoomMemberLeftMessage(roomCode: roomCode, member: member);
  }

  static ServerErrorMessage? _parseError(Map<String, Object?> map) {
    final payload = asRecord(map['payload']);
    if (payload == null ||
        !isBoundedString(payload['code'], 32) ||
        !isBoundedString(payload['message'], titleMaxLength)) {
      return null;
    }
    return ServerErrorMessage(
      code: payload['code'] as String,
      message: payload['message'] as String,
    );
  }

  static SyncPongMessage? _parseSyncPong(Map<String, Object?> map) {
    final payload = asRecord(map['payload']);
    if (payload == null ||
        !isFiniteNumber(payload['clientSendTime']) ||
        !isFiniteNumber(payload['serverReceiveTime']) ||
        !isFiniteNumber(payload['serverSendTime'])) {
      return null;
    }
    return SyncPongMessage(
      clientSendTime: payload['clientSendTime'] as num,
      serverReceiveTime: payload['serverReceiveTime'] as num,
      serverSendTime: payload['serverSendTime'] as num,
    );
  }
}

final class RoomCreatedMessage extends SyncPlayServerMessage {
  const RoomCreatedMessage({
    required this.roomCode,
    required this.memberId,
    required this.joinToken,
    required this.memberToken,
    this.serverProtocolVersion,
  });

  final String roomCode;
  final String memberId;
  final String joinToken;
  final String memberToken;
  final int? serverProtocolVersion;
}

final class RoomJoinedMessage extends SyncPlayServerMessage {
  const RoomJoinedMessage({
    required this.roomCode,
    required this.memberId,
    required this.memberToken,
    this.serverProtocolVersion,
  });

  final String roomCode;
  final String memberId;
  final String memberToken;
  final int? serverProtocolVersion;
}

/// types/server-message.ts: RoomStateMessage / RoomStatePayload
final class RoomStateMessage extends SyncPlayServerMessage {
  const RoomStateMessage({required this.state, this.playbackAgeMs});

  final RoomState state;

  /// 服务端下发这一刻,其播放快照已有多旧(毫秒时长)。
  ///
  /// 它挂在消息上而不是 [RoomState] 里,也刻意是**时长**而非时刻:
  ///
  /// - 时长跨两台不同步的钟仍然安全——接收端只会把它加到自己的锚点上;时刻不安全,
  ///   拿服务端时刻减本地时刻量到的是钟差,而钟差不是时长且会自己漂。
  /// - 年龄只在发送那一刻为真,因此必须每次下发重算、绝不能存进房间状态。把它挡在
  ///   [PlaybackState] 之外(那是会被服务端持久化、也会被客户端在 playback:update
  ///   里回传的形状),让"存下来"在结构上不可能,而不是靠人记住的一条规矩。
  ///
  /// 为兼容旧服务端而可选;缺失时接收端按 0 处理(#212 之前的行为:认为刚到达的
  /// 快照就是当前的)。
  final num? playbackAgeMs;
}

final class RoomMemberJoinedMessage extends SyncPlayServerMessage {
  const RoomMemberJoinedMessage({required this.roomCode, required this.member});

  final String roomCode;
  final RoomMember member;
}

final class RoomMemberLeftMessage extends SyncPlayServerMessage {
  const RoomMemberLeftMessage({required this.roomCode, required this.member});

  final String roomCode;
  final RoomMember member;
}

final class ServerErrorMessage extends SyncPlayServerMessage {
  const ServerErrorMessage({required this.code, required this.message});

  /// 见 [SyncPlayErrorCode] 已知常量;服务端可能发送未知码。
  final String code;
  final String message;
}

final class SyncPongMessage extends SyncPlayServerMessage {
  const SyncPongMessage({
    required this.clientSendTime,
    required this.serverReceiveTime,
    required this.serverSendTime,
  });

  final num clientSendTime;
  final num serverReceiveTime;
  final num serverSendTime;
}
