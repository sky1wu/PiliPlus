/// 移植自 packages/protocol/test/video-ref.test.ts,逐条对应;
/// 末尾追加 buildBilibiliVideoRef 的移动端专属用例。
library;

import 'package:sync_play_core/sync_play_core.dart';
import 'package:test/test.dart';

void main() {
  test('parses a standard video URL', () {
    expect(
      parseBilibiliVideoRef('https://www.bilibili.com/video/BV1xx411c7mD'),
      const BilibiliVideoRef(
        videoId: 'BV1xx411c7mD',
        normalizedUrl: 'https://www.bilibili.com/video/BV1xx411c7mD',
      ),
    );
  });

  test('parses a bangumi URL', () {
    expect(
      parseBilibiliVideoRef('https://www.bilibili.com/bangumi/play/ep123456'),
      const BilibiliVideoRef(
        videoId: 'ep123456',
        normalizedUrl: 'https://www.bilibili.com/bangumi/play/ep123456',
      ),
    );
  });

  test('parses a festival URL carrying bvid and cid', () {
    expect(
      parseBilibiliVideoRef(
        'https://www.bilibili.com/festival/demo?bvid=BV1ab411c7mD&cid=987654',
      ),
      const BilibiliVideoRef(
        videoId: 'BV1ab411c7mD:987654',
        normalizedUrl: 'https://www.bilibili.com/video/BV1ab411c7mD?cid=987654',
      ),
    );
  });

  test('parses a paged video URL', () {
    expect(
      parseBilibiliVideoRef('https://www.bilibili.com/video/BV1xx411c7mD?p=3'),
      const BilibiliVideoRef(
        videoId: 'BV1xx411c7mD:p3',
        normalizedUrl: 'https://www.bilibili.com/video/BV1xx411c7mD?p=3',
      ),
    );
  });

  test('parses watchlater URLs only through explicit supported paths', () {
    expect(
      parseBilibiliVideoRef(
        'https://www.bilibili.com/list/watchlater?bvid=BV1xx411c7mD',
      ),
      const BilibiliVideoRef(
        videoId: 'BV1xx411c7mD',
        normalizedUrl: 'https://www.bilibili.com/video/BV1xx411c7mD',
      ),
    );
    expect(
      parseBilibiliVideoRef(
        'https://www.bilibili.com/medialist/play/watchlater?bvid=BV1xx411c7mD&cid=42',
      ),
      const BilibiliVideoRef(
        videoId: 'BV1xx411c7mD:42',
        normalizedUrl: 'https://www.bilibili.com/video/BV1xx411c7mD?cid=42',
      ),
    );
  });

  test('returns null for invalid or unsupported URLs', () {
    expect(parseBilibiliVideoRef('not-a-url'), isNull);
    expect(
      parseBilibiliVideoRef('https://www.bilibili.com/list/watchlater'),
      isNull,
    );
    expect(parseBilibiliVideoRef('https://example.com/anything'), isNull);
    expect(
      parseBilibiliVideoRef('https://evil.example/?bvid=BV1xx411c7mD'),
      isNull,
    );
    expect(
      parseBilibiliVideoRef(
        'https://evil.example/festival/demo?bvid=BV1ab411c7mD&cid=987654',
      ),
      isNull,
    );
    expect(
      parseBilibiliVideoRef(
        'https://www.bilibili.com/list/fav?bvid=BV1xx411c7mD',
      ),
      isNull,
    );
  });

  test('parses a video URL with cid and preserves it', () {
    expect(
      parseBilibiliVideoRef(
        'https://www.bilibili.com/video/BV1ab411c7mD?cid=987654',
      ),
      const BilibiliVideoRef(
        videoId: 'BV1ab411c7mD:987654',
        normalizedUrl: 'https://www.bilibili.com/video/BV1ab411c7mD?cid=987654',
      ),
    );
  });

  test('normalization is idempotent for festival URLs with cid', () {
    const festivalUrl =
        'https://www.bilibili.com/festival/demo?bvid=BV1ab411c7mD&cid=987654';
    final firstPass = normalizeBilibiliUrl(festivalUrl);
    expect(firstPass, 'https://www.bilibili.com/video/BV1ab411c7mD?cid=987654');
    final secondPass = normalizeBilibiliUrl(firstPass);
    expect(secondPass, firstPass);
  });

  test('normalizes supported URLs and rejects unsupported ones', () {
    expect(
      normalizeBilibiliUrl(
        'https://www.bilibili.com/festival/demo?cid=987654&bvid=BV1ab411c7mD',
      ),
      'https://www.bilibili.com/video/BV1ab411c7mD?cid=987654',
    );
    expect(
      normalizeBilibiliUrl(
        'https://www.bilibili.com/list/watchlater?bvid=BV1xx411c7mD&p=2',
      ),
      'https://www.bilibili.com/video/BV1xx411c7mD?p=2',
    );
    expect(
      normalizeBilibiliUrl('https://www.bilibili.com/list/watchlater'),
      isNull,
    );
    expect(
      normalizeBilibiliUrl(
        'https://evil.example/festival/demo?cid=987654&bvid=BV1ab411c7mD',
      ),
      isNull,
    );
  });

  group('buildBilibiliVideoRef (mobile-side construction)', () {
    test('builds refs that round-trip through parseBilibiliVideoRef', () {
      for (final built in [
        buildBilibiliVideoRef(bvid: 'BV1xx411c7mD'),
        buildBilibiliVideoRef(bvid: 'BV1xx411c7mD', cid: 987654),
        buildBilibiliVideoRef(bvid: 'BV1xx411c7mD', page: 3),
        // cid 优先于 page,与 TS 端规范化取值顺序一致
        buildBilibiliVideoRef(bvid: 'BV1xx411c7mD', cid: 42, page: 3),
      ]) {
        expect(built, isNotNull);
        expect(parseBilibiliVideoRef(built!.normalizedUrl), built);
      }
    });

    test('matches normalizeBilibiliUrl output byte-for-byte', () {
      expect(
        buildBilibiliVideoRef(bvid: 'BV1ab411c7mD', cid: 987654)!.normalizedUrl,
        normalizeBilibiliUrl(
          'https://www.bilibili.com/video/BV1ab411c7mD?cid=987654',
        ),
      );
      expect(
        buildBilibiliVideoRef(bvid: 'BV1xx411c7mD', page: 3)!.normalizedUrl,
        normalizeBilibiliUrl('https://www.bilibili.com/video/BV1xx411c7mD?p=3'),
      );
    });

    test('rejects invalid inputs', () {
      expect(buildBilibiliVideoRef(bvid: 'av170001'), isNull);
      expect(buildBilibiliVideoRef(bvid: 'not a bvid'), isNull);
      expect(buildBilibiliVideoRef(bvid: 'BV1xx411c7mD', cid: 0), isNull);
      expect(buildBilibiliVideoRef(bvid: 'BV1xx411c7mD', page: 0), isNull);
    });
  });

  group('buildBilibiliEpisodeRef (mobile-side construction)', () {
    test('round-trips and matches normalizeBilibiliUrl byte-for-byte', () {
      final built = buildBilibiliEpisodeRef(epId: 123456)!;
      expect(built.videoId, 'ep123456');
      expect(parseBilibiliVideoRef(built.normalizedUrl), built);
      expect(
        built.normalizedUrl,
        normalizeBilibiliUrl('https://www.bilibili.com/bangumi/play/ep123456'),
      );
    });

    test('rejects invalid epId', () {
      expect(buildBilibiliEpisodeRef(epId: 0), isNull);
      expect(buildBilibiliEpisodeRef(epId: -1), isNull);
    });
  });
}
