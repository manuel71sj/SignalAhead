import 'prediction.dart' show IntervalMs;

const _maximumExactInteger = 9007199254740991;

bool _validTime(int? value) =>
    value != null && value >= 0 && value <= _maximumExactInteger;

/// Immutable receipt-anchored signal lifetime in the device's monotonic domain.
///
/// sourceAgeAtReceiptMs must bound *all* source-to-device age, including UTC
/// offset uncertainty and transmission delay. expiresInAtReceiptMs is the
/// earliest possible server expiry minus latest possible receipt UTC time.
/// The caller must derive these from verified clock/unit evidence, not assume
/// an offset or subtract server monotonic time from device monotonic time.
/// No constructor here grants timing verification or operational approval.
class MonotonicSignalDeadline {
  const MonotonicSignalDeadline._({
    required this.eventKey,
    required this.receivedMonotonicMs,
    required this.observedMonotonicMs,
    required this.remainingAtReceiptMs,
    required this.ttlAtReceiptMs,
    required this.valid,
  });

  factory MonotonicSignalDeadline.fromReceipt({
    required String? eventKey,
    required IntervalMs? remainingAtSourceMs,
    required IntervalMs? sourceAgeAtReceiptMs,
    required int? expiresInAtReceiptMs,
    required int? maxSignalAgeMs,
    required int? receivedMonotonicMs,
  }) {
    final valid = eventKey != null &&
        eventKey.trim().isNotEmpty &&
        remainingAtSourceMs != null &&
        remainingAtSourceMs.isValid &&
        sourceAgeAtReceiptMs != null &&
        sourceAgeAtReceiptMs.isValid &&
        _validTime(expiresInAtReceiptMs) &&
        _validTime(maxSignalAgeMs) &&
        _validTime(receivedMonotonicMs);
    if (!valid) {
      return MonotonicSignalDeadline._(
        eventKey: eventKey,
        receivedMonotonicMs: receivedMonotonicMs,
        observedMonotonicMs: receivedMonotonicMs,
        remainingAtReceiptMs: null,
        ttlAtReceiptMs: null,
        valid: false,
      );
    }

    final earliest =
        remainingAtSourceMs.earliestMs! - sourceAgeAtReceiptMs.latestMs!;
    final latest =
        remainingAtSourceMs.latestMs! - sourceAgeAtReceiptMs.earliestMs!;
    final ageBudget = maxSignalAgeMs! - sourceAgeAtReceiptMs.latestMs!;
    final ttl =
        ageBudget < expiresInAtReceiptMs! ? ageBudget : expiresInAtReceiptMs;
    return MonotonicSignalDeadline._(
      eventKey: eventKey,
      receivedMonotonicMs: receivedMonotonicMs,
      observedMonotonicMs: receivedMonotonicMs,
      remainingAtReceiptMs: IntervalMs(
        earliestMs: earliest < 0 ? 0 : earliest,
        latestMs: latest < 0 ? 0 : latest,
      ),
      ttlAtReceiptMs: ttl < 0 ? 0 : ttl,
      valid: true,
    );
  }

  /// A source-backed identity, not a transport sequence or invented event ID.
  final String? eventKey;
  final int? receivedMonotonicMs;
  final int? observedMonotonicMs;
  final IntervalMs? remainingAtReceiptMs;
  final int? ttlAtReceiptMs;
  final bool valid;

  int? get elapsedMs =>
      valid ? observedMonotonicMs! - receivedMonotonicMs! : null;

  /// TTL equality and the earliest possible phase end both expire the signal.
  bool get fresh =>
      valid &&
      elapsedMs! < ttlAtReceiptMs! &&
      elapsedMs! < remainingAtReceiptMs!.earliestMs!;

  /// Source age was deducted at receipt; only device elapsed time is deducted
  /// here, always from the original receipt interval, never the prior result.
  IntervalMs? get remainingMs => fresh
      ? IntervalMs(
          earliestMs: remainingAtReceiptMs!.earliestMs! - elapsedMs!,
          latestMs: remainingAtReceiptMs!.latestMs! - elapsedMs!,
        )
      : null;

  /// Retain the returned model between evaluations. A rollback freezes time at
  /// the high-water mark and cannot restore freshness or increase remaining.
  /// Invalid clock readings invalidate this event permanently.
  MonotonicSignalDeadline advanceTo(int? nowMonotonicMs) {
    if (!valid) return this;
    if (!_validTime(nowMonotonicMs)) {
      return MonotonicSignalDeadline._(
        eventKey: eventKey,
        receivedMonotonicMs: receivedMonotonicMs,
        observedMonotonicMs: observedMonotonicMs,
        remainingAtReceiptMs: remainingAtReceiptMs,
        ttlAtReceiptMs: ttlAtReceiptMs,
        valid: false,
      );
    }
    if (nowMonotonicMs! <= observedMonotonicMs!) return this;
    return MonotonicSignalDeadline._(
      eventKey: eventKey,
      receivedMonotonicMs: receivedMonotonicMs,
      observedMonotonicMs: nowMonotonicMs,
      remainingAtReceiptMs: remainingAtReceiptMs,
      ttlAtReceiptMs: ttlAtReceiptMs,
      valid: true,
    );
  }

  /// Repeated receipts never re-anchor their event's lifetime. A different
  /// identity alone is also insufficient: the caller must have evidence of a
  /// newer *source* event. Reconnect/request/stream sequence changes are not
  /// such evidence. Unknown source ordering keeps the original deadline.
  /// A newly verified event with invalid timing invalidates the old event.
  MonotonicSignalDeadline acceptReceipt(
    MonotonicSignalDeadline candidate, {
    required int? nowMonotonicMs,
    required bool verifiedNewerSourceEvent,
  }) {
    final current = advanceTo(nowMonotonicMs);
    if (!verifiedNewerSourceEvent ||
        candidate.eventKey == eventKey ||
        candidate.eventKey == null ||
        candidate.eventKey!.trim().isEmpty) {
      return current;
    }
    // A receipt stamped before an observed instant cannot establish a later
    // event on this monotonic timeline. Do not reset on a clock-domain change.
    if (!_validTime(nowMonotonicMs) ||
        !_validTime(candidate.receivedMonotonicMs) ||
        (observedMonotonicMs != null &&
            candidate.receivedMonotonicMs! < observedMonotonicMs!) ||
        candidate.receivedMonotonicMs! > nowMonotonicMs!) {
      return current;
    }
    return candidate.advanceTo(current.observedMonotonicMs ?? nowMonotonicMs);
  }
}
