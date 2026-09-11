import 'package:flutter_test/flutter_test.dart';
import 'package:signalahead_mobile/prediction/prediction.dart';

MonotonicSignalDeadline receipt({
  String? eventKey = 'verified-source-event-1',
  IntervalMs? remainingAtSourceMs =
      const IntervalMs(earliestMs: 20000, latestMs: 26000),
  IntervalMs? sourceAgeAtReceiptMs =
      const IntervalMs(earliestMs: 1000, latestMs: 3000),
  int? expiresInAtReceiptMs = 10000,
  int? maxSignalAgeMs = 12000,
  int? receivedMonotonicMs = 1000,
}) =>
    MonotonicSignalDeadline.fromReceipt(
      eventKey: eventKey,
      remainingAtSourceMs: remainingAtSourceMs,
      sourceAgeAtReceiptMs: sourceAgeAtReceiptMs,
      expiresInAtReceiptMs: expiresInAtReceiptMs,
      maxSignalAgeMs: maxSignalAgeMs,
      receivedMonotonicMs: receivedMonotonicMs,
    );

PredictionResult predict(MonotonicSignalDeadline deadline) =>
    evaluatePrediction(
      PredictionInput(
        sessionActive: true,
        targetMatched: true,
        signalState: SignalState.green,
        signalFresh: deadline.fresh,
        timingQuality: TimingQuality.verified,
        locationValid: true,
        horizontalAccuracyM: 1,
        distanceM: const NumericInterval(min: 1, max: 2),
        speedMps: const NumericInterval(min: 1, max: 1),
        greenRemainingMs: deadline.remainingMs,
        syntheticFixture: true,
      ),
      const PredictionPolicy.syntheticFixture(
        maxSignalAgeMs: 12000,
        clockSkewBudgetMs: 100,
        minimumSpeedMps: 0.1,
        maxHorizontalAccuracyM: 10,
        extraSafetyMarginMs: 0,
      ),
    );

void main() {
  test('source age and offset/delay uncertainty are deducted exactly once', () {
    final deadline = receipt();
    expect(deadline.remainingMs!.earliestMs, 17000);
    expect(deadline.remainingMs!.latestMs, 25000);
    final later = deadline.advanceTo(2000).advanceTo(3000);
    expect(later.remainingMs!.earliestMs, 15000);
    expect(later.remainingMs!.latestMs, 23000);
    expect(later.advanceTo(3000).remainingMs!.toJson(),
        later.remainingMs!.toJson());
    expect(deadline.advanceTo(3000).remainingMs!.toJson(),
        later.remainingMs!.toJson());
  });

  test('SA-10 TTL just before evaluates, equality and afterwards are stale',
      () {
    // max source age 12000 - worst age at receipt 3000 = 9000ms lifetime.
    final deadline = receipt();
    expect(predict(deadline.advanceTo(9999)).status, PredictionStatus.possible);
    final atExpiry = predict(deadline.advanceTo(10000));
    expect(atExpiry.status, PredictionStatus.unknown);
    expect(atExpiry.reason, PredictionReason.signalStale);
    expect(deadline.advanceTo(10001).remainingMs, isNull);
    expect(atExpiry.signalStateAtDecision, SignalState.green);
  });

  test('server expiry also limits lifetime before the maximum source age', () {
    final deadline = receipt(expiresInAtReceiptMs: 500);
    expect(deadline.advanceTo(1499).fresh, isTrue);
    expect(deadline.advanceTo(1500).fresh, isFalse);
  });

  test('earliest possible phase end invalidates without inventing next color',
      () {
    final deadline = receipt(
      remainingAtSourceMs: const IntervalMs(earliestMs: 3500, latestMs: 9000),
    );
    expect(deadline.advanceTo(1499).fresh, isTrue);
    expect(deadline.advanceTo(1500).remainingMs, isNull);
    final result = predict(deadline.advanceTo(1500));
    expect(result.status, PredictionStatus.unknown);
    expect(result.reason, PredictionReason.signalStale);
    expect(result.signalStateAtDecision, SignalState.green);
  });

  test('clock rollback cannot increase remaining or revive expired data', () {
    final later = receipt().advanceTo(5000);
    expect(later.advanceTo(2000).remainingMs!.toJson(),
        later.remainingMs!.toJson());
    final expired = later.advanceTo(10000);
    expect(expired.advanceTo(1000).fresh, isFalse);
    expect(expired.advanceTo(1000).remainingMs, isNull);
  });

  test('invalid device time permanently invalidates the same event', () {
    for (final now in <int?>[null, -1]) {
      final invalid = receipt().advanceTo(now);
      expect(invalid.fresh, isFalse);
      expect(invalid.advanceTo(2000).fresh, isFalse);
    }
  });

  test('repeated source events never reset countdown or TTL, even after expiry',
      () {
    var deadline = receipt();
    deadline = deadline.acceptReceipt(
      receipt(receivedMonotonicMs: 5000),
      nowMonotonicMs: 5000,
      verifiedNewerSourceEvent: true,
    );
    expect(deadline.remainingMs!.earliestMs, 13000);
    deadline = deadline.acceptReceipt(
      receipt(receivedMonotonicMs: 10000),
      nowMonotonicMs: 10000,
      verifiedNewerSourceEvent: true,
    );
    expect(deadline.fresh, isFalse);
  });

  test('new transport identity without source ordering cannot extend lifetime',
      () {
    final deadline = receipt().acceptReceipt(
      receipt(
          eventKey: 'different-transport-event', receivedMonotonicMs: 10000),
      nowMonotonicMs: 10000,
      verifiedNewerSourceEvent: false,
    );
    expect(deadline.fresh, isFalse);
  });

  test('verified newer source event can establish its own lifetime', () {
    final deadline = receipt().advanceTo(5000).acceptReceipt(
          receipt(
              eventKey: 'verified-source-event-2', receivedMonotonicMs: 6000),
          nowMonotonicMs: 6500,
          verifiedNewerSourceEvent: true,
        );
    expect(deadline.remainingMs!.earliestMs, 16500);
    expect(deadline.advanceTo(14999).fresh, isTrue);
    expect(deadline.advanceTo(15000).fresh, isFalse);
  });

  test('a newly verified event with unknown timing invalidates old green', () {
    final deadline = receipt().acceptReceipt(
      receipt(
          eventKey: 'verified-source-event-2',
          receivedMonotonicMs: 6000,
          remainingAtSourceMs: null),
      nowMonotonicMs: 6000,
      verifiedNewerSourceEvent: true,
    );
    expect(deadline.fresh, isFalse);
    expect(deadline.remainingMs, isNull);
  });

  test('receipt timestamp rollback cannot establish a later source lifetime',
      () {
    final deadline = receipt().advanceTo(5000);
    final rolledBack = deadline.acceptReceipt(
      receipt(eventKey: 'verified-source-event-2', receivedMonotonicMs: 2000),
      nowMonotonicMs: 2000,
      verifiedNewerSourceEvent: true,
    );
    expect(rolledBack.remainingMs!.toJson(), deadline.remainingMs!.toJson());
  });

  test('missing timing, expired ages and invalid bounds fail closed at receipt',
      () {
    for (final deadline in [
      receipt(eventKey: null),
      receipt(remainingAtSourceMs: null),
      receipt(sourceAgeAtReceiptMs: null),
      receipt(
          sourceAgeAtReceiptMs:
              const IntervalMs(earliestMs: 3000, latestMs: 1000)),
      receipt(expiresInAtReceiptMs: null),
      receipt(expiresInAtReceiptMs: -1),
      receipt(expiresInAtReceiptMs: 0),
      receipt(maxSignalAgeMs: null),
      receipt(maxSignalAgeMs: 3000),
      receipt(receivedMonotonicMs: -1),
      receipt(
          remainingAtSourceMs:
              const IntervalMs(earliestMs: 2000, latestMs: 10000)),
    ]) {
      expect(deadline.fresh, isFalse);
      expect(deadline.remainingMs, isNull);
    }
  });
}
