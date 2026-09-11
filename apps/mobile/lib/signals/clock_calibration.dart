import 'dart:math' as math;

import '../prediction/prediction.dart';

const maximumExactTime = 9007199254740991;
bool validTime(Object? value) =>
    value is int && value >= 0 && value <= maximumExactTime;

/// An asymmetric RTT bound; no half-RTT or synchronized device UTC assumption.
/// The explicit prediction skew budget bounds HTTP uncertainty and source/server
/// skew. Local UTC jumps over min(50ms, budget) invalidate the sample. A sample
/// lasts at most 30 seconds; this is a conservative refusal limit, not evidence
/// of operational clock accuracy. Operational policy still requires approval.
class ClockCalibration {
  const ClockCalibration._(this.receivedMonotonicMs, this.receivedUtcMs,
      this.earliestServerUtcMs, this.latestServerUtcMs, this.skewBudgetMs);

  static const maximumLifetimeMs = 30000;
  final int receivedMonotonicMs;
  final int receivedUtcMs;
  final int earliestServerUtcMs;
  final int latestServerUtcMs;
  final int skewBudgetMs;

  static ClockCalibration? fromExchange({
    required int sentMonotonicMs,
    required int receivedMonotonicMs,
    required int sentUtcMs,
    required int receivedUtcMs,
    required Object? serverReceivedAtUtcMs,
    required Object? serverSentAtUtcMs,
    required int skewBudgetMs,
  }) {
    if (![
      sentMonotonicMs,
      receivedMonotonicMs,
      sentUtcMs,
      receivedUtcMs,
      serverReceivedAtUtcMs,
      serverSentAtUtcMs,
      skewBudgetMs
    ].every(validTime)) {
      return null;
    }
    final serverReceived = serverReceivedAtUtcMs as int;
    final serverSent = serverSentAtUtcMs as int;
    final rtt = receivedMonotonicMs - sentMonotonicMs;
    final processing = serverSent - serverReceived;
    if (rtt < 0 ||
        rtt > 5000 ||
        processing < 0 ||
        processing > rtt ||
        rtt - processing > skewBudgetMs ||
        ((receivedUtcMs - sentUtcMs) - rtt).abs() >
            math.min(50, skewBudgetMs) ||
        serverReceived + rtt > maximumExactTime) {
      return null;
    }
    return ClockCalibration._(receivedMonotonicMs, receivedUtcMs, serverSent,
        serverReceived + rtt, skewBudgetMs);
  }

  bool isValidAt({required int monotonicMs, required int utcMs}) {
    if (!validTime(monotonicMs) || !validTime(utcMs)) return false;
    final elapsed = monotonicMs - receivedMonotonicMs;
    return elapsed >= 0 &&
        elapsed < maximumLifetimeMs &&
        ((utcMs - receivedUtcMs) - elapsed).abs() <=
            math.min(50, skewBudgetMs) &&
        latestServerUtcMs + elapsed + skewBudgetMs <= maximumExactTime;
  }

  /// Source age includes all pre-server age and transit exactly once. Server
  /// sent time is not an additional subtraction from the source countdown.
  MonotonicSignalDeadline? deadline({
    required String eventKey,
    required int sourceObservedAtUtcMs,
    required int serverReceivedAtUtcMs,
    required int serverSentAtUtcMs,
    required int remainingAtSourceMs,
    required int expiresAtUtcMs,
    required int maxSignalAgeMs,
    required int monotonicMs,
    required int utcMs,
  }) {
    if (!isValidAt(monotonicMs: monotonicMs, utcMs: utcMs) ||
        ![
          sourceObservedAtUtcMs,
          serverReceivedAtUtcMs,
          serverSentAtUtcMs,
          remainingAtSourceMs,
          expiresAtUtcMs,
          maxSignalAgeMs
        ].every(validTime)) {
      return null;
    }
    final elapsed = monotonicMs - receivedMonotonicMs;
    final earliest = earliestServerUtcMs + elapsed;
    final latest = latestServerUtcMs + elapsed;
    if (sourceObservedAtUtcMs > serverReceivedAtUtcMs ||
        serverReceivedAtUtcMs > serverSentAtUtcMs ||
        serverSentAtUtcMs > latest ||
        sourceObservedAtUtcMs > latest ||
        expiresAtUtcMs <= latest + skewBudgetMs) {
      return null;
    }
    return MonotonicSignalDeadline.fromReceipt(
      eventKey: eventKey,
      remainingAtSourceMs: IntervalMs(
          earliestMs: remainingAtSourceMs, latestMs: remainingAtSourceMs),
      sourceAgeAtReceiptMs: IntervalMs(
        earliestMs:
            math.max(0, earliest - sourceObservedAtUtcMs - skewBudgetMs),
        latestMs: latest - sourceObservedAtUtcMs + skewBudgetMs,
      ),
      expiresInAtReceiptMs: expiresAtUtcMs - latest - skewBudgetMs,
      maxSignalAgeMs: maxSignalAgeMs,
      receivedMonotonicMs: monotonicMs,
    );
  }
}
