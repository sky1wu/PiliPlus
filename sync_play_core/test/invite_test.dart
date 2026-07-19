/// 邀请码解析测试,语义对照 extension/src/popup/helpers.ts。
library;

import 'package:sync_play_core/sync_play_core.dart';
import 'package:test/test.dart';

const token = 'join-token-1234567890';

void main() {
  test('formats as roomCode:joinToken', () {
    expect(
      formatInviteValue(roomCode: 'ABC123', joinToken: token),
      'ABC123:$token',
    );
  });

  test('parses colon/pipe/comma separated invites', () {
    for (final separator in [':', '|', ',']) {
      expect(parseInviteValue('ABC123$separator$token'), (
        roomCode: 'ABC123',
        joinToken: token,
      ));
    }
  });

  test('uppercases the room code and strips whitespace', () {
    expect(parseInviteValue('  abc123 : $token  '), (
      roomCode: 'ABC123',
      joinToken: token,
    ));
  });

  test('rejects malformed invites', () {
    expect(parseInviteValue(''), isNull);
    expect(parseInviteValue('ABC123'), isNull);
    expect(parseInviteValue('ABC123:$token:extra'), isNull);
    expect(parseInviteValue('ABCDEFG:$token'), isNull); // 7 位房间号
    expect(parseInviteValue('ABC123:short'), isNull); // 口令过短
  });
}
