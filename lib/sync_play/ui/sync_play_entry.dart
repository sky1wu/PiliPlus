import 'package:PiliPlus/sync_play/sync_play_messages.dart';
import 'package:PiliPlus/sync_play/ui/room_panel.dart';
import 'package:flutter/material.dart';

/// 一起看(Bili-SyncPlay)入口按钮。
///
/// 外观不随是否在房间内变化:入口和顶栏/详情页的其它图标并排,
/// 换色换实心会破坏整排图标的一致性,着重色在深色底上辨识度也不好。
/// 房间状态在面板里看。
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

  /// 图标色,默认跟随 IconTheme。
  final Color? color;
  final List<Shadow>? shadows;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      iconSize: iconSize,
      padding: padding,
      style: style,
      tooltip: SyncPlayMessages.title,
      onPressed: () => SyncPlayRoomPanel.show(context),
      icon: Icon(
        Icons.groups_outlined,
        color: color,
        shadows: shadows,
      ),
    );
  }
}
