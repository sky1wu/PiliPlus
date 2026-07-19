/// 对应 packages/protocol/src/types/domain.ts 的领域模型,
/// tryParse 校验逻辑对应 guards/server-message.ts 中的同名 guard。
library;

import 'common.dart';
import 'validation.dart';

class RoomMember {
  const RoomMember({required this.id, required this.name});

  final String id;
  final String name;

  /// guards/server-message.ts: isRoomMember
  static RoomMember? tryParse(Object? value) {
    final map = asRecord(value);
    if (map == null) {
      return null;
    }
    final id = map['id'];
    final name = map['name'];
    if (!isActorId(id) || !isBoundedString(name, displayNameMaxLength)) {
      return null;
    }
    return RoomMember(id: id as String, name: name as String);
  }

  Map<String, Object?> toJson() => {'id': id, 'name': name};
}

class SharedVideo {
  const SharedVideo({
    required this.videoId,
    required this.url,
    required this.title,
    this.sharedByMemberId,
    this.sharedByDisplayName,
  });

  final String videoId;
  final String url;
  final String title;
  final String? sharedByMemberId;
  final String? sharedByDisplayName;

  /// guards/server-message.ts: isSharedVideo
  static SharedVideo? tryParse(Object? value) {
    final map = asRecord(value);
    if (map == null) {
      return null;
    }
    final videoId = map['videoId'];
    final url = map['url'];
    final title = map['title'];
    final sharedByMemberId = map['sharedByMemberId'];
    final sharedByDisplayName = map['sharedByDisplayName'];
    final valid =
        isBoundedString(videoId, titleMaxLength) &&
        isVideoId(videoId) &&
        isBoundedString(url, urlMaxLength) &&
        isBilibiliUrl(url) &&
        isBoundedString(title, titleMaxLength) &&
        (sharedByMemberId == null || isActorId(sharedByMemberId)) &&
        (sharedByDisplayName == null ||
            isBoundedString(sharedByDisplayName, displayNameMaxLength));
    if (!valid) {
      return null;
    }
    return SharedVideo(
      videoId: videoId as String,
      url: url as String,
      title: title as String,
      sharedByMemberId: sharedByMemberId as String?,
      sharedByDisplayName: sharedByDisplayName as String?,
    );
  }

  Map<String, Object?> toJson() => {
    'videoId': videoId,
    'url': url,
    'title': title,
    if (sharedByMemberId != null) 'sharedByMemberId': sharedByMemberId,
    if (sharedByDisplayName != null) 'sharedByDisplayName': sharedByDisplayName,
  };
}

class PlaybackState {
  const PlaybackState({
    required this.url,
    required this.currentTime,
    required this.playState,
    this.syncIntent,
    this.userInitiated,
    this.naturalEnd,
    required this.playbackRate,
    required this.updatedAt,
    required this.serverTime,
    required this.actorId,
    required this.seq,
  });

  final String url;
  final double currentTime;
  final PlaybackPlayState playState;
  final PlaybackSyncIntent? syncIntent;

  /// 显式用户手势提示(domain.ts 注释):接收端可跳过防抖直接应用。
  final bool? userInitiated;

  /// 共享视频自然播完产生的终态 paused(domain.ts 注释):
  /// 接收端应用状态但不弹"已暂停/已跳转"类提示。
  final bool? naturalEnd;
  final double playbackRate;
  final num updatedAt;
  final num serverTime;
  final String actorId;
  final num seq;

  /// guards/server-message.ts: isPlaybackState
  static PlaybackState? tryParse(Object? value) {
    final map = asRecord(value);
    if (map == null) {
      return null;
    }
    final playState = PlaybackPlayState.tryParse(map['playState']);
    final syncIntentRaw = map['syncIntent'];
    final syncIntent = PlaybackSyncIntent.tryParse(syncIntentRaw);
    final userInitiated = map['userInitiated'];
    final naturalEnd = map['naturalEnd'];
    final valid =
        isBoundedString(map['url'], urlMaxLength) &&
        isFiniteNumber(map['currentTime']) &&
        playState != null &&
        (syncIntentRaw == null || syncIntent != null) &&
        (userInitiated == null || userInitiated is bool) &&
        (naturalEnd == null || naturalEnd is bool) &&
        isFiniteNumber(map['playbackRate']) &&
        isFiniteNumber(map['updatedAt']) &&
        isFiniteNumber(map['serverTime']) &&
        isActorId(map['actorId']) &&
        isFiniteNumber(map['seq']);
    if (!valid) {
      return null;
    }
    return PlaybackState(
      url: map['url'] as String,
      currentTime: (map['currentTime'] as num).toDouble(),
      playState: playState,
      syncIntent: syncIntent,
      userInitiated: userInitiated as bool?,
      naturalEnd: naturalEnd as bool?,
      playbackRate: (map['playbackRate'] as num).toDouble(),
      updatedAt: map['updatedAt'] as num,
      serverTime: map['serverTime'] as num,
      actorId: map['actorId'] as String,
      seq: map['seq'] as num,
    );
  }

  Map<String, Object?> toJson() => {
    'url': url,
    'currentTime': currentTime,
    'playState': playState.wire,
    if (syncIntent != null) 'syncIntent': syncIntent!.wire,
    if (userInitiated != null) 'userInitiated': userInitiated,
    if (naturalEnd != null) 'naturalEnd': naturalEnd,
    'playbackRate': playbackRate,
    'updatedAt': updatedAt,
    'serverTime': serverTime,
    'actorId': actorId,
    'seq': seq,
  };

  PlaybackState copyWith({double? currentTime}) => PlaybackState(
    url: url,
    currentTime: currentTime ?? this.currentTime,
    playState: playState,
    syncIntent: syncIntent,
    userInitiated: userInitiated,
    naturalEnd: naturalEnd,
    playbackRate: playbackRate,
    updatedAt: updatedAt,
    serverTime: serverTime,
    actorId: actorId,
    seq: seq,
  );
}

class RoomState {
  const RoomState({
    required this.roomCode,
    required this.sharedVideo,
    required this.playback,
    required this.members,
  });

  final String roomCode;
  final SharedVideo? sharedVideo;
  final PlaybackState? playback;
  final List<RoomMember> members;

  /// guards/server-message.ts: isRoomState
  static RoomState? tryParse(Object? value) {
    final map = asRecord(value);
    if (map == null || !isRoomCode(map['roomCode'])) {
      return null;
    }

    final sharedVideoRaw = map['sharedVideo'];
    final SharedVideo? sharedVideo;
    if (sharedVideoRaw == null) {
      sharedVideo = null;
    } else {
      sharedVideo = SharedVideo.tryParse(sharedVideoRaw);
      if (sharedVideo == null) {
        return null;
      }
    }

    final playbackRaw = map['playback'];
    final PlaybackState? playback;
    if (playbackRaw == null) {
      playback = null;
    } else {
      playback = PlaybackState.tryParse(playbackRaw);
      if (playback == null) {
        return null;
      }
    }

    final membersRaw = map['members'];
    if (membersRaw is! List) {
      return null;
    }
    final members = <RoomMember>[];
    for (final item in membersRaw) {
      final member = RoomMember.tryParse(item);
      if (member == null) {
        return null;
      }
      members.add(member);
    }

    return RoomState(
      roomCode: map['roomCode'] as String,
      sharedVideo: sharedVideo,
      playback: playback,
      members: members,
    );
  }

  Map<String, Object?> toJson() => {
    'roomCode': roomCode,
    'sharedVideo': sharedVideo?.toJson(),
    'playback': playback?.toJson(),
    'members': [for (final member in members) member.toJson()],
  };
}
