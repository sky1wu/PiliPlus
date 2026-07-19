import 'package:sync_play_core/sync_play_core.dart';

/// 用户可见文案,逐条对齐浏览器扩展 extension/src/shared/i18n.ts 的 zh 目录。
/// 新增文案前先查扩展端是否已有对应条目。
abstract final class SyncPlayMessages {
  static const String title = 'Bili SyncPlay';
  static const String statusConnected = '已连接';
  static const String statusDisconnected = '未连接';
  static const String statusConnecting = '连接中'; // 扩展无此瞬时态,移动端补充
  static const String actionCreate = '创建';
  static const String actionJoin = '加入';
  static const String actionLeave = '退出';
  static const String roomCodeLabel = '房间码';
  static const String roomCodePlaceholder = '输入房间码';
  static const String serverUrlLabel = '服务器地址';
  static const String sectionSharedVideo = '当前共享视频';
  static const String stateNoSharedVideo = '暂无共享视频';
  static const String sectionRoomMembers = '成员';
  static const String stateNoMembers = '暂无成员';
  static const String actionShareCurrentVideo = '同步当前页视频';
  static const String pageShareSuccess = '已同步当前页视频';
  static const String errorInvalidInviteFormat = '邀请格式无效，请输入“房间码:加入码”。';
  static const String invalidServerUrl = '服务端地址必须以 ws:// 或 wss:// 开头。';
  static const String connectionServerUnreachable = '无法连接到同步服务器。';
  static const String connectionLostReconnecting = '与同步服务器的连接已断开，正在尝试重连。';

  static String ownerSharedBy(String owner) => '由 $owner 共享';

  static String memberSelf(String name) => '我 ($name)';

  static String membersCount(int count) => '$count人';

  /// i18n.ts: localizeServerError 的 zh 分支;未知码回退服务端原始消息。
  static String localizeServerError(String code, String fallback) =>
      switch (code) {
        SyncPlayErrorCode.roomNotFound => '房间不存在。',
        SyncPlayErrorCode.joinTokenInvalid => '加入码无效，请检查后重试。',
        SyncPlayErrorCode.memberTokenInvalid => '成员令牌无效，请重新加入房间。',
        SyncPlayErrorCode.notInRoom => '请先加入房间。',
        SyncPlayErrorCode.rateLimited => '请求过于频繁，请稍后再试。',
        SyncPlayErrorCode.roomFull => '房间已满。',
        SyncPlayErrorCode.invalidMessage => '当前请求无效。',
        SyncPlayErrorCode.internalError => '服务器内部错误。',
        // 扩展端原文为"扩展版本过低",移动端相应调整主语
        SyncPlayErrorCode.unsupportedProtocolVersion =>
          '客户端版本过低，请升级 Bili SyncPlay 到最新版本。',
        _ => fallback,
      };

  /// 会话终结原因:admin close reason 对齐 i18n.ts 的三条 admin 文案,
  /// 存量房间被服务端拒绝时是错误码,套 leftRoomWithReason 格式。
  static String localizeSessionEndReason(String reason) => switch (reason) {
    'Admin kicked member' => '你已被管理员移出房间。',
    'Admin disconnected session' => '你的连接已被管理员断开。',
    'Admin closed room' => '当前房间已被管理员关闭。',
    _ => '已退出房间：${localizeServerError(reason, reason)}',
  };

  /// 会话层连接类 lastError(英文内部文案)转用户可见文案。
  static String? localizeSessionError(String? lastError) {
    if (lastError == null) {
      return null;
    }
    if (lastError.startsWith('connection failed')) {
      return connectionServerUnreachable;
    }
    if (lastError.startsWith('invalid server url')) {
      return invalidServerUrl;
    }
    return lastError;
  }
}
