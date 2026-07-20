/// 对应 packages/protocol/src/video-ref.ts。
///
/// URL 规范化是协议的主键约定,任何行为调整必须与 TS 端同步,
/// 并保持 test/video_ref_test.dart 与 TS 端 video-ref.test.ts 用例一致。
library;

class BilibiliVideoRef {
  const BilibiliVideoRef({required this.videoId, required this.normalizedUrl});

  final String videoId;
  final String normalizedUrl;

  @override
  bool operator ==(Object other) =>
      other is BilibiliVideoRef &&
      other.videoId == videoId &&
      other.normalizedUrl == normalizedUrl;

  @override
  int get hashCode => Object.hash(videoId, normalizedUrl);

  @override
  String toString() =>
      'BilibiliVideoRef(videoId: $videoId, normalizedUrl: $normalizedUrl)';
}

const Set<String> _supportedBilibiliHosts = {'www.bilibili.com'};

final RegExp _trailingSlashes = RegExp(r'/+$');

({String kind, String id})? _parseSupportedBilibiliPath(String pathname) {
  final normalizedPath = pathname.replaceAll(_trailingSlashes, '');

  final videoMatch = RegExp(r'^/video/([^/?]+)$').firstMatch(normalizedPath);
  if (videoMatch != null) {
    return (kind: 'video', id: videoMatch.group(1)!);
  }

  final bangumiMatch = RegExp(
    r'^/bangumi/play/([^/?]+)$',
  ).firstMatch(normalizedPath);
  if (bangumiMatch != null) {
    return (kind: 'bangumi', id: bangumiMatch.group(1)!);
  }

  if (RegExp(r'^/festival/[^/?]+$').hasMatch(normalizedPath)) {
    return (kind: 'festival', id: normalizedPath);
  }

  if (normalizedPath == '/list/watchlater' ||
      normalizedPath == '/medialist/play/watchlater') {
    return (kind: 'watchlater', id: normalizedPath);
  }

  return null;
}

String? _nonEmpty(String? value) =>
    (value == null || value.isEmpty) ? null : value;

BilibiliVideoRef? parseBilibiliVideoRef(String? url) {
  if (url == null || url.isEmpty) {
    return null;
  }

  try {
    final parsed = Uri.parse(url);
    // TS 端接受任意 scheme 的 URL 对象;实际输入只会是 http(s),
    // 这里显式限定以避免 Uri.origin 对非 http(s) 抛错。
    if (parsed.scheme != 'http' && parsed.scheme != 'https') {
      return null;
    }
    if (!_supportedBilibiliHosts.contains(parsed.host)) {
      return null;
    }

    final supportedPath = _parseSupportedBilibiliPath(parsed.path);
    if (supportedPath == null) {
      return null;
    }

    final query = parsed.queryParameters;
    final bvid = _nonEmpty(query['bvid']);
    if ((supportedPath.kind == 'festival' ||
            supportedPath.kind == 'watchlater') &&
        bvid != null) {
      final cid = _nonEmpty(query['cid']);
      final p = _nonEmpty(query['p']);
      return BilibiliVideoRef(
        videoId: cid != null
            ? '$bvid:$cid'
            : p != null
            ? '$bvid:p$p'
            : bvid,
        normalizedUrl: cid != null
            ? 'https://www.bilibili.com/video/$bvid?cid=$cid'
            : p != null
            ? 'https://www.bilibili.com/video/$bvid?p=$p'
            : 'https://www.bilibili.com/video/$bvid',
      );
    }

    if (supportedPath.kind == 'watchlater') {
      return null;
    }

    final p = _nonEmpty(query['p']);
    final cid = supportedPath.kind == 'video' ? _nonEmpty(query['cid']) : null;
    final basePath =
        '${parsed.origin}${parsed.path.replaceAll(_trailingSlashes, '')}';
    final videoId = cid != null
        ? '${supportedPath.id}:$cid'
        : p != null
        ? '${supportedPath.id}:p$p'
        : supportedPath.id;
    final normalizedUrl = cid != null
        ? '$basePath?cid=$cid'
        : p != null
        ? '$basePath?p=$p'
        : basePath;
    return BilibiliVideoRef(videoId: videoId, normalizedUrl: normalizedUrl);
  } on FormatException {
    return null;
  }
}

String? normalizeBilibiliUrl(String? url) =>
    parseBilibiliVideoRef(url)?.normalizedUrl;

final RegExp _bvidPattern = RegExp(r'^BV[0-9A-Za-z]+$');

/// 移动端专用:从 PlPlayer 持有的 bvid/cid(或分 P 序号)直接构造视频引用,
/// 输出与 [normalizeBilibiliUrl] 的规范化结果逐字节一致(有对照测试保证)。
/// cid 优先于 page,与 TS 端规范化的取值顺序一致。
BilibiliVideoRef? buildBilibiliVideoRef({
  required String bvid,
  int? cid,
  int? page,
}) {
  if (!_bvidPattern.hasMatch(bvid)) {
    return null;
  }
  if (cid != null) {
    if (cid < 1) {
      return null;
    }
    return BilibiliVideoRef(
      videoId: '$bvid:$cid',
      normalizedUrl: 'https://www.bilibili.com/video/$bvid?cid=$cid',
    );
  }
  if (page != null) {
    if (page < 1) {
      return null;
    }
    return BilibiliVideoRef(
      videoId: '$bvid:p$page',
      normalizedUrl: 'https://www.bilibili.com/video/$bvid?p=$page',
    );
  }
  return BilibiliVideoRef(
    videoId: bvid,
    normalizedUrl: 'https://www.bilibili.com/video/$bvid',
  );
}

/// 移动端专用:从番剧 epId 构造视频引用,输出与 [normalizeBilibiliUrl]
/// 对 `/bangumi/play/epN` 的规范化结果逐字节一致(有对照测试保证)。
BilibiliVideoRef? buildBilibiliEpisodeRef({required int epId}) {
  if (epId < 1) {
    return null;
  }
  return BilibiliVideoRef(
    videoId: 'ep$epId',
    normalizedUrl: 'https://www.bilibili.com/bangumi/play/ep$epId',
  );
}
