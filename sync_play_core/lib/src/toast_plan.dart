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

import 'dart:math' as math;

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

/// content/toast.ts: shouldShowSeekToast——房间位置的移动是否超出"照着播"能解释
/// 的范围,即有人拖了进度条。
///
/// 进度增量要与**两个独立的**流逝时间参考对照,两者都超阈值才算跳转,因为它们各
/// 有各的说谎方式:
///
/// - serverTime 差不受本机任何事情影响,但它由服务端墙钟打戳。服务端的钟被步进
///   (容器/虚拟机重同步——实测某 WSL 开发服务端两次 ping 之间跳了约 1.9s)会报出
///   一段根本没发生过的间隔,差值就在这里变成幻影跳转。
/// - 本地量到的两拍到达间隔不受任何钟调整影响,但扛不住本端被饿着:主线程卡顿后
///   两份状态背靠背处理完,看起来像没过时间,读作房间向前跳了。
///
/// 真实的跳转对**两个**参考都成立,所以要求两者都超阈值即可同时消掉这两类误报。
/// 代价是真跳转恰好撞上钟步进或卡顿时会漏一次提示——只是观感问题,下一次更新照样
/// 把事情说清楚。误报更糟:它说某位成员做了他没做的事。
bool shouldShowSeekToast(
  PlaybackState previous,
  PlaybackState next,
  double localElapsedMs,
) {
  final actualDelta = next.currentTime - previous.currentTime;
  final serverElapsedMs = next.serverTime - previous.serverTime;
  final serverElapsedSeconds =
      (serverElapsedMs > 0 ? serverElapsedMs : 0) / 1000;
  final localElapsedSeconds = (localElapsedMs > 0 ? localElapsedMs : 0) / 1000;
  double unexplainedBy(double elapsedSeconds) =>
      (actualDelta - elapsedSeconds * previous.playbackRate).abs();

  if (previous.playState != PlaybackPlayState.playing) {
    // 房间当时没在走,任何流逝时间都解释不了位移:此后位置有变就是有人拖了。这条
    // 也覆盖从暂停恢复的情形——那里把流逝时间算进去会把暂停区间报成一次倒退。
    return actualDelta.abs() >= seekToastThresholdSeconds;
  }

  return math.min(
        unexplainedBy(serverElapsedSeconds),
        unexplainedBy(localElapsedSeconds),
      ) >=
      seekToastThresholdSeconds;
}

/// content/toast.ts: getRoomStateToastMessages(+ 折叠的共享视频切换提示)。
RoomToastPlan buildRoomStateToastPlan({
  required RoomState? previousState,
  required RoomState nextState,
  required String? localMemberId,
  required bool pendingRoomStateHydration,
  required bool isCurrentPageShowingSharedVideo,

  /// 单调 now,也是 [lastSeekToastByActor] 里时间戳所在的钟。用单调时钟,钟被调整
  /// 时既不会撑大也不会压扁跳转判定与抑制窗口。
  required num now,

  /// previousState 与 nextState 两次到达之间在本地量到的间隔,与 [now] 同一单调
  /// 时钟。见 [shouldShowSeekToast]。
  required double elapsedSincePreviousStateMs,
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
      shouldShowSeekToast(
        previousPlayback,
        nextPlayback,
        elapsedSincePreviousStateMs,
      );

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
