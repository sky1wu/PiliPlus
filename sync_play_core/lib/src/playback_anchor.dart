/// 对应 extension/src/background/clock-controller.ts 中的播放快照锚点部分
/// (ping 定时器与消息收发在本移植里归 session.dart)。
library;

import 'clock_sync.dart';
import 'common.dart';
import 'models.dart';

/// clock-controller.ts: playbackSnapshotKey——播放快照的身份。同一份快照的两次
/// 广播共享它,两份不同的快照必须不同。
///
/// serverTime 在这里是服务端给快照的版本号——只做相等比较,绝不与本地时刻相减
/// (那正是本模块要避免的事)。少了它这个身份是可伪造的:seq 是每个内容脚本
/// (本移植里为每个播放器会话)自己的计数器,重载后从 0 重来,一个重载后恰好停在
/// 早期 seq 快照报过的位置的成员会造出见过的 key,而那份更早快照的锚点还立着——
/// 于是把这中间发生的一切都加进了播放位置。
String playbackSnapshotKey(PlaybackState playback) => [
  playback.actorId,
  playback.seq,
  playback.serverTime,
  playback.playState.wire,
  playback.url,
  playback.currentTime,
  playback.playbackRate,
].join('|');

/// clock-controller.ts 的锚点状态机:记住"当前正在外推的这份快照是什么时候到的",
/// 并据此把 playing 快照推进到此刻。
class PlaybackAnchorTracker {
  PlaybackAnchorTracker(this._monotonicNowMs);

  /// 锚点用的单调时间源。不能用墙钟:锚点的全部意义就是不受钟调整影响。
  final double Function() _monotonicNowMs;

  String? _anchorKey;
  double? _anchorAtMs;

  /// clock-controller.ts: markPlaybackArrival——在任何其他人能观察到这份快照之前,
  /// 以本地单调时间记下它的位置在何时为真。
  ///
  /// 在入口打戳而不是等到第一次 compensate,把"该由哪个调用方提供锚点"这个问题
  /// 从局面里拿掉:快照落地后就可能被别处读到或重包(成员增删),谁先补偿谁就会
  /// 拿自己那个更晚的时刻当锚点,中间房间播过的部分就丢了。
  void markPlaybackArrival(PlaybackState? playback, double atMs) {
    if (playback == null || playback.playState != PlaybackPlayState.playing) {
      // 锚点只描述房间当前正在播出的那份快照。丢掉它,可以避免一个旧锚点活过一次
      // 暂停,从而没有任何后续快照会被跨越暂停区间外推。
      _anchorKey = null;
      _anchorAtMs = null;
      return;
    }

    final key = playbackSnapshotKey(playback);
    if (_anchorKey != key) {
      _anchorKey = key;
      _anchorAtMs = atMs;
      return;
    }
    // 只会往更早改。同一份快照可能被呈现多次(重播、回放),而房间从第一次到达起
    // 就在那个位置上,最早的证据就是最好的证据。计入 playbackAgeMs 之后,同一份
    // 快照的两次到达无论隔多远都会解析到同一个锚点,所以这里只会丢弃某个读取方
    // 迟到的、未计年龄的猜测。
    if (atMs < _anchorAtMs!) {
      _anchorAtMs = atMs;
    }
  }

  /// clock-controller.ts: compensateRoomState——把房间状态的播放位置推进到此刻。
  ///
  /// 流逝时间从这份快照到达时算起、在本地单调钟上量,绝不拿 serverTime 与本地
  /// 时刻相比(见 [extrapolatePlayingRoomState])。因此刚到达的快照原样透传,
  /// 而一次回放(晚绑定的播放器、UI 来问当前状态)会被推进真正过去的那段时间。
  ///
  /// [anchorAtMs](单调,与本跟踪器同源)是该快照位置在本机为真的时刻,处理新到
  /// room:state 的调用方必须传:到达与此处之间的工作不是瞬时的,在此处才打锚点
  /// 等于把那段时间算给了没有人。它等于到达时刻减去到达时快照已有的年龄,见
  /// [resolvePlaybackAnchorAtMs]。只有在回放一份已锚定的快照时才可省略。
  RoomState compensateRoomState(RoomState state, {double? anchorAtMs}) {
    final playback = state.playback;
    if (playback == null || playback.playState != PlaybackPlayState.playing) {
      _anchorKey = null;
      _anchorAtMs = null;
      return state;
    }

    final now = _monotonicNowMs();
    // 入口没打过锚点时补打(例如回放一份跨会话恢复来的快照),并纠正某个读取方
    // 迟打的锚点。
    markPlaybackArrival(playback, anchorAtMs ?? now);
    return extrapolatePlayingRoomState(state, now - _anchorAtMs!);
  }

  /// 会话清场时丢弃锚点(离房、被踢、连接重置)。
  void reset() {
    _anchorKey = null;
    _anchorAtMs = null;
  }
}
