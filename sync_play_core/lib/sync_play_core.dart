/// Bili-SyncPlay 协议核心(纯 Dart,无 Flutter 依赖)。
///
/// 与 Bili-SyncPlay 仓库对照维护:
/// - 协议模型/守卫: packages/protocol/src/ (protocol v3)
/// - 时钟对时:     extension/src/background/clock-sync.ts
///
/// 协议侧有任何改动时,必须同步更新这里并补对照测试。
library;

export 'src/clock_sync.dart';
export 'src/client_messages.dart';
export 'src/common.dart';
export 'src/invite.dart';
export 'src/models.dart';
export 'src/player_sync.dart';
export 'src/server_messages.dart';
export 'src/session.dart';
export 'src/toast_plan.dart';
export 'src/transport.dart';
export 'src/video_ref.dart';
