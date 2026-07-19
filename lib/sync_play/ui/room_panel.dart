import 'package:PiliPlus/sync_play/sync_play_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:sync_play_core/sync_play_core.dart';

/// "一起看"房间面板:建房/加入/成员列表/分享/离开。
/// 从播放器底部控制栏的按钮弹出(BottomSheet)。
class SyncPlayRoomPanel extends StatefulWidget {
  const SyncPlayRoomPanel({super.key});

  static Future<void> show(BuildContext context) => showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (context) => Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: const SyncPlayRoomPanel(),
    ),
  );

  @override
  State<SyncPlayRoomPanel> createState() => _SyncPlayRoomPanelState();
}

class _SyncPlayRoomPanelState extends State<SyncPlayRoomPanel> {
  SyncPlayService get service => SyncPlayService.to;

  late final TextEditingController _serverCtrl;
  late final TextEditingController _nameCtrl;
  final TextEditingController _roomCodeCtrl = TextEditingController();
  final TextEditingController _joinTokenCtrl = TextEditingController();
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _serverCtrl = TextEditingController(text: service.serverUrl);
    _nameCtrl = TextEditingController(text: service.displayName);
  }

  @override
  void dispose() {
    _serverCtrl.dispose();
    _nameCtrl.dispose();
    _roomCodeCtrl.dispose();
    _joinTokenCtrl.dispose();
    super.dispose();
  }

  bool _saveConnectionFields() {
    final server = _serverCtrl.text.trim();
    if (validateServerUrl(server) == null) {
      SmartDialog.showToast('请填写有效的服务器地址(ws:// 或 wss://)');
      return false;
    }
    service
      ..setServerUrl(server)
      ..setDisplayName(_nameCtrl.text);
    return true;
  }

  Future<void> _createRoom() async {
    if (!_saveConnectionFields()) {
      return;
    }
    setState(() => _busy = true);
    await service.createRoom();
    if (mounted) {
      setState(() => _busy = false);
    }
  }

  Future<void> _joinRoom() async {
    if (!_saveConnectionFields()) {
      return;
    }
    final roomCode = _roomCodeCtrl.text.trim();
    final joinToken = _joinTokenCtrl.text.trim();
    if (roomCode.isEmpty || joinToken.isEmpty) {
      SmartDialog.showToast('请填写房间号与加入口令');
      return;
    }
    setState(() => _busy = true);
    final result = await service.joinRoom(roomCode, joinToken);
    if (mounted) {
      setState(() => _busy = false);
    }
    switch (result) {
      case JoinAttemptResult.joined:
        SmartDialog.showToast('已加入房间');
      case JoinAttemptResult.failed:
        SmartDialog.showToast(service.session.lastError ?? '加入房间失败');
      case JoinAttemptResult.timeout:
        SmartDialog.showToast('加入房间超时,请检查服务器地址');
    }
  }

  void _copy(String label, String value) {
    Clipboard.setData(ClipboardData(text: value));
    SmartDialog.showToast('$label已复制');
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: service,
      builder: (context, _) {
        final session = service.session;
        return SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  const Icon(Icons.groups_outlined),
                  const SizedBox(width: 8),
                  Text('一起看', style: Theme.of(context).textTheme.titleMedium),
                  const Spacer(),
                  _StatusChip(status: session.status),
                ],
              ),
              const SizedBox(height: 12),
              if (session.lastError != null) ...[
                Text(
                  session.lastError!,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.error,
                    fontSize: 12,
                  ),
                ),
                const SizedBox(height: 8),
              ],
              if (!service.inRoom)
                ..._buildOutOfRoom(context)
              else
                ..._buildInRoom(context, session),
            ],
          ),
        );
      },
    );
  }

  List<Widget> _buildOutOfRoom(BuildContext context) => [
    TextField(
      controller: _serverCtrl,
      decoration: const InputDecoration(
        labelText: '服务器地址',
        hintText: 'wss://your-syncplay-server/ws',
        isDense: true,
      ),
      keyboardType: TextInputType.url,
    ),
    const SizedBox(height: 8),
    TextField(
      controller: _nameCtrl,
      decoration: const InputDecoration(labelText: '昵称(可选)', isDense: true),
      maxLength: 32,
    ),
    const SizedBox(height: 4),
    FilledButton.icon(
      onPressed: _busy ? null : _createRoom,
      icon: const Icon(Icons.add),
      label: const Text('创建房间'),
    ),
    const Divider(height: 32),
    TextField(
      controller: _roomCodeCtrl,
      decoration: const InputDecoration(
        labelText: '房间号',
        hintText: '6 位大写字母/数字',
        isDense: true,
      ),
      textCapitalization: TextCapitalization.characters,
    ),
    const SizedBox(height: 8),
    TextField(
      controller: _joinTokenCtrl,
      decoration: const InputDecoration(labelText: '加入口令', isDense: true),
    ),
    const SizedBox(height: 12),
    FilledButton.tonalIcon(
      onPressed: _busy ? null : _joinRoom,
      icon: const Icon(Icons.login),
      label: const Text('加入房间'),
    ),
  ];

  List<Widget> _buildInRoom(BuildContext context, SyncPlayRoomSession session) {
    final roomState = session.roomState;
    final sharedVideo = roomState?.sharedVideo;
    return [
      ListTile(
        contentPadding: EdgeInsets.zero,
        dense: true,
        title: Text('房间号:${session.roomCode}'),
        subtitle: const Text('点击复制房间号与口令,发给同伴加入'),
        trailing: const Icon(Icons.copy, size: 18),
        onTap: () =>
            _copy('房间信息', '房间号:${session.roomCode}\n口令:${session.joinToken}'),
      ),
      if (sharedVideo != null)
        ListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          leading: const Icon(Icons.play_circle_outline),
          title: Text(
            sharedVideo.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Text(
            '共享者:${sharedVideo.sharedByDisplayName ?? sharedVideo.sharedByMemberId ?? '未知'}',
          ),
        ),
      const SizedBox(height: 4),
      Text(
        '成员(${roomState?.members.length ?? 0})',
        style: Theme.of(context).textTheme.labelLarge,
      ),
      const SizedBox(height: 4),
      ...?roomState?.members.map(
        (member) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(
            children: [
              Icon(
                member.id == session.memberId
                    ? Icons.person
                    : Icons.person_outline,
                size: 16,
              ),
              const SizedBox(width: 6),
              Text(
                member.id == session.memberId
                    ? '${member.name}(我)'
                    : member.name,
              ),
              if (member.id == sharedVideo?.sharedByMemberId) ...[
                const SizedBox(width: 6),
                const Icon(Icons.cast, size: 14),
              ],
            ],
          ),
        ),
      ),
      const SizedBox(height: 16),
      FilledButton.icon(
        onPressed: () {
          service.shareCurrentVideo();
          Navigator.of(context).pop();
        },
        icon: const Icon(Icons.screen_share_outlined),
        label: const Text('分享当前视频'),
      ),
      const SizedBox(height: 8),
      OutlinedButton.icon(
        onPressed: () {
          service.leaveRoom();
          Navigator.of(context).pop();
        },
        icon: const Icon(Icons.logout),
        label: const Text('离开房间'),
      ),
    ];
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.status});

  final SyncPlayConnectionStatus status;

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (status) {
      SyncPlayConnectionStatus.connected => ('已连接', Colors.green),
      SyncPlayConnectionStatus.connecting => ('连接中', Colors.orange),
      SyncPlayConnectionStatus.disconnected => ('未连接', Colors.grey),
    };
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.circle, size: 8, color: color),
        const SizedBox(width: 4),
        Text(label, style: const TextStyle(fontSize: 12)),
      ],
    );
  }
}
