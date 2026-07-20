/// 房间事件 toast 决策测试:对照扩展端 content/toast.ts 的
/// getRoomStateToastMessages / shouldShowSeekToast 语义。
library;

import 'package:sync_play_core/sync_play_core.dart';
import 'package:test/test.dart';

const sharedUrl = 'https://www.bilibili.com/video/BV1xx411c7mD';
const otherUrl = 'https://www.bilibili.com/video/BV1ab411c7mD';

PlaybackState playback({
  String url = sharedUrl,
  double currentTime = 30,
  PlaybackPlayState playState = PlaybackPlayState.playing,
  double playbackRate = 1,
  bool? naturalEnd,
  num serverTime = 1000,
  String actorId = 'member-2',
  num seq = 1,
}) => PlaybackState(
  url: url,
  currentTime: currentTime,
  playState: playState,
  naturalEnd: naturalEnd,
  playbackRate: playbackRate,
  updatedAt: serverTime,
  serverTime: serverTime,
  actorId: actorId,
  seq: seq,
);

RoomState roomState({
  String roomCode = 'ABC123',
  SharedVideo? sharedVideo = const SharedVideo(
    videoId: 'BV1xx411c7mD',
    url: sharedUrl,
    title: 'Video',
    sharedByMemberId: 'member-2',
  ),
  PlaybackState? playback,
  List<RoomMember> members = const [
    RoomMember(id: 'member-1', name: 'Alice'),
    RoomMember(id: 'member-2', name: 'Bob'),
  ],
}) => RoomState(
  roomCode: roomCode,
  sharedVideo: sharedVideo,
  playback: playback,
  members: members,
);

RoomToastPlan plan({
  RoomState? previousState,
  required RoomState nextState,
  String? localMemberId = 'member-1',
  bool pendingRoomStateHydration = false,
  bool isCurrentPageShowingSharedVideo = true,
  num now = 100000,
  Map<String, num> lastSeekToastByActor = const {},
}) => buildRoomStateToastPlan(
  previousState: previousState,
  nextState: nextState,
  localMemberId: localMemberId,
  pendingRoomStateHydration: pendingRoomStateHydration,
  isCurrentPageShowingSharedVideo: isCurrentPageShowingSharedVideo,
  now: now,
  lastSeekToastByActor: lastSeekToastByActor,
);

void main() {
  group('shouldShowSeekToast', () {
    test('playing→playing compares against expected elapsed progress', () {
      final previous = playback(currentTime: 30, serverTime: 1000);
      // 2s 流逝,进度 +2s:符合预期,不是跳转
      expect(
        shouldShowSeekToast(
          previous,
          playback(currentTime: 32, serverTime: 3000, seq: 2),
        ),
        isFalse,
      );
      // 2s 流逝,进度 +10s:跳转
      expect(
        shouldShowSeekToast(
          previous,
          playback(currentTime: 40, serverTime: 3000, seq: 2),
        ),
        isTrue,
      );
    });

    test('paused states compare raw position delta', () {
      final previous = playback(
        currentTime: 30,
        playState: PlaybackPlayState.paused,
      );
      expect(
        shouldShowSeekToast(
          previous,
          playback(
            currentTime: 31,
            playState: PlaybackPlayState.paused,
            serverTime: 3000,
          ),
        ),
        isFalse,
      );
      expect(
        shouldShowSeekToast(
          previous,
          playback(
            currentTime: 40,
            playState: PlaybackPlayState.paused,
            serverTime: 3000,
          ),
        ),
        isTrue,
      );
    });
  });

  group('buildRoomStateToastPlan', () {
    test('no events without previous state or on room change', () {
      expect(plan(nextState: roomState()).events, isEmpty);
      expect(
        plan(
          previousState: roomState(roomCode: 'OLD999'),
          nextState: roomState(),
        ).events,
        isEmpty,
      );
      expect(
        plan(
          previousState: roomState(),
          nextState: roomState(),
          localMemberId: null,
        ).events,
        isEmpty,
      );
    });

    test('member join and leave, excluding self', () {
      final previous = roomState(
        members: const [RoomMember(id: 'member-1', name: 'Alice')],
      );
      final joined = plan(
        previousState: previous,
        nextState: roomState(),
      ).events;
      expect(joined, [isA<MemberJoinedToast>()]);
      expect((joined.single as MemberJoinedToast).name, 'Bob');

      final left = plan(previousState: roomState(), nextState: previous).events;
      expect(left, [isA<MemberLeftToast>()]);
      expect((left.single as MemberLeftToast).name, 'Bob');
    });

    test('remote play/pause transitions produce toasts', () {
      final events = plan(
        previousState: roomState(
          playback: playback(playState: PlaybackPlayState.paused),
        ),
        nextState: roomState(playback: playback(serverTime: 2000, seq: 2)),
      ).events;
      expect(events, [isA<StartedPlayingToast>()]);
      expect((events.single as StartedPlayingToast).name, 'Bob');

      final paused = plan(
        previousState: roomState(playback: playback()),
        nextState: roomState(
          playback: playback(
            currentTime: 31,
            playState: PlaybackPlayState.paused,
            serverTime: 2000,
            seq: 2,
          ),
        ),
      ).events;
      expect(paused, [isA<PausedVideoToast>()]);
    });

    test('own playback actions stay silent', () {
      final events = plan(
        previousState: roomState(
          playback: playback(playState: PlaybackPlayState.paused),
        ),
        nextState: roomState(
          playback: playback(actorId: 'member-1', serverTime: 2000, seq: 2),
        ),
      ).events;
      expect(events, isEmpty);
    });

    test('playback toasts suppressed during hydration, off-shared page and '
        'natural end', () {
      final previous = roomState(
        playback: playback(playState: PlaybackPlayState.paused),
      );
      final next = roomState(playback: playback(serverTime: 2000, seq: 2));
      expect(
        plan(
          previousState: previous,
          nextState: next,
          pendingRoomStateHydration: true,
        ).events,
        isEmpty,
      );
      expect(
        plan(
          previousState: previous,
          nextState: next,
          isCurrentPageShowingSharedVideo: false,
        ).events,
        isEmpty,
      );
      expect(
        plan(
          previousState: roomState(playback: playback()),
          nextState: roomState(
            playback: playback(
              playState: PlaybackPlayState.paused,
              naturalEnd: true,
              serverTime: 2000,
              seq: 2,
            ),
          ),
        ).events,
        isEmpty,
      );
    });

    test('seek toast fires and swallows the playing transition', () {
      final result = plan(
        previousState: roomState(
          playback: playback(playState: PlaybackPlayState.paused),
        ),
        nextState: roomState(
          playback: playback(currentTime: 90, serverTime: 2000, seq: 2),
        ),
      );
      // paused→playing 且大幅跳转:只发"跳转到",不叠加"开始播放"
      expect(result.events, [isA<SeekedToToast>()]);
      final seeked = result.events.single as SeekedToToast;
      expect(seeked.name, 'Bob');
      expect(seeked.seconds, 90);
      expect(result.nextSeekToastByActor['member-2'], 100000);
    });

    test('recent seek suppresses the follow-up playing toast', () {
      final events = plan(
        previousState: roomState(
          playback: playback(playState: PlaybackPlayState.paused),
        ),
        nextState: roomState(playback: playback(serverTime: 2000, seq: 2)),
        now: 100000,
        lastSeekToastByActor: const {'member-2': 99000},
      ).events;
      expect(events, isEmpty);
    });

    test('rate change toast beyond 0.01 threshold', () {
      final events = plan(
        previousState: roomState(playback: playback()),
        nextState: roomState(
          playback: playback(
            currentTime: 32,
            playbackRate: 1.5,
            serverTime: 3000,
            seq: 2,
          ),
        ),
      ).events;
      expect(events, [isA<SwitchedRateToast>()]);
      expect((events.single as SwitchedRateToast).rate, 1.5);
    });

    test('shared video switch by another member toasts once with title', () {
      final next = roomState(
        sharedVideo: const SharedVideo(
          videoId: 'BV1ab411c7mD',
          url: otherUrl,
          title: 'Next Video',
          sharedByMemberId: 'member-2',
        ),
        playback: playback(url: otherUrl, serverTime: 2000, seq: 2),
      );
      final events = plan(
        previousState: roomState(playback: playback()),
        nextState: next,
      ).events;
      expect(events, [isA<SharedNewVideoToast>()]);
      final toast = events.single as SharedNewVideoToast;
      expect(toast.name, 'Bob');
      expect(toast.title, 'Next Video');

      // 下一拍 URL 未再变化:不重复提示
      expect(plan(previousState: next, nextState: next).events, isEmpty);
    });

    test('own shared video switch stays silent', () {
      final events = plan(
        previousState: roomState(playback: playback()),
        nextState: roomState(
          sharedVideo: const SharedVideo(
            videoId: 'BV1ab411c7mD',
            url: otherUrl,
            title: 'Next Video',
            sharedByMemberId: 'member-1',
          ),
          playback: playback(url: otherUrl, serverTime: 2000, seq: 2),
        ),
      ).events;
      expect(events, isEmpty);
    });
  });
}
