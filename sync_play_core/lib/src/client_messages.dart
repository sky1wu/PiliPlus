/// 客户端出站消息构造器,对应 packages/protocol/src/types/client-message.ts。
/// 服务端是校验方,这里只负责构形;字段合法性由调用方(room service)保证。
library;

import 'common.dart';
import 'models.dart';

abstract final class ClientMessages {
  static Map<String, Object?> roomCreate({
    String? displayName,
    int protocolVersion = syncPlayProtocolVersion,
  }) =>
      {
        'type': 'room:create',
        'payload': {
          if (displayName != null) 'displayName': displayName,
          'protocolVersion': protocolVersion,
        },
      };

  static Map<String, Object?> roomJoin({
    required String roomCode,
    required String joinToken,
    String? memberToken,
    String? displayName,
    int protocolVersion = syncPlayProtocolVersion,
  }) =>
      {
        'type': 'room:join',
        'payload': {
          'roomCode': roomCode,
          'joinToken': joinToken,
          if (memberToken != null) 'memberToken': memberToken,
          if (displayName != null) 'displayName': displayName,
          'protocolVersion': protocolVersion,
        },
      };

  static Map<String, Object?> profileUpdate({
    required String memberToken,
    required String displayName,
  }) =>
      {
        'type': 'profile:update',
        'payload': {
          'memberToken': memberToken,
          'displayName': displayName,
        },
      };

  static Map<String, Object?> roomLeave({String? memberToken}) => {
        'type': 'room:leave',
        if (memberToken != null) 'payload': {'memberToken': memberToken},
      };

  static Map<String, Object?> videoShare({
    required String memberToken,
    required SharedVideo video,
    PlaybackState? playback,
  }) =>
      {
        'type': 'video:share',
        'payload': {
          'memberToken': memberToken,
          'video': video.toJson(),
          if (playback != null) 'playback': playback.toJson(),
        },
      };

  static Map<String, Object?> playbackUpdate({
    required String memberToken,
    required PlaybackState playback,
  }) =>
      {
        'type': 'playback:update',
        'payload': {
          'memberToken': memberToken,
          'playback': playback.toJson(),
        },
      };

  static Map<String, Object?> syncRequest({required String memberToken}) => {
        'type': 'sync:request',
        'payload': {'memberToken': memberToken},
      };

  static Map<String, Object?> syncPing({required num clientSendTime}) => {
        'type': 'sync:ping',
        'payload': {'clientSendTime': clientSendTime},
      };
}
