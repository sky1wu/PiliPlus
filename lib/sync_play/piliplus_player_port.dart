import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/http/video.dart';
import 'package:PiliPlus/plugin/pl_player/controller.dart';
import 'package:PiliPlus/utils/page_utils.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:sync_play_core/sync_play_core.dart';

/// [SyncPlayPlayerPort] 的 PiliPlus 实现:施加动作走 PlPlayerController
/// 单例,切换视频走 PageUtils.toVideoPage。
///
/// 引擎在程序化施加窗口内调用这些方法,期间播放器回流的事件由引擎的
/// 回声抑制丢弃,这里不需要额外防护。
class PiliPlusPlayerPort implements SyncPlayPlayerPort {
  PlPlayerController? get _player => PlPlayerController.instance;

  @override
  Future<void> seekTo(double seconds) async {
    await _player?.seekTo(Duration(milliseconds: (seconds * 1000).round()));
  }

  @override
  Future<void> play() async {
    await _player?.play();
  }

  @override
  Future<void> pause() async {
    await _player?.pause();
  }

  @override
  Future<void> setRate(double rate) async {
    await _player?.setPlaybackSpeed(rate);
  }

  @override
  Future<void> openVideo(
    BilibiliVideoRef ref, {
    required double initialSeconds,
    required bool startPaused,
  }) async {
    // videoId 形态(protocol 约定):BVxxx / BVxxx:cid / BVxxx:pN / (ep|ss)N
    final parts = ref.videoId.split(':');
    final id = parts.first;
    if (!id.startsWith('BV')) {
      // v1 边界:仅支持普通视频(ugc)
      SmartDialog.showToast('Bili SyncPlay 暂不支持该视频类型($id)');
      return;
    }
    final suffix = parts.length > 1 ? parts[1] : null;
    int? cid;
    int? page;
    if (suffix != null) {
      if (suffix.startsWith('p')) {
        page = int.tryParse(suffix.substring(1));
      } else {
        cid = int.tryParse(suffix);
      }
    }

    String? title;
    String? cover;
    if (cid == null) {
      // 分享方是浏览器扩展时 URL 可能不带 cid:走视频详情接口换取
      final res = await VideoHttp.videoIntro(bvid: id);
      if (res case Success(:final response)) {
        title = response.title;
        cover = response.pic;
        final pages = response.pages;
        if (page != null && pages != null && page <= pages.length && page > 0) {
          cid = pages[page - 1].cid;
        }
        cid ??= response.cid;
      }
      if (cid == null) {
        SmartDialog.showToast('Bili SyncPlay:无法解析共享视频($id)');
        return;
      }
    }

    // autoPlay 强制目标页初始化播放器(用户关闭自动播放偏好时页面只显示
    // 封面、播放器不建立,同步无法接管)。startPaused 不在导航参数里表达:
    // 目标页加载完成后 service 会 requestSync 拉回权威房间状态,由引擎
    // 施加暂停/进度。
    await PageUtils.toVideoPage(
      bvid: id,
      cid: cid,
      progress: (initialSeconds * 1000).round(),
      title: title,
      cover: cover,
      extraArguments: const {'autoPlay': true},
    );
  }
}
