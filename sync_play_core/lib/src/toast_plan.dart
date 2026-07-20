/// 房间事件 toast 决策,移植自扩展 content/toast.ts 的纯决策函数
/// (getRoomStateToastMessages / shouldShowSeekToast)。
///
/// 与扩展端的结构性差异:
/// - 扩展端返回已本地化的字符串(t()),这里返回类型化事件
///   [RoomToastEvent],由 App 层负责文案(lib/sync_play/sync_play_messages);
/// - 扩展端"共享了新视频"走 background 的 pendingShareToast 转发 + key 去重
///   (room-manager.ts),因为跨页导航会重建 content script;App 是单进程,
///   前后状态 diff 即可保证只在切换那一拍产生一次,语义等价,故折叠进
///   同一个决策函数;
/// - 扩展端 toastAutoSharedNextVideo(连播自动共享提示)依赖 sharer-autoplay
///   专用状态机,App 的自动跟进分享无法区分连播与手动切页,v1 不做。
library;

import 'common.dart';
import 'models.dart';

/// content/toast.ts: SEEK_TOAST_THRESHOLD_SECONDS
const double seekToastThresholdSeconds = 1.5;

/// content/toast.ts: SEEK_START_TOAST_SUPPRESSION_MS
const int seekStartToastSuppressionMs = 1600;

sealed class RoomToastEvent {
  const RoomToastEvent();
}

final class MemberJoinedToast extends RoomToastEvent {
  const MemberJoinedToast(this.name);

  final String name;
}

final class MemberLeftToast extends RoomToastEvent {
  const MemberLeftToast(this.name);

  final String name;
}

final class StartedPlayingToast extends RoomToastEvent {
  const StartedPlayingToast(this.name);

  final String name;
}

final class PausedVideoToast extends RoomToastEvent {
  const PausedVideoToast(this.name);

  final String name;
}

final class SwitchedRateToast extends RoomToastEvent {
  const SwitchedRateToast({required this.name, required this.rate});

  final String name;
  final double rate;
}

final class SeekedToToast extends RoomToastEvent {
  const SeekedToToast({required this.name, required this.seconds});

  final String name;
  final double seconds;
}

final class SharedNewVideoToast extends RoomToastEvent {
  const SharedNewVideoToast({required this.name, required this.title});

  final String name;
  final String title;
}

typedef RoomToastPlan = ({
  List<RoomToastEvent> events,
  Map<String, num> nextSeekToastByActor,
});

String? _memberName(RoomState state, String? memberId) {
  if (memberId == null) {
    return null;
  }
  for (final member in state.members) {
    if (member.id == memberId) {
      return member.name;
    }
  }
  return null;
}

/// content/toast.ts: shouldShowSeekToast——按两拍 serverTime 差推算期望
/// 进度增量,实际增量偏离超过阈值才认定为一次"跳转"。
bool shouldShowSeekToast(PlaybackState previous, PlaybackState next) {
  final actualDelta = next.currentTime - previous.currentTime;
  final elapsedMs = next.serverTime - previous.serverTime;
  final elapsedSeconds = (elapsedMs > 0 ? elapsedMs : 0) / 1000;
  final expectedDelta = elapsedSeconds * previous.playbackRate;

  if (previous.playState == PlaybackPlayState.playing &&
      next.playState != PlaybackPlayState.playing) {
    return (actualDelta - expectedDelta).abs() >= seekToastThresholdSeconds;
  }

  if (previous.playState != PlaybackPlayState.playing ||
      next.playState != PlaybackPlayState.playing) {
    return actualDelta.abs() >= seekToastThresholdSeconds;
  }

  return (actualDelta - expectedDelta).abs() >= seekToastThresholdSeconds;
}

/// content/toast.ts: getRoomStateToastMessages(+ 折叠的共享视频切换提示)。
RoomToastPlan buildRoomStateToastPlan({
  required RoomState? previousState,
  required RoomState nextState,
  required String? localMemberId,
  required bool pendingRoomStateHydration,
  required bool isCurrentPageShowingSharedVideo,
  required num now,
  required Map<String, num> lastSeekToastByActor,
}) {
  final events = <RoomToastEvent>[];
  final nextSeekToastByActor = Map<String, num>.of(lastSeekToastByActor);

  if (localMemberId == null ||
      previousState == null ||
      previousState.roomCode != nextState.roomCode) {
    return (events: events, nextSeekToastByActor: nextSeekToastByActor);
  }

  final sharedVideoChanged =
      previousState.sharedVideo?.url != nextState.sharedVideo?.url;
  final previousMembers = {
    for (final member in previousState.members) member.id: member.name,
  };
  final currentMembers = {
    for (final member in nextState.members) member.id: member.name,
  };

  currentMembers.forEach((memberId, memberName) {
    if (!previousMembers.containsKey(memberId) && memberId != localMemberId) {
      events.add(MemberJoinedToast(memberName));
    }
  });
  previousMembers.forEach((memberId, memberName) {
    if (!currentMembers.containsKey(memberId) && memberId != localMemberId) {
      events.add(MemberLeftToast(memberName));
    }
  });

  final sharedVideo = nextState.sharedVideo;
  if (sharedVideoChanged && sharedVideo != null) {
    final actorId = sharedVideo.sharedByMemberId ?? nextState.playback?.actorId;
    if (actorId != null && actorId != localMemberId) {
      final actorName =
          _memberName(nextState, actorId) ?? sharedVideo.sharedByDisplayName;
      if (actorName != null) {
        events.add(
          SharedNewVideoToast(name: actorName, title: sharedVideo.title),
        );
      }
    }
  }

  if (pendingRoomStateHydration ||
      sharedVideoChanged ||
      !isCurrentPageShowingSharedVideo ||
      // 共享视频自然播完的终态 paused 需静默施加(见 PlaybackState.naturalEnd)
      nextState.playback?.naturalEnd == true) {
    return (events: events, nextSeekToastByActor: nextSeekToastByActor);
  }

  final previousPlayback = previousState.playback;
  final nextPlayback = nextState.playback;

  final shouldShowSeek =
      previousPlayback != null &&
      nextPlayback != null &&
      previousState.sharedVideo?.url == nextState.sharedVideo?.url &&
      nextPlayback.actorId != localMemberId &&
      shouldShowSeekToast(previousPlayback, nextPlayback);

  if (previousPlayback?.playState != nextPlayback?.playState &&
      nextPlayback != null &&
      nextPlayback.playState != PlaybackPlayState.buffering &&
      nextPlayback.actorId != localMemberId &&
      !(shouldShowSeek &&
          nextPlayback.playState == PlaybackPlayState.playing) &&
      !(nextPlayback.playState == PlaybackPlayState.playing &&
          nextSeekToastByActor.containsKey(nextPlayback.actorId) &&
          now - (nextSeekToastByActor[nextPlayback.actorId] ?? 0) <
              seekStartToastSuppressionMs)) {
    final actorName = _memberName(nextState, nextPlayback.actorId);
    if (actorName != null) {
      events.add(
        nextPlayback.playState == PlaybackPlayState.playing
            ? StartedPlayingToast(actorName)
            : PausedVideoToast(actorName),
      );
    }
  }

  if (previousPlayback != null &&
      nextPlayback != null &&
      previousState.sharedVideo?.url == nextState.sharedVideo?.url &&
      nextPlayback.actorId != localMemberId &&
      (previousPlayback.playbackRate - nextPlayback.playbackRate).abs() >
          0.01) {
    final actorName = _memberName(nextState, nextPlayback.actorId);
    if (actorName != null) {
      events.add(
        SwitchedRateToast(name: actorName, rate: nextPlayback.playbackRate),
      );
    }
  }

  if (shouldShowSeek) {
    final actorName = _memberName(nextState, nextPlayback.actorId);
    if (actorName != null) {
      nextSeekToastByActor[nextPlayback.actorId] = now;
      events.add(
        SeekedToToast(name: actorName, seconds: nextPlayback.currentTime),
      );
    }
  }

  return (events: events, nextSeekToastByActor: nextSeekToastByActor);
}
