/// 移植自 packages/protocol/test/server-message.test.ts,逐条对应:
/// TS 端 isServerMessage(...) === true 的用例这里断言 tryParse 产出对应
/// 类型;=== false 的用例断言 tryParse 返回 null。
library;

import 'package:sync_play_core/sync_play_core.dart';
import 'package:test/test.dart';

const validToken = 'valid-member-token-123';

Map<String, Object?> _sharedVideo({
  String url = 'https://www.bilibili.com/video/BV1xx411c7mD?p=2',
  String? sharedByMemberId,
  String? sharedByDisplayName,
}) => {
  'videoId': 'BV1xx411c7mD',
  'url': url,
  'title': 'Video',
  if (sharedByMemberId != null) 'sharedByMemberId': sharedByMemberId,
  if (sharedByDisplayName != null) 'sharedByDisplayName': sharedByDisplayName,
};

Map<String, Object?> _playback(Map<String, Object?> overrides) => {
  'url': 'https://www.bilibili.com/video/BV1xx411c7mD?p=2',
  'currentTime': 12,
  'playState': 'playing',
  'playbackRate': 1,
  'updatedAt': 1,
  'serverTime': 1,
  'actorId': 'member-1',
  'seq': 1,
  ...overrides,
};

Map<String, Object?> _roomStateMessage({
  Object? sharedVideo,
  Object? playback,
  Object? members,
}) => {
  'type': 'room:state',
  'payload': {
    'roomCode': 'ABC123',
    'sharedVideo': sharedVideo,
    'playback': playback,
    'members':
        members ??
        [
          {'id': 'member-1', 'name': 'Alice'},
        ],
  },
};

void main() {
  test('accepts a valid room:created message', () {
    final message = SyncPlayServerMessage.tryParse({
      'type': 'room:created',
      'payload': {
        'roomCode': 'ABC123',
        'memberId': 'member-1',
        'joinToken': validToken,
        'memberToken': validToken,
      },
    });
    expect(message, isA<RoomCreatedMessage>());
    final created = message as RoomCreatedMessage;
    expect(created.roomCode, 'ABC123');
    expect(created.memberId, 'member-1');
    expect(created.joinToken, validToken);
    expect(created.memberToken, validToken);
    expect(created.serverProtocolVersion, isNull);
  });

  test('accepts a valid room:state message', () {
    final message = SyncPlayServerMessage.tryParse(
      _roomStateMessage(
        sharedVideo: _sharedVideo(),
        playback: _playback({'syncIntent': 'explicit-seek'}),
      ),
    );
    expect(message, isA<RoomStateMessage>());
    final state = (message as RoomStateMessage).state;
    expect(state.roomCode, 'ABC123');
    expect(state.sharedVideo!.videoId, 'BV1xx411c7mD');
    expect(state.playback!.currentTime, 12);
    expect(state.playback!.playState, PlaybackPlayState.playing);
    expect(state.playback!.syncIntent, PlaybackSyncIntent.explicitSeek);
    expect(state.members, hasLength(1));
    expect(state.members.single.name, 'Alice');
  });

  test('accepts room:state when member ids use UUIDs', () {
    const uuid = '123e4567-e89b-12d3-a456-426614174000';
    final message = SyncPlayServerMessage.tryParse(
      _roomStateMessage(
        sharedVideo: _sharedVideo(sharedByMemberId: uuid),
        playback: _playback({'actorId': uuid}),
        members: [
          {'id': uuid, 'name': 'Alice'},
        ],
      ),
    );
    expect(message, isA<RoomStateMessage>());
  });

  test(
    'accepts room:state when playback sync intent is explicit-ratechange',
    () {
      final message = SyncPlayServerMessage.tryParse(
        _roomStateMessage(
          sharedVideo: _sharedVideo(),
          playback: _playback({
            'syncIntent': 'explicit-ratechange',
            'playbackRate': 1.5,
          }),
        ),
      );
      expect(message, isA<RoomStateMessage>());
      final playback = (message as RoomStateMessage).state.playback!;
      expect(playback.syncIntent, PlaybackSyncIntent.explicitRatechange);
      expect(playback.playbackRate, 1.5);
    },
  );

  test(
    'accepts room:joined when memberId uses max-compatible actor format',
    () {
      final message = SyncPlayServerMessage.tryParse({
        'type': 'room:joined',
        'payload': {
          'roomCode': 'ABC123',
          'memberId': 'member_01:host',
          'memberToken': validToken,
        },
      });
      expect(message, isA<RoomJoinedMessage>());
    },
  );

  test('accepts room member delta messages', () {
    expect(
      SyncPlayServerMessage.tryParse({
        'type': 'room:member-joined',
        'payload': {
          'roomCode': 'ABC123',
          'member': {'id': 'member-1', 'name': 'Alice'},
        },
      }),
      isA<RoomMemberJoinedMessage>(),
    );
    expect(
      SyncPlayServerMessage.tryParse({
        'type': 'room:member-left',
        'payload': {
          'roomCode': 'ABC123',
          'member': {'id': 'member-2', 'name': 'Bob'},
        },
      }),
      isA<RoomMemberLeftMessage>(),
    );
  });

  test('rejects room member delta messages with invalid member payloads', () {
    expect(
      SyncPlayServerMessage.tryParse({
        'type': 'room:member-joined',
        'payload': {
          'roomCode': 'ABC123',
          'member': {'id': 'member 1', 'name': 'Alice'},
        },
      }),
      isNull,
    );
    expect(
      SyncPlayServerMessage.tryParse({
        'type': 'room:member-left',
        'payload': {
          'roomCode': 'ABC123',
          'member': {'id': 'member-2', 'name': 'x' * 33},
        },
      }),
      isNull,
    );
  });

  test('rejects room:created when memberId format is invalid', () {
    expect(
      SyncPlayServerMessage.tryParse({
        'type': 'room:created',
        'payload': {
          'roomCode': 'ABC123',
          'memberId': 'member 1',
          'joinToken': validToken,
          'memberToken': validToken,
        },
      }),
      isNull,
    );
  });

  test('accepts room:state when playback carries userInitiated:true', () {
    final message = SyncPlayServerMessage.tryParse(
      _roomStateMessage(
        sharedVideo: _sharedVideo(),
        playback: _playback({'playState': 'paused', 'userInitiated': true}),
      ),
    );
    expect(message, isA<RoomStateMessage>());
    expect((message as RoomStateMessage).state.playback!.userInitiated, isTrue);
  });

  test('rejects room:state when playback userInitiated is non-boolean', () {
    expect(
      SyncPlayServerMessage.tryParse(
        _roomStateMessage(
          sharedVideo: _sharedVideo(),
          playback: _playback({'playState': 'paused', 'userInitiated': 'yes'}),
        ),
      ),
      isNull,
    );
  });

  test('accepts room:state when playback carries naturalEnd:true', () {
    final message = SyncPlayServerMessage.tryParse(
      _roomStateMessage(
        sharedVideo: _sharedVideo(),
        playback: _playback({
          'playState': 'paused',
          'naturalEnd': true,
          'currentTime': 262.5,
        }),
      ),
    );
    expect(message, isA<RoomStateMessage>());
    expect((message as RoomStateMessage).state.playback!.naturalEnd, isTrue);
  });

  test('rejects room:state when playback naturalEnd is non-boolean', () {
    expect(
      SyncPlayServerMessage.tryParse(
        _roomStateMessage(
          sharedVideo: _sharedVideo(),
          playback: _playback({'playState': 'paused', 'naturalEnd': 'yes'}),
        ),
      ),
      isNull,
    );
  });

  test('rejects room:state when playback sync intent is invalid', () {
    expect(
      SyncPlayServerMessage.tryParse(
        _roomStateMessage(
          sharedVideo: _sharedVideo(),
          playback: _playback({'syncIntent': 'follow'}),
        ),
      ),
      isNull,
    );
  });

  test(
    'accepts room:state when sharedByDisplayName is set on the shared video',
    () {
      final message = SyncPlayServerMessage.tryParse(
        _roomStateMessage(
          sharedVideo: _sharedVideo(
            url: 'https://www.bilibili.com/video/BV1xx411c7mD',
            sharedByMemberId: 'member-1',
            sharedByDisplayName: 'Alice',
          ),
        ),
      );
      expect(message, isA<RoomStateMessage>());
      expect(
        (message as RoomStateMessage).state.sharedVideo!.sharedByDisplayName,
        'Alice',
      );
    },
  );

  test('rejects room:state when sharedByDisplayName exceeds the bound', () {
    expect(
      SyncPlayServerMessage.tryParse(
        _roomStateMessage(
          sharedVideo: _sharedVideo(
            url: 'https://www.bilibili.com/video/BV1xx411c7mD',
            sharedByMemberId: 'member-1',
            sharedByDisplayName: 'x' * 33,
          ),
        ),
      ),
      isNull,
    );
  });

  test('rejects room:state when sharedByMemberId format is invalid', () {
    expect(
      SyncPlayServerMessage.tryParse(
        _roomStateMessage(
          sharedVideo: _sharedVideo(
            url: 'https://www.bilibili.com/video/BV1xx411c7mD',
            sharedByMemberId: 'member 1',
          ),
        ),
      ),
      isNull,
    );
  });

  test('rejects room:state when shared video url is invalid', () {
    expect(
      SyncPlayServerMessage.tryParse(
        _roomStateMessage(
          sharedVideo: _sharedVideo(
            url: 'https://example.com/video/BV1xx411c7mD',
          ),
        ),
      ),
      isNull,
    );
  });

  test('rejects room:state when playback actorId format is invalid', () {
    expect(
      SyncPlayServerMessage.tryParse(
        _roomStateMessage(playback: _playback({'actorId': 'member 1'})),
      ),
      isNull,
    );
  });

  test('rejects room:state when members contain invalid items', () {
    expect(
      SyncPlayServerMessage.tryParse(
        _roomStateMessage(
          members: [
            {'id': 'member-1', 'name': 123},
          ],
        ),
      ),
      isNull,
    );
  });

  test('rejects error when payload shape is invalid', () {
    expect(
      SyncPlayServerMessage.tryParse({
        'type': 'error',
        'payload': {'code': 'room_not_found'},
      }),
      isNull,
    );
  });

  test('accepts a valid error message', () {
    final message = SyncPlayServerMessage.tryParse({
      'type': 'error',
      'payload': {'code': 'room_not_found', 'message': 'Room not found'},
    });
    expect(message, isA<ServerErrorMessage>());
    expect(
      (message as ServerErrorMessage).code,
      SyncPlayErrorCode.roomNotFound,
    );
  });

  test('accepts a valid sync:pong message', () {
    final message = SyncPlayServerMessage.tryParse({
      'type': 'sync:pong',
      'payload': {
        'clientSendTime': 1,
        'serverReceiveTime': 2,
        'serverSendTime': 3,
      },
    });
    expect(message, isA<SyncPongMessage>());
    final pong = message as SyncPongMessage;
    expect(pong.clientSendTime, 1);
    expect(pong.serverReceiveTime, 2);
    expect(pong.serverSendTime, 3);
  });

  test('accepts room:created / room:joined with serverProtocolVersion', () {
    final created = SyncPlayServerMessage.tryParse({
      'type': 'room:created',
      'payload': {
        'roomCode': 'ABC123',
        'memberId': 'member-1',
        'joinToken': validToken,
        'memberToken': validToken,
        'serverProtocolVersion': 1,
      },
    });
    expect((created as RoomCreatedMessage).serverProtocolVersion, 1);

    final joined = SyncPlayServerMessage.tryParse({
      'type': 'room:joined',
      'payload': {
        'roomCode': 'ABC123',
        'memberId': 'member-1',
        'memberToken': validToken,
        'serverProtocolVersion': 1,
      },
    });
    expect((joined as RoomJoinedMessage).serverProtocolVersion, 1);
  });

  test('rejects non-positive serverProtocolVersion', () {
    expect(
      SyncPlayServerMessage.tryParse({
        'type': 'room:created',
        'payload': {
          'roomCode': 'ABC123',
          'memberId': 'member-1',
          'joinToken': validToken,
          'memberToken': validToken,
          'serverProtocolVersion': 0,
        },
      }),
      isNull,
    );
    expect(
      SyncPlayServerMessage.tryParse({
        'type': 'room:joined',
        'payload': {
          'roomCode': 'ABC123',
          'memberId': 'member-1',
          'memberToken': validToken,
          'serverProtocolVersion': -1,
        },
      }),
      isNull,
    );
  });

  test('rejects unknown message types and malformed JSON text', () {
    expect(SyncPlayServerMessage.tryParse({'type': 'room:exploded'}), isNull);
    expect(SyncPlayServerMessage.tryParse('room:state'), isNull);
    expect(SyncPlayServerMessage.tryParseJson('{not json'), isNull);
    expect(
      SyncPlayServerMessage.tryParseJson(
        '{"type":"sync:pong","payload":{"clientSendTime":1,'
        '"serverReceiveTime":2,"serverSendTime":3}}',
      ),
      isA<SyncPongMessage>(),
    );
  });
}
