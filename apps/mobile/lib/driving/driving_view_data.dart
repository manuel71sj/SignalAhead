import '../prediction/prediction.dart';

/// Already-normalized display state. Widgets never own sensors, sockets or clocks.
class DrivingViewData {
  const DrivingViewData({
    required this.active,
    required this.phaseLabel,
    required this.heading,
    required this.message,
    this.directionLabel = '방향 확인 전',
    this.signalState = SignalState.unknown,
    this.remainingMs,
    this.prediction,
    this.speedMps,
    this.distanceM,
    this.horizontalAccuracyM,
    this.synthetic = false,
  });

  final bool active;
  final String phaseLabel;
  final String heading;
  final String message;
  final String directionLabel;
  final SignalState signalState;
  final IntervalMs? remainingMs;
  final PredictionResult? prediction;
  final double? speedMps;
  final NumericInterval? distanceM;
  final double? horizontalAccuracyM;
  final bool synthetic;
}
