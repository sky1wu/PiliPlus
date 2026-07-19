/// 邀请码(`roomCode:joinToken`)的构造与解析,
/// 对应 extension/src/popup/helpers.ts: parseInviteValue 与
/// popup-actions.ts 的复制格式。
library;

import 'validation.dart';

typedef InviteValue = ({String roomCode, String joinToken});

/// 复制/展示用的邀请码格式(popup-actions.ts: `${roomCode}:${joinToken}`)。
String formatInviteValue({
  required String roomCode,
  required String joinToken,
}) => '$roomCode:$joinToken';

/// popup/helpers.ts: parseInviteValue——去除全部空白后按 `:`/`|`/`,`
/// 尝试切分,房间号大写并校验 6 位,口令按长度界校验;不合法返回 null。
InviteValue? parseInviteValue(String value) {
  final trimmed = value.trim();
  if (trimmed.isEmpty) {
    return null;
  }

  final normalized = trimmed.replaceAll(RegExp(r'\s+'), '');
  for (final separator in const [':', '|', ',']) {
    final parts = normalized.split(separator);
    if (parts.length != 2 || parts[0].isEmpty || parts[1].isEmpty) {
      continue;
    }
    final roomCode = parts[0].toUpperCase();
    final joinToken = parts[1];
    if (!roomCodePattern.hasMatch(roomCode)) {
      continue;
    }
    if (joinToken.length < tokenMinLength ||
        joinToken.length > tokenMaxLength) {
      continue;
    }
    return (roomCode: roomCode, joinToken: joinToken);
  }

  return null;
}
