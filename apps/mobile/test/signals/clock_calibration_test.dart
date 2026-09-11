import 'package:flutter_test/flutter_test.dart';
import 'package:signalahead_mobile/signals/clock_calibration.dart';

ClockCalibration? exchange(
        {int receivedUtc = 1100,
        int receivedMono = 200,
        int serverReceived = 5050,
        int serverSent = 5060,
        int budget = 100}) =>
    ClockCalibration.fromExchange(
        sentMonotonicMs: 100,
        receivedMonotonicMs: receivedMono,
        sentUtcMs: 1000,
        receivedUtcMs: receivedUtc,
        serverReceivedAtUtcMs: serverReceived,
        serverSentAtUtcMs: serverSent,
        skewBudgetMs: budget);

void main() {
  test('asymmetric HTTP RTT and source skew bound age without double transit',
      () {
    final clock = exchange()!;
    // At device receipt server UTC is [5060, 5150], not midpoint 5105.
    final deadline = clock.deadline(
        eventKey: 'source-1',
        sourceObservedAtUtcMs: 4800,
        serverReceivedAtUtcMs: 4900,
        serverSentAtUtcMs: 4950,
        remainingAtSourceMs: 2000,
        expiresAtUtcMs: 6000,
        maxSignalAgeMs: 1000,
        monotonicMs: 300,
        utcMs: 1200)!;
    // At mono300 server UTC [5160,5250]; age [260,550] including ±100 skew.
    expect(deadline.remainingMs!.earliestMs, 1450);
    expect(deadline.remainingMs!.latestMs, 1740);
    expect(deadline.advanceTo(400).remainingMs!.earliestMs, 1350);
    expect(deadline.advanceTo(749).fresh, isTrue);
    expect(deadline.advanceTo(750).fresh, isFalse); // max source age
  });

  test('server expiry and earliest phase end independently cut off freshness',
      () {
    final clock = exchange()!;
    final ttl = clock.deadline(
        eventKey: 'ttl',
        sourceObservedAtUtcMs: 4800,
        serverReceivedAtUtcMs: 4900,
        serverSentAtUtcMs: 4950,
        remainingAtSourceMs: 2000,
        expiresAtUtcMs: 5400,
        maxSignalAgeMs: 10000,
        monotonicMs: 300,
        utcMs: 1200)!;
    expect(ttl.advanceTo(349).fresh, isTrue);
    expect(ttl.advanceTo(350).fresh, isFalse);
    final phase = clock.deadline(
        eventKey: 'phase',
        sourceObservedAtUtcMs: 4800,
        serverReceivedAtUtcMs: 4900,
        serverSentAtUtcMs: 4950,
        remainingAtSourceMs: 600,
        expiresAtUtcMs: 10000,
        maxSignalAgeMs: 10000,
        monotonicMs: 300,
        utcMs: 1200)!;
    expect(phase.advanceTo(349).fresh, isTrue);
    expect(phase.advanceTo(350).fresh, isFalse);
  });

  test('uncertain or inverted HTTP exchange and clock jumps fail closed', () {
    expect(exchange(budget: 89), isNull);
    expect(exchange(serverSent: 5049), isNull);
    expect(exchange(serverSent: 5151), isNull);
    expect(exchange(receivedUtc: 1151), isNull);
    expect(exchange(receivedMono: 99), isNull);
    final clock = exchange()!;
    expect(clock.isValidAt(monotonicMs: 300, utcMs: 1250), isTrue);
    expect(clock.isValidAt(monotonicMs: 300, utcMs: 1251), isFalse);
    expect(clock.isValidAt(monotonicMs: 300, utcMs: 1149), isFalse);
    expect(clock.isValidAt(monotonicMs: 199, utcMs: 1099), isFalse);
    expect(clock.isValidAt(monotonicMs: 30200, utcMs: 31100), isFalse);
  });

  test(
      'future server stamps and stale source evidence cannot create a deadline',
      () {
    final clock = exchange()!;
    expect(
        clock.deadline(
            eventKey: 'future',
            sourceObservedAtUtcMs: 5200,
            serverReceivedAtUtcMs: 5200,
            serverSentAtUtcMs: 5200,
            remainingAtSourceMs: 2000,
            expiresAtUtcMs: 8000,
            maxSignalAgeMs: 1000,
            monotonicMs: 200,
            utcMs: 1100),
        isNull);
    final stale = clock.deadline(
        eventKey: 'old',
        sourceObservedAtUtcMs: 1000,
        serverReceivedAtUtcMs: 4900,
        serverSentAtUtcMs: 4950,
        remainingAtSourceMs: 10000,
        expiresAtUtcMs: 8000,
        maxSignalAgeMs: 1000,
        monotonicMs: 200,
        utcMs: 1100)!;
    expect(stale.fresh, isFalse);
  });
}
