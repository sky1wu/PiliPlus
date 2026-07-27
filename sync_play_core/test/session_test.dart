/// 会话状态机测试:语义断言对照浏览器扩展的
/// socket-controller.ts / room-session-controller.ts / socket-manager.ts。
library;

import 'dart:async';
import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:sync_play_core/sync_play_core.dart';
import 'package:test/test.dart';

const memberTokenA = 'member-token-aaaaaaaa';
const joinTokenA = 'join-token-aaaaaaaaaa';

class FakeTransport implements SyncPlayTransport {
  final _controller = StreamController<String>();
  final List<String> sent = [];
  bool closedByClient = false;

  @override
  String? closeReason;

  @override
  Stream<String> get messages => _controller.stream;

  @override
  void send(String text) => sent.add(text);

  @override
  Future<void> close() async {
    closedByClient = true;
    if (!_controller.isClosed) {
      await _controller.close();
    }
  }

  void emit(Map<String, Object?> message) =>
      _controller.add(jsonEncode(message));

  void serverClose([String? reason]) {
    closeReason = reason;
    _controller.close();
  }

  List<Map<String, Object?>> get sentJson => [
    for (final text in sent) (jsonDecode(text) as Map).cast<String, Object?>(),
  ];

  Map<String, Object?>? lastSentOfType(String type) {
    for (final message in sentJson.reversed) {
      if (message['type'] == type) {
        return message;
      }
    }
    return null;
  }
}

class Harness {
  Harness({Duration? bootstrapTimeout}) {
    session = SyncPlayRoomSession(
      serverUrl: 'wss://sync.example.com/ws',
      connector: _connect,
      displayName: 'Alice',
      bootstrapRoomStateTimeout: bootstrapTimeout ?? const Duration(seconds: 5),
      onRoomState: appliedStates.add,
      onSessionEnded: endedReasons.add,
      onServerError: serverErrors.add,
      monotonicNowMs: () => monotonicNowMs,
    );
  }

  /// 受控的单调时钟(生产中为 Stopwatch,见 session.dart)。
  double monotonicNowMs = 0;

  late final SyncPlayRoomSession session;
  final transports = <FakeTransport>[];
  final appliedStates = <RoomState>[];
  final endedReasons = <String>[];
  final serverErrors = <ServerErrorMessage>[];
  int connectCalls = 0;
  int failConnectsRemaining = 0;

  FakeTransport get transport => transports.last;

  Future<SyncPlayTransport> _connect(Uri uri) async {
    connectCalls += 1;
    if (failConnectsRemaining > 0) {
      failConnectsRemaining -= 1;
      throw Exception('connection refused');
    }
    final created = FakeTransport();
    transports.add(created);
    return created;
  }

  /// 建立 "已建房" 的稳定会话:create → room:created → room:state。
  void establishCreatedRoom(FakeAsync async) {
    session.requestCreateRoom();
    async.flushMicrotasks();
    transport.emit({
      'type': 'room:created',
      'payload': {
        'roomCode': 'ABC123',
        'memberId': 'member-1',
        'joinToken': joinTokenA,
        'memberToken': memberTokenA,
      },
    });
    async.flushMicrotasks();
    transport.emit(roomStateMessage());
    async.flushMicrotasks();
  }
}

Map<String, Object?> roomStateMessage({List<Map<String, Object?>>? members}) =>
    {
      'type': 'room:state',
      'payload': {
        'roomCode': 'ABC123',
        'sharedVideo': null,
        'playback': null,
        'members':
            members ??
            [
              {'id': 'member-1', 'name': 'Alice'},
            ],
      },
    };

Map<String, Object?> playingRoomStateMessage({
  double currentTime = 42,
  num serverTime = 1000,
  num? playbackAgeMs,
}) => {
  'type': 'room:state',
  'payload': {
    'roomCode': 'ABC123',
    'sharedVideo': null,
    'playback': {
      'url': 'https://www.bilibili.com/video/BV1xx411c7mD',
      'currentTime': currentTime,
      'playState': 'playing',
      'playbackRate': 1,
      'updatedAt': serverTime,
      'serverTime': serverTime,
      'actorId': 'member-2',
      'seq': 7,
    },
    'members': [
      {'id': 'member-1', 'name': 'Alice'},
      {'id': 'member-2', 'name': 'Bob'},
    ],
    if (playbackAgeMs != null) 'playbackAgeMs': playbackAgeMs,
  },
};

void main() {
  test('getReconnectDelay backs off exponentially and caps at 30s', () {
    expect(getReconnectDelay(1), const Duration(seconds: 1));
    expect(getReconnectDelay(2), const Duration(seconds: 2));
    expect(getReconnectDelay(3), const Duration(seconds: 4));
    expect(getReconnectDelay(5), const Duration(seconds: 16));
    expect(getReconnectDelay(6), const Duration(seconds: 30));
    expect(getReconnectDelay(60), const Duration(seconds: 30));
  });

  test('validateServerUrl accepts ws/wss only', () {
    expect(validateServerUrl('wss://sync.example.com/ws'), isNotNull);
    expect(validateServerUrl(' ws://localhost:8787 '), isNotNull);
    expect(validateServerUrl('https://sync.example.com'), isNull);
    expect(validateServerUrl('not a url'), isNull);
  });

  test('create room: connects, sends room:create, stores identity', () {
    fakeAsync((async) {
      final harness = Harness();
      harness.session.requestCreateRoom();
      async.flushMicrotasks();

      expect(harness.session.connected, isTrue);
      final create = harness.transport.lastSentOfType('room:create');
      expect(create, isNotNull);
      expect((create!['payload'] as Map)['displayName'], 'Alice');
      expect(
        (create['payload'] as Map)['protocolVersion'],
        syncPlayProtocolVersion,
      );

      harness.transport.emit({
        'type': 'room:created',
        'payload': {
          'roomCode': 'ABC123',
          'memberId': 'member-1',
          'joinToken': joinTokenA,
          'memberToken': memberTokenA,
        },
      });
      async.flushMicrotasks();

      expect(harness.session.roomCode, 'ABC123');
      expect(harness.session.memberToken, memberTokenA);
      expect(harness.session.joinToken, joinTokenA);
      // room:created 后、room:state 前:权威状态未到
      expect(harness.session.awaitingFreshRoomState, isTrue);
      // 建房时带了 displayName,room:created 后还会同步一次 profile
      expect(harness.transport.lastSentOfType('profile:update'), isNotNull);

      harness.transport.emit(roomStateMessage());
      async.flushMicrotasks();
      expect(harness.session.awaitingFreshRoomState, isFalse);
      expect(harness.session.roomState!.members, hasLength(1));
      expect(harness.appliedStates, hasLength(1));
      harness.session.dispose();
    });
  });

  test('join room: sends room:join and resolves waitForJoinAttemptResult', () {
    fakeAsync((async) {
      final harness = Harness();
      harness.session.requestJoinRoom('abc123', ' $joinTokenA ');
      async.flushMicrotasks();

      final join = harness.transport.lastSentOfType('room:join');
      expect(join, isNotNull);
      final payload = (join!['payload'] as Map).cast<String, Object?>();
      // roomCode 大写化、joinToken 去空白(room-session-controller 语义)
      expect(payload['roomCode'], 'ABC123');
      expect(payload['joinToken'], joinTokenA);
      expect(payload.containsKey('memberToken'), isFalse);

      JoinAttemptResult? result;
      harness.session.waitForJoinAttemptResult().then(
        (value) => result = value,
      );
      harness.transport.emit({
        'type': 'room:joined',
        'payload': {
          'roomCode': 'ABC123',
          'memberId': 'member-2',
          'memberToken': memberTokenA,
        },
      });
      async.flushMicrotasks();
      expect(result, JoinAttemptResult.joined);
      // pendingJoinToken 晋升为会话 joinToken(重连重进房要用)
      expect(harness.session.joinToken, joinTokenA);
      harness.session.dispose();
    });
  });

  test('join failure error clears pending join and resolves failed', () {
    fakeAsync((async) {
      final harness = Harness();
      harness.session.requestJoinRoom('ABC123', joinTokenA);
      async.flushMicrotasks();

      JoinAttemptResult? result;
      harness.session.waitForJoinAttemptResult().then(
        (value) => result = value,
      );
      harness.transport.emit({
        'type': 'error',
        'payload': {'code': 'room_not_found', 'message': 'Room not found'},
      });
      async.flushMicrotasks();

      expect(result, JoinAttemptResult.failed);
      expect(harness.session.pendingJoinRoomCode, isNull);
      expect(harness.session.roomCode, isNull);
      expect(harness.session.lastError, 'Room not found');
      expect(harness.serverErrors, hasLength(1));
      harness.session.dispose();
    });
  });

  test('waitForJoinAttemptResult times out without a response', () {
    fakeAsync((async) {
      final harness = Harness();
      harness.session.requestJoinRoom('ABC123', joinTokenA);
      async.flushMicrotasks();
      JoinAttemptResult? result;
      harness.session.waitForJoinAttemptResult().then(
        (value) => result = value,
      );
      async.elapse(const Duration(seconds: 3));
      expect(result, JoinAttemptResult.timeout);
      harness.session.dispose();
    });
  });

  test('reconnects with backoff and rejoins with member token', () {
    fakeAsync((async) {
      final harness = Harness();
      harness.establishCreatedRoom(async);
      expect(harness.connectCalls, 1);

      harness.transport.serverClose();
      async.flushMicrotasks();
      expect(harness.session.connected, isFalse);
      expect(harness.session.retryIn, isNotNull);

      // 第一次重连:1s 后
      async.elapse(const Duration(milliseconds: 999));
      expect(harness.connectCalls, 1);
      async.elapse(const Duration(milliseconds: 1));
      async.flushMicrotasks();
      expect(harness.connectCalls, 2);
      expect(harness.session.connected, isTrue);

      // 重进房带上 joinToken + memberToken 维持身份
      final rejoin = harness.transport.lastSentOfType('room:join');
      final payload = (rejoin!['payload'] as Map).cast<String, Object?>();
      expect(payload['roomCode'], 'ABC123');
      expect(payload['joinToken'], joinTokenA);
      expect(payload['memberToken'], memberTokenA);
      expect(harness.session.awaitingFreshRoomState, isTrue);
      harness.session.dispose();
    });
  });

  test('repeated connect failures back off 1s, 2s, 4s', () {
    fakeAsync((async) {
      final harness = Harness();
      harness.establishCreatedRoom(async);
      harness.failConnectsRemaining = 10;
      harness.transport.serverClose();
      async.flushMicrotasks();

      async.elapse(const Duration(seconds: 1));
      async.flushMicrotasks();
      expect(harness.connectCalls, 2); // 第 1 次重试(失败)

      async.elapse(const Duration(seconds: 2));
      async.flushMicrotasks();
      expect(harness.connectCalls, 3); // +2s 第 2 次

      async.elapse(const Duration(seconds: 3));
      async.flushMicrotasks();
      expect(harness.connectCalls, 3); // 4s 未到
      async.elapse(const Duration(seconds: 1));
      async.flushMicrotasks();
      expect(harness.connectCalls, 4); // +4s 第 3 次
      harness.session.dispose();
    });
  });

  test('no reconnect without a room session', () {
    fakeAsync((async) {
      final harness = Harness();
      harness.session.requestCreateRoom();
      async.flushMicrotasks();
      // 未建房完成就离开:清空会话
      harness.session.requestLeaveRoom();
      async.flushMicrotasks();
      final callsAfterLeave = harness.connectCalls;
      async.elapse(const Duration(minutes: 2));
      expect(harness.connectCalls, callsAfterLeave);
      harness.session.dispose();
    });
  });

  test('admin close reason tears down the session without reconnect', () {
    fakeAsync((async) {
      final harness = Harness();
      harness.establishCreatedRoom(async);

      harness.transport.serverClose('Admin closed room');
      async.flushMicrotasks();

      expect(harness.session.roomCode, isNull);
      expect(harness.session.memberToken, isNull);
      expect(harness.session.roomState, isNull);
      expect(harness.endedReasons, ['Admin closed room']);
      expect(harness.session.lastError, 'Admin closed room');

      final calls = harness.connectCalls;
      async.elapse(const Duration(minutes: 2));
      expect(harness.connectCalls, calls);
      harness.session.dispose();
    });
  });

  test(
    'member deltas during bootstrap are queued then merged into room:state',
    () {
      fakeAsync((async) {
        final harness = Harness();
        harness.establishCreatedRoom(async);

        // 断线重连,进入 bootstrap 窗口(room:joined 已到,room:state 未到)
        harness.transport.serverClose();
        async.elapse(const Duration(seconds: 1));
        async.flushMicrotasks();
        harness.transport.emit({
          'type': 'room:joined',
          'payload': {
            'roomCode': 'ABC123',
            'memberId': 'member-1',
            'memberToken': memberTokenA,
          },
        });
        async.flushMicrotasks();

        harness.transport.emit({
          'type': 'room:member-joined',
          'payload': {
            'roomCode': 'ABC123',
            'member': {'id': 'member-2', 'name': 'Bob'},
          },
        });
        async.flushMicrotasks();
        // bootstrap 窗口内不直接应用
        expect(harness.session.roomState!.members, hasLength(1));

        // 权威 room:state(不含 Bob)到达:排队的增量并入
        harness.transport.emit(roomStateMessage());
        async.flushMicrotasks();
        expect(harness.session.roomState!.members.map((member) => member.id), [
          'member-1',
          'member-2',
        ]);
        harness.session.dispose();
      });
    },
  );

  test('bootstrap timeout applies queued deltas but keeps awaiting flag', () {
    fakeAsync((async) {
      final harness = Harness();
      harness.establishCreatedRoom(async);

      harness.transport.serverClose();
      async.elapse(const Duration(seconds: 1));
      async.flushMicrotasks();
      harness.transport.emit({
        'type': 'room:joined',
        'payload': {
          'roomCode': 'ABC123',
          'memberId': 'member-1',
          'memberToken': memberTokenA,
        },
      });
      async.flushMicrotasks();
      harness.transport.emit({
        'type': 'room:member-left',
        'payload': {
          'roomCode': 'ABC123',
          'member': {'id': 'member-1', 'name': 'Alice'},
        },
      });
      async.flushMicrotasks();
      expect(harness.session.roomState!.members, hasLength(1));

      async.elapse(const Duration(seconds: 5));
      // 超时兜底:增量应用到手头快照
      expect(harness.session.roomState!.members, isEmpty);
      // 但 awaitingFreshRoomState 保持,直到真正的 room:state
      // (room-session-controller.ts: expireBootstrapRoomStateWait 注释)
      expect(harness.session.awaitingFreshRoomState, isTrue);
      harness.session.dispose();
    });
  });

  test('member deltas after bootstrap apply immediately', () {
    fakeAsync((async) {
      final harness = Harness();
      harness.establishCreatedRoom(async);

      harness.transport.emit({
        'type': 'room:member-joined',
        'payload': {
          'roomCode': 'ABC123',
          'member': {'id': 'member-2', 'name': 'Bob'},
        },
      });
      async.flushMicrotasks();
      expect(harness.session.roomState!.members, hasLength(2));

      harness.transport.emit({
        'type': 'room:member-left',
        'payload': {
          'roomCode': 'ABC123',
          'member': {'id': 'member-2', 'name': 'Bob'},
        },
      });
      async.flushMicrotasks();
      expect(harness.session.roomState!.members, hasLength(1));
      harness.session.dispose();
    });
  });

  test('member_token_invalid clears only the member token', () {
    fakeAsync((async) {
      final harness = Harness();
      harness.establishCreatedRoom(async);
      harness.transport.emit({
        'type': 'error',
        'payload': {'code': 'member_token_invalid', 'message': 'bad token'},
      });
      async.flushMicrotasks();
      expect(harness.session.memberToken, isNull);
      expect(harness.session.roomCode, 'ABC123');
      harness.session.dispose();
    });
  });

  test('stored room rejection clears context and reports session end', () {
    fakeAsync((async) {
      final harness = Harness();
      harness.establishCreatedRoom(async);
      harness.transport.emit({
        'type': 'error',
        'payload': {'code': 'room_not_found', 'message': 'Room not found'},
      });
      async.flushMicrotasks();
      expect(harness.session.roomCode, isNull);
      expect(harness.session.roomState, isNull);
      expect(harness.endedReasons, ['room_not_found']);
      harness.session.dispose();
    });
  });

  test('clock: pings on open and every 15s; pong updates offset', () {
    fakeAsync((async) {
      final harness = Harness();
      harness.establishCreatedRoom(async);

      expect(harness.transport.lastSentOfType('sync:ping'), isNotNull);
      final pingsAfterOpen = harness.transport.sentJson
          .where((message) => message['type'] == 'sync:ping')
          .length;

      harness.transport.emit({
        'type': 'sync:pong',
        'payload': {
          'clientSendTime': 1000,
          'serverReceiveTime': 1600,
          'serverSendTime': 1650,
        },
      });
      async.flushMicrotasks();
      expect(harness.session.clockOffsetMs, isNotNull);
      expect(harness.session.rttMs, isNotNull);

      async.elapse(const Duration(seconds: 15));
      final pingsLater = harness.transport.sentJson
          .where((message) => message['type'] == 'sync:ping')
          .length;
      expect(pingsLater, pingsAfterOpen + 1);
      harness.session.dispose();
    });
  });

  test('outbound actions are gated on connection and member token', () {
    fakeAsync((async) {
      final harness = Harness();
      const playback = PlaybackState(
        url: 'https://www.bilibili.com/video/BV1xx411c7mD',
        currentTime: 1,
        playState: PlaybackPlayState.playing,
        playbackRate: 1,
        updatedAt: 1,
        serverTime: 1,
        actorId: 'member-1',
        seq: 1,
      );
      // 未连接:静默丢弃,不抛错
      harness.session.sendPlaybackUpdate(playback);
      harness.session.requestSync();

      harness.establishCreatedRoom(async);
      harness.session.sendPlaybackUpdate(playback);
      harness.session.requestSync();
      expect(harness.transport.lastSentOfType('playback:update'), isNotNull);
      expect(harness.transport.lastSentOfType('sync:request'), isNotNull);
      harness.session.dispose();
    });
  });

  test('leave room sends room:leave and closes the transport', () {
    fakeAsync((async) {
      final harness = Harness();
      harness.establishCreatedRoom(async);
      harness.session.requestLeaveRoom();
      async.flushMicrotasks();

      final leave = harness.transport.lastSentOfType('room:leave');
      expect((leave!['payload'] as Map)['memberToken'], memberTokenA);
      expect(harness.transport.closedByClient, isTrue);
      expect(harness.session.roomCode, isNull);
      expect(harness.session.connected, isFalse);
      harness.session.dispose();
    });
  });

  group('播放锚点', () {
    test('a fresh playing snapshot is applied as the sender reported it', () {
      fakeAsync((async) {
        final harness = Harness();
        harness.establishCreatedRoom(async);
        harness.monotonicNowMs = 10000;
        harness.transport.emit(playingRoomStateMessage());
        async.flushMicrotasks();

        expect(harness.appliedStates.last.playback!.currentTime, 42);
        harness.session.dispose();
      });
    });

    test('a reported snapshot age is credited on arrival', () {
      fakeAsync((async) {
        final harness = Harness();
        harness.establishCreatedRoom(async);
        // 中途加入:服务端交来的快照在下发时已旧了 2s。
        harness.monotonicNowMs = 10000;
        harness.transport.emit(playingRoomStateMessage(playbackAgeMs: 2000));
        async.flushMicrotasks();

        expect(
          harness.appliedStates.last.playback!.currentTime,
          closeTo(44, 1e-9),
        );

        // 之后的读取继续从同一个锚点外推,而不是从施加那一刻。
        harness.monotonicNowMs = 13000;
        expect(
          harness.session.compensatedRoomState!.playback!.currentTime,
          closeTo(47, 1e-9),
        );
        harness.session.dispose();
      });
    });

    test('an implausible age falls back to anchoring at arrival', () {
      fakeAsync((async) {
        final harness = Harness();
        harness.establishCreatedRoom(async);
        harness.monotonicNowMs = 60000;
        harness.transport.emit(
          playingRoomStateMessage(playbackAgeMs: maxTrustedPlaybackAgeMs + 1),
        );
        async.flushMicrotasks();

        expect(harness.appliedStates.last.playback!.currentTime, 42);
        harness.session.dispose();
      });
    });

    test('serverTime alone never moves the applied position', () {
      // #210 的判据:同一份快照只把服务端打戳往前挪一大截(钟步进),施加的位置
      // 必须不变。
      double appliedWith(num serverTime) {
        late double applied;
        fakeAsync((async) {
          final harness = Harness();
          harness.establishCreatedRoom(async);
          harness.monotonicNowMs = 10000;
          harness.transport.emit(
            playingRoomStateMessage(serverTime: serverTime),
          );
          async.flushMicrotasks();
          applied = harness.appliedStates.last.playback!.currentTime;
          harness.session.dispose();
        });
        return applied;
      }

      expect(appliedWith(1000), appliedWith(1000 + 900000));
    });

    test('member deltas do not re-anchor the snapshot they carry', () {
      fakeAsync((async) {
        final harness = Harness();
        harness.establishCreatedRoom(async);
        harness.monotonicNowMs = 10000;
        harness.transport.emit(playingRoomStateMessage());
        async.flushMicrotasks();

        harness.monotonicNowMs = 13000;
        harness.transport.emit({
          'type': 'room:member-joined',
          'payload': {
            'roomCode': 'ABC123',
            'member': {'id': 'member-3', 'name': 'Carol'},
          },
        });
        async.flushMicrotasks();

        // 成员增量携带的是已到达的那份快照:位置按其到达以来真正流逝的 3s 前进,
        // 而不是重新从 0 开始。
        expect(
          harness.appliedStates.last.playback!.currentTime,
          closeTo(45, 1e-9),
        );
        harness.session.dispose();
      });
    });
  });
}
