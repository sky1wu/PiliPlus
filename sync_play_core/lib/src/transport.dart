/// WebSocket 传输抽象:会话层只依赖这个接口,测试用假实现,
/// 生产用 [WebSocketSyncPlayTransport](web_socket_channel 包装)。
library;

import 'package:web_socket_channel/web_socket_channel.dart';

abstract interface class SyncPlayTransport {
  /// 入站文本帧;连接关闭时 done(服务端异常关闭可能先 error 后 done)。
  Stream<String> get messages;

  void send(String text);

  Future<void> close();

  /// 服务端关闭帧携带的 reason;连接关闭前为 null。
  /// 管理后台踢人/关房通过这个字段识别(见 adminSessionResetReasons)。
  String? get closeReason;
}

/// 建立到 [uri] 的连接;失败时抛异常。
typedef SyncPlayTransportConnector =
    Future<SyncPlayTransport> Function(Uri uri);

class WebSocketSyncPlayTransport implements SyncPlayTransport {
  WebSocketSyncPlayTransport._(this._channel);

  final WebSocketChannel _channel;

  /// 默认 connector:握手完成(channel.ready)才算连接成功,
  /// 失败以异常抛出,与扩展端"open 事件前的 error 是握手失败"的语义对应。
  static Future<SyncPlayTransport> connect(Uri uri) async {
    final channel = WebSocketChannel.connect(uri);
    await channel.ready;
    return WebSocketSyncPlayTransport._(channel);
  }

  @override
  Stream<String> get messages =>
      _channel.stream.where((frame) => frame is String).cast<String>();

  @override
  void send(String text) => _channel.sink.add(text);

  @override
  Future<void> close() => _channel.sink.close();

  @override
  String? get closeReason => _channel.closeReason;
}
