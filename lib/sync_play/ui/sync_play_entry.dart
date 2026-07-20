import 'package:PiliPlus/sync_play/sync_play_messages.dart';
import 'package:PiliPlus/sync_play/sync_play_service.dart';
import 'package:PiliPlus/sync_play/ui/room_panel.dart';
import 'package:flutter/material.dart';

/// 一起看(Bili-SyncPlay)入口按钮。
///
/// 在房间内时图标转为实心并着重色,与播放控件里的 syncPlay 按钮
/// (pl_player/view/view.dart: BottomControlType.syncPlay)保持一致,
/// 这样不管在哪个页面都能一眼看出当前是否在房间里。
class SyncPlayEntryButton extends StatelessWidget {
  const SyncPlayEntryButton({
    super.key,
    this.iconSize,
    this.padding,
    this.style,
    this.color,
    this.shadows,
  });

  final double? iconSize;
  final EdgeInsetsGeometry? padding;
  final ButtonStyle? style;

  /// 不在房间时的图标色(默认跟随 IconTheme);在房间时一律用着重色。
  final Color? color;
  final List<Shadow>? shadows;

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    return ListenableBuilder(
      listenable: SyncPlayService.to,
      builder: (context, _) {
        final inRoom = SyncPlayService.to.inRoom;
        return IconButton(
          iconSize: iconSize,
          padding: padding,
          style: style,
          tooltip: SyncPlayMessages.title,
          onPressed: () => SyncPlayRoomPanel.show(context),
          icon: Icon(
            inRoom ? Icons.groups : Icons.groups_outlined,
            color: inRoom ? primary : color,
            shadows: shadows,
          ),
        );
      },
    );
  }
}
