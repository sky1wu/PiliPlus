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

  static RoomStateMessage? _parseRoomState(Map<String, Object?> map) {
    final state = RoomState.tryParse(map['payload']);
    if (state == null) {
      return null;
    }
    return RoomStateMessage(state: state);
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

final class RoomStateMessage extends SyncPlayServerMessage {
  const RoomStateMessage({required this.state});

  final RoomState state;
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
