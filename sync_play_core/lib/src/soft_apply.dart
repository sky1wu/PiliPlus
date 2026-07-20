/// 软施加(soft-apply)的纯计算部分,移植自扩展 content 侧的
/// player-binding.ts(速率/步进公式)与 soft-apply-controller.ts(时限)。
///
/// 目的:漂移在中间档时用**微调倍速**慢慢追平,而不是跳帧。浏览器端这么做
/// 是为了观感;移动端更刚性——一次 seek 要 1–3s 重新缓冲,缓冲本身又制造新
/// 漂移,硬 seek 会自我循环(见 player_sync.dart 的 programmaticSeekSettle*)。
///
/// 分档由 decidePlaybackReconcileMode 给出(player_sync.dart):
/// - rateOnly (0.45–0.9s):只动倍速,不写进度;按"相对漂移消化完"计时恢复
/// - softApply (0.9–1.2s):微调倍速 + 最多 0.4s 的小步进度修正;
///   本地位置追到目标 ±0.2s 即收敛,或超时恢复
library;

// ---- player-binding.ts ----
const double softApplyStepSeconds = 0.22;
const double softApplyMaxStepSeconds = 0.4;
const double softApplyRateOffset = 0.12;

// ---- soft-apply-controller.ts ----

/// 本地位置进入目标的这个范围即认为追平。
const double softApplyRecoveryThresholdSeconds = 0.2;
const int softApplyMinTimeoutMs = 2000;
const int softApplyMaxTimeoutMs = 4500;
const int softApplyTimeoutPerSecondMs = 900;
const double softApplyRttTimeoutFactor = 2.5;

/// 会话进行中目标位置挪动超过这个量,说明远端又动了,放弃本次追平。
const double softApplyTargetShiftCancelThresholdSeconds = 0.6;

/// 一次真正的 softApply 收敛后的冷却期:期间不再响应 rateOnly/softApply
/// 档的远端状态,避免刚追平又被下一拍触发。
const int softApplyCooldownMs = 2500;

const int rateOnlyMinRestoreMs = 600;
const int rateOnlyMaxRestoreMs = 8000;

/// 随倍速放宽的调节参数(player-binding.ts: getPlaybackAdjustmentTuning)。
typedef PlaybackAdjustmentTuning = ({
  double rateOffsetLimit,
  double minPlaybackRate,
  double maxPlaybackRate,
  double minStepSeconds,
  double maxStepSeconds,
  double stepScale,
});

PlaybackAdjustmentTuning playbackAdjustmentTuning(double basePlaybackRate) {
  final normalizedRate = basePlaybackRate > 1 ? basePlaybackRate : 1.0;
  final extraRate = normalizedRate - 1;
  final rateOffsetLimit = _min(0.26, softApplyRateOffset + extraRate * 0.1);
  return (
    rateOffsetLimit: rateOffsetLimit,
    minPlaybackRate: _max(0.1, basePlaybackRate - rateOffsetLimit),
    maxPlaybackRate: basePlaybackRate + rateOffsetLimit,
    minStepSeconds: _max(0.16, softApplyStepSeconds - extraRate * 0.03),
    maxStepSeconds: _max(0.28, softApplyMaxStepSeconds - extraRate * 0.08),
    stepScale: _max(0.3, 0.45 - extraRate * 0.08),
  );
}

/// player-binding.ts: getRateAdjustedPlaybackRate。
/// 落后就略微加速、超前就略微减速,偏移量与漂移成正比并被夹住。
double rateAdjustedPlaybackRate({
  required double localCurrentTime,
  required double targetTime,
  required double basePlaybackRate,
}) {
  final tuning = playbackAdjustmentTuning(basePlaybackRate);
  final drift = targetTime - localCurrentTime;
  final rateOffset = _clamp(
    drift * 0.18,
    -tuning.rateOffsetLimit,
    tuning.rateOffsetLimit,
  );
  return _clamp(
    basePlaybackRate + rateOffset,
    tuning.minPlaybackRate,
    tuning.maxPlaybackRate,
  );
}

/// player-binding.ts: getSoftApplySignature——softApply 档同时给出微调后的
/// 倍速和一小步进度修正(单次最多 maxStepSeconds,所以不是可感知的跳帧)。
({double currentTime, double playbackRate}) softApplySignature({
  required double localCurrentTime,
  required double targetTime,
  required double basePlaybackRate,
}) {
  final tuning = playbackAdjustmentTuning(basePlaybackRate);
  final playbackRate = rateAdjustedPlaybackRate(
    localCurrentTime: localCurrentTime,
    targetTime: targetTime,
    basePlaybackRate: basePlaybackRate,
  );
  final drift = targetTime - localCurrentTime;
  final stepLimit = _min(
    tuning.maxStepSeconds,
    _max(tuning.minStepSeconds, drift.abs() * tuning.stepScale),
  );
  return (
    currentTime: localCurrentTime + _clamp(drift, -stepLimit, stepLimit),
    playbackRate: playbackRate,
  );
}

/// soft-apply-controller.ts: computeSoftApplyTimeoutMs。
int softApplyTimeoutMs({required double remainingDriftSeconds, double? rttMs}) {
  final networkAllowanceMs = rttMs == null
      ? 0
      : (rttMs * softApplyRttTimeoutFactor).round();
  final driftAllowance =
      _max(0, remainingDriftSeconds - softApplyRecoveryThresholdSeconds) *
      softApplyTimeoutPerSecondMs;
  final raw = softApplyMinTimeoutMs + networkAllowanceMs + driftAllowance;
  return _clamp(
    raw.roundToDouble(),
    softApplyMinTimeoutMs.toDouble(),
    softApplyMaxTimeoutMs.toDouble(),
  ).round();
}

/// soft-apply-controller.ts: computeRelativeDriftCloseMs。
///
/// rateOnly 档不会"追到目标"——远端也在前进,快照目标一到手就过期了。
/// 恢复时机改按"这点倍速偏移消化掉初始漂移需要多久"算:drift / rateOffset。
int relativeDriftCloseMs({
  required double driftSeconds,
  required double rateOffsetSeconds,
}) {
  final offset = _max(0.01, rateOffsetSeconds.abs());
  final closeMs = (driftSeconds.abs() / offset) * 1000;
  return _clamp(
    closeMs.roundToDouble(),
    rateOnlyMinRestoreMs.toDouble(),
    rateOnlyMaxRestoreMs.toDouble(),
  ).round();
}

double _clamp(double value, double lo, double hi) =>
    value < lo ? lo : (value > hi ? hi : value);
double _min(double a, double b) => a < b ? a : b;
double _max(double a, double b) => a > b ? a : b;
