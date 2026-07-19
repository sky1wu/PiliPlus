/// 出站消息构形测试:断言 wire shape 与
/// packages/protocol/src/types/client-message.ts 的接口逐字段一致。
library;

import 'package:sync_play_core/sync_play_core.dart';
import 'package:test/test.dart';

void main() {
  test('room:create carries protocol version and optional display name', () {
    expect(ClientMessages.roomCreate(), {
      'type': 'room:create',
      'payload': {'protocolVersion': syncPlayProtocolVersion},
    });
    expect(ClientMessages.roomCreate(displayName: 'Alice'), {
      'type': 'room:create',
      'payload': {
        'displayName': 'Alice',
        'protocolVersion': syncPlayProtocolVersion,
      },
    });
  });

  test('room:join includes tokens and omits absent optionals', () {
    expect(
      ClientMessages.roomJoin(
        roomCode: 'ABC123',
        joinToken: 'join-token-1234567890',
      ),
      {
        'type': 'room:join',
        'payload': {
          'roomCode': 'ABC123',
          'joinToken': 'join-token-1234567890',
          'protocolVersion': syncPlayProtocolVersion,
        },
      },
    );
    expect(
      ClientMessages.roomJoin(
        roomCode: 'ABC123',
        joinToken: 'join-token-1234567890',
        memberToken: 'member-token-1234567890',
        displayName: 'Alice',
      )['payload'],
      containsPair('memberToken', 'member-token-1234567890'),
    );
  });

  test('profile:update and sync:request wrap the member token', () {
    expect(
      ClientMessages.profileUpdate(
        memberToken: 'member-token-1234567890',
        displayName: 'Bob',
      ),
      {
        'type': 'profile:update',
        'payload': {
          'memberToken': 'member-token-1234567890',
          'displayName': 'Bob',
        },
      },
    );
    expect(
      ClientMessages.syncRequest(memberToken: 'member-token-1234567890'),
      {
        'type': 'sync:request',
        'payload': {'memberToken': 'member-token-1234567890'},
      },
    );
  });

  test('room:leave omits payload entirely when no member token', () {
    expect(ClientMessages.roomLeave(), {'type': 'room:leave'});
    expect(ClientMessages.roomLeave(memberToken: 'member-token-1234567890'), {
      'type': 'room:leave',
      'payload': {'memberToken': 'member-token-1234567890'},
    });
  });

  test('video:share and playback:update serialize domain models', () {
    const video = SharedVideo(
      videoId: 'BV1xx411c7mD:42',
      url: 'https://www.bilibili.com/video/BV1xx411c7mD?cid=42',
      title: 'Video',
    );
    const playback = PlaybackState(
      url: 'https://www.bilibili.com/video/BV1xx411c7mD?cid=42',
      currentTime: 12.5,
      playState: PlaybackPlayState.playing,
      syncIntent: PlaybackSyncIntent.explicitSeek,
      userInitiated: true,
      playbackRate: 1.25,
      updatedAt: 1700000000000,
      serverTime: 1700000000100,
      actorId: 'member-1',
      seq: 7,
    );

    expect(
      ClientMessages.videoShare(
        memberToken: 'member-token-1234567890',
        video: video,
      ),
      {
        'type': 'video:share',
        'payload': {
          'memberToken': 'member-token-1234567890',
          'video': {
            'videoId': 'BV1xx411c7mD:42',
            'url': 'https://www.bilibili.com/video/BV1xx411c7mD?cid=42',
            'title': 'Video',
          },
        },
      },
    );

    final update = ClientMessages.playbackUpdate(
      memberToken: 'member-token-1234567890',
      playback: playback,
    );
    expect(update['type'], 'playback:update');
    final payload = update['payload'] as Map<String, Object?>;
    expect(payload['playback'], {
      'url': 'https://www.bilibili.com/video/BV1xx411c7mD?cid=42',
      'currentTime': 12.5,
      'playState': 'playing',
      'syncIntent': 'explicit-seek',
      'userInitiated': true,
      'playbackRate': 1.25,
      'updatedAt': 1700000000000,
      'serverTime': 1700000000100,
      'actorId': 'member-1',
      'seq': 7,
    });
    // 未设置的可选字段不得上 wire
    expect(payload['playback'] as Map, isNot(contains('naturalEnd')));
  });

  test('sync:ping carries the client send time', () {
    expect(ClientMessages.syncPing(clientSendTime: 1234), {
      'type': 'sync:ping',
      'payload': {'clientSendTime': 1234},
    });
  });
}
