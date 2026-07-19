/// 对应 packages/protocol/src/guards/primitives.ts 与 server-message.ts 的
/// 校验原语。模式与长度上限必须与 TS 端保持一致。
library;

import 'video_ref.dart';

final RegExp roomCodePattern = RegExp(r'^[A-Z0-9]{6}$');
final RegExp actorIdPattern = RegExp(r'^[A-Za-z0-9][A-Za-z0-9:_-]{0,63}$');
final RegExp videoIdPattern = RegExp(
  r'^(?:BV[0-9A-Za-z]+|(?:av|ep|ss)\d+)(?::(?:p[1-9]\d*|[1-9]\d*))?$',
);

const int tokenMinLength = 16;
const int tokenMaxLength = 128;
const int displayNameMaxLength = 32;
const int titleMaxLength = 128;
const int urlMaxLength = 512;

Map<String, Object?>? asRecord(Object? value) =>
    value is Map ? value.cast<String, Object?>() : null;

bool isBoundedString(Object? value, int maxLength) =>
    value is String && value.length <= maxLength;

bool isFiniteNumber(Object? value) => value is num && value.isFinite;

/// TS 端 undefined 即字段缺失;JSON 解出的 Map 里缺失键取值为 null,
/// 因此这里统一把 null 当缺失处理。
bool isOptionalPositiveInteger(Object? value) =>
    value == null ||
    (value is num && value.isFinite && value >= 1 && value % 1 == 0);

bool isRoomCode(Object? value) =>
    value is String && roomCodePattern.hasMatch(value);

bool isActorId(Object? value) =>
    value is String && actorIdPattern.hasMatch(value);

bool isVideoId(Object? value) =>
    value is String && videoIdPattern.hasMatch(value);

bool isToken(Object? value) =>
    value is String &&
    value.length >= tokenMinLength &&
    value.length <= tokenMaxLength;

bool isBilibiliUrl(Object? value) =>
    value is String && parseBilibiliVideoRef(value) != null;
