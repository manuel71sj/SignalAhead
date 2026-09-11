import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:signalahead_mobile/driving/driving_view_data.dart';
import 'package:signalahead_mobile/features/driving/presentation/driving_content.dart';
import 'package:signalahead_mobile/features/driving/presentation/interval_graph.dart';
import 'package:signalahead_mobile/prediction/prediction.dart';

import '../prediction/prediction_test.dart' show fixturePolicy, input;

DrivingViewData viewData({
  SignalState signal = SignalState.green,
  PredictionResult? prediction,
  IntervalMs? remaining = const IntervalMs(earliestMs: 20000, latestMs: 26000),
}) =>
    DrivingViewData(
      active: true,
      phaseLabel: '주행 중',
      heading: '지원 정보 없음',
      message: '운영 정보가 없습니다.',
      directionLabel: '직진',
      signalState: signal,
      remainingMs: remaining,
      prediction: prediction,
      speedMps: 1,
      distanceM: const NumericInterval(min: 13, max: 17),
    );

Widget app(DrivingViewData data, {VoidCallback? onAction}) => MaterialApp(
      theme: ThemeData.dark(useMaterial3: true),
      home: Scaffold(
        appBar: AppBar(title: const Text('SignalAhead')),
        body: DrivingContent(
          data: data,
          onStartStop: onAction ?? () {},
          onOpenSettings: onAction ?? () {},
        ),
      ),
    );

void main() {
  testWidgets(
      'new non-green or expired signal discards a previous positive result',
      (tester) async {
    tester.view.physicalSize = const Size(430, 932);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final positive = evaluatePrediction(input(), fixturePolicy);
    for (final signal in [
      SignalState.yellow,
      SignalState.red,
      SignalState.flashing,
      SignalState.unknown,
    ]) {
      await tester.pumpWidget(app(viewData(prediction: positive)));
      expect(find.byKey(const ValueKey('driving-result-possible')),
          findsOneWidget);
      expect(find.byType(IntervalGraph), findsOneWidget);
      // A retained result must not override the new current signal.
      await tester
          .pumpWidget(app(viewData(signal: signal, prediction: positive)));
      expect(
          find.byKey(const ValueKey('driving-result-possible')), findsNothing);
      expect(find.byType(IntervalGraph), findsNothing);
      expect(
          find.byKey(const ValueKey('driving-result-unknown')), findsOneWidget);
      final icon = switch (signal) {
        SignalState.yellow => Icons.warning_rounded,
        SignalState.red => Icons.stop,
        SignalState.flashing => Icons.bolt,
        SignalState.unknown => Icons.help_outline,
        SignalState.green => Icons.circle,
      };
      expect(find.byIcon(icon), findsOneWidget);
    }
    await tester
        .pumpWidget(app(viewData(prediction: positive, remaining: null)));
    expect(find.byKey(const ValueKey('driving-result-possible')), findsNothing);
    expect(find.byType(IntervalGraph), findsNothing);
    await tester.pumpWidget(app(viewData(
      prediction: positive,
      remaining: const IntervalMs(earliestMs: 0, latestMs: 1000),
    )));
    expect(find.byIcon(Icons.circle), findsNothing);
    expect(find.byIcon(Icons.help_outline), findsOneWidget);
    expect(find.byKey(const ValueKey('driving-result-possible')), findsNothing);
    expect(find.byType(IntervalGraph), findsNothing);

    final stale = evaluatePrediction(input(signalFresh: false), fixturePolicy);
    await tester.pumpWidget(app(viewData(prediction: stale)));
    expect(find.byIcon(Icons.circle), findsNothing);
    expect(find.byIcon(Icons.help_outline), findsOneWidget);
    expect(find.byType(IntervalGraph), findsNothing);
  });

  testWidgets('stopping removes arrival graph but preserves fresh signal',
      (tester) async {
    tester.view.physicalSize = const Size(430, 932);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
        app(viewData(prediction: evaluatePrediction(input(), fixturePolicy))));
    expect(find.byType(IntervalGraph), findsOneWidget);
    final directionTop =
        tester.getTopLeft(find.byKey(const ValueKey('driving-direction'))).dy;
    final signalTop =
        tester.getTopLeft(find.byKey(const ValueKey('driving-signal'))).dy;
    final stopped = evaluatePrediction(
        input(speedMps: const NumericInterval(min: 0, max: 0)), fixturePolicy);
    await tester.pumpWidget(app(viewData(prediction: stopped)));
    expect(find.byType(IntervalGraph), findsNothing);
    expect(find.byKey(const ValueKey('driving-result-possible')), findsNothing);
    expect(find.byIcon(Icons.circle), findsOneWidget);
    expect(
        tester.getTopLeft(find.byKey(const ValueKey('driving-direction'))).dy,
        closeTo(directionTop, 0.1));
    expect(tester.getTopLeft(find.byKey(const ValueKey('driving-signal'))).dy,
        closeTo(signalTop, 0.1));
    final remaining =
        tester.widget<Text>(find.byKey(const ValueKey('driving-remaining')));
    expect(remaining.data, contains('20'));
    expect(remaining.data, contains('26'));
  });

  for (final size in [
    const Size(320, 568),
    const Size(390, 844),
    const Size(430, 932)
  ]) {
    for (final scale in [1.0, 1.5, 2.0]) {
      testWidgets(
          'core fits $size at text scale $scale and actions remain reachable',
          (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        tester.platformDispatcher.textScaleFactorTestValue = scale;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        var actions = 0;
        final prediction = evaluatePrediction(
            input(distanceM: const NumericInterval(min: 40, max: 50)),
            fixturePolicy);
        await tester.pumpWidget(
            app(viewData(prediction: prediction), onAction: () => actions++));
        for (final key in [
          'driving-signal',
          'driving-remaining',
          'driving-result-unlikely'
        ]) {
          final rect = tester.getRect(find.byKey(ValueKey(key)));
          expect(rect.left, greaterThanOrEqualTo(0));
          expect(rect.right, lessThanOrEqualTo(size.width));
          expect(rect.top, greaterThanOrEqualTo(0));
          expect(rect.bottom, lessThanOrEqualTo(size.height));
        }
        if (size.height == 568 || scale >= 1.5) {
          expect(find.byType(IntervalGraph), findsNothing);
        }
        if (size.height == 568 || scale == 2) {
          expect(find.byKey(const ValueKey('driving-metrics')), findsNothing);
        }
        for (final finder in [
          find.byType(FilledButton),
          find.byType(OutlinedButton)
        ]) {
          await tester.ensureVisible(finder);
          await tester.pumpAndSettle();
          expect(tester.getSize(finder).height, greaterThanOrEqualTo(48));
          await tester.tap(finder);
        }
        expect(actions, 2);
        expect(tester.takeException(), isNull);
      });
    }
  }
}
