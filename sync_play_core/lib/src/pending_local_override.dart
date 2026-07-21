/// 本地显式操作的保护窗口,移植自 pending-local-override.ts。
///
/// 用户显式 seek(或改倍速)之后,本地播放器要过一段时间才真正落到目标;
/// 这期间房间里还在流转"我们操作之前"的状态。没有这道守卫的话,那些陈旧
/// 状态会被当成正常远端更新施加下来,把用户刚跳到的位置又拽回去。
///
/// 守卫在下列任一条件成立时解除:
/// - 本地位置已到目标(±[pendingLocalSeekSettleThresholdSeconds]);
/// - 收到自己 actorId 且 seq 不低于登记值的回流(对端已经看到我们的操作);
/// - 超过 [pendingLocalSeekGuardMs] / [pendingLocalRatechangeGuardMs]。
///
/// 移动端比浏览器端更依赖它:那边 seek 近乎瞬时,这边要 1–3 秒。
library;

import 'common.dart';
import 'models.dart';
import 'video_ref.dart';

const int pendingLocalSeekGuardMs = 5000;
const double pendingLocalSeekSettleThresholdSeconds = 0.35;
const int pendingLocalRatechangeGuardMs = 5000;
const double pendingLocalRatechangeSettleThreshold = 0.01;

enum PendingLocalOverrideKind { seek, ratechange }

/// 登记中的本地显式操作。
typedef PendingLocalOverride = ({
  PendingLocalOverrideKind kind,
  String url,
  num seq,
  num expiresAt,
  double? targetTime,
  double? playbackRate,
});

/// 守卫判定结果。[nextPending] 为守卫消解后应写回的状态(null 表示清除)。
typedef PendingLocalOverrideDecision = ({
  bool shouldIgnore,
  String? reason,
  PendingLocalOverride? nextPending,
});

const PendingLocalOverrideDecision _pass = (
  shouldIgnore: false,
  reason: null,
  nextPending: null,
);

/// pending-local-override.ts: rememberPendingLocalPlaybackOverride
///
/// 只有显式 seek、以及紧跟用户 ratechange 手势的广播才登记;
/// 其余广播不设守卫(它们本来就该让位于远端)。
PendingLocalOverride? rememberPendingLocalOverride({
  required PlaybackState payload,
  required num now,
  /// 该广播是否紧跟一次用户改倍速手势(调用方按手势宽限期判定)。
  bool followsUserRatechange = false,
}) {
  final url = normalizeBilibiliUrl(payload.url) ?? payload.url;
  if (payload.syncIntent == PlaybackSyncIntent.explicitSeek) {
    return (
      kind: PendingLocalOverrideKind.seek,
      url: url,
      seq: payload.seq,
      expiresAt: now + pendingLocalSeekGuardMs,
      targetTime: payload.currentTime,
      playbackRate: null,
    );
  }
  if (followsUserRatechange) {
    return (
      kind: PendingLocalOverrideKind.ratechange,
      url: url,
      seq: payload.seq,
      expiresAt: now + pendingLocalRatechangeGuardMs,
      targetTime: null,
      playbackRate: payload.playbackRate,
    );
  }
  return null;
}

/// pending-local-override.ts: getPendingLocalPlaybackOverrideDecision
PendingLocalOverrideDecision decidePendingLocalOverride({
  required PendingLocalOverride? pending,
  required PlaybackState? playback,
  required String? localMemberId,
  required num now,
}) {
  if (pending == null) {
    return _pass;
  }
  if (now >= pending.expiresAt) {
    return (shouldIgnore: false, reason: 'expired', nextPending: null);
  }
  if (playback == null) {
    return (shouldIgnore: false, reason: null, nextPending: pending);
  }

  // 别的视频的状态与本次操作无关,照常施加
  final normalizedUrl = normalizeBilibiliUrl(playback.url);
  if (normalizedUrl == null || normalizedUrl != pending.url) {
    return (shouldIgnore: false, reason: null, nextPending: pending);
  }

  // 自己的操作已经回流(seq 不低于登记值):房间已经看到了,守卫功成身退
  if (localMemberId != null &&
      playback.actorId == localMemberId &&
      playback.seq >= pending.seq) {
    return (
      shouldIgnore: false,
      reason: 'self-echo-ack',
      nextPending: null,
    );
  }

  return switch (pending.kind) {
    PendingLocalOverrideKind.seek => _decideSeek(pending, playback),
    PendingLocalOverrideKind.ratechange => _decideRate(pending, playback),
  };
}

PendingLocalOverrideDecision _decideSeek(
  PendingLocalOverride pending,
  PlaybackState playback,
) {
  final target = pending.targetTime;
  if (target == null) {
    return (shouldIgnore: false, reason: null, nextPending: pending);
  }
  // 远端位置已经和我们的目标一致:它跟上了,守卫解除
  if ((playback.currentTime - target).abs() <=
      pendingLocalSeekSettleThresholdSeconds) {
    return (shouldIgnore: false, reason: 'seek-settled', nextPending: null);
  }
  return (
    shouldIgnore: true,
    reason: 'pending-local-explicit-seek',
    nextPending: pending,
  );
}

PendingLocalOverrideDecision _decideRate(
  PendingLocalOverride pending,
  PlaybackState playback,
) {
  final target = pending.playbackRate;
  if (playback.playState != PlaybackPlayState.playing || target == null) {
    return (shouldIgnore: false, reason: null, nextPending: pending);
  }
  if ((playback.playbackRate - target).abs() <=
      pendingLocalRatechangeSettleThreshold) {
    return (shouldIgnore: false, reason: 'rate-settled', nextPending: null);
  }
  return (
    shouldIgnore: true,
    reason: 'pending-local-explicit-ratechange',
    nextPending: pending,
  );
}
