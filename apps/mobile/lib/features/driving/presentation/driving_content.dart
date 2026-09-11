import 'package:flutter/material.dart';

import '../../../driving/driving_view_data.dart';
import '../../../prediction/prediction.dart';
import 'interval_graph.dart';

const _surface = Color(0xFF1B2B3A);
const _accent = Color(0xFF69DBB6);

/// A display-only body. The caller owns freshness, motion and session lifecycle.
class DrivingContent extends StatelessWidget {
  const DrivingContent({
    super.key,
    required this.data,
    required this.onStartStop,
    this.onOpenSettings,
  });

  final DrivingViewData data;
  final VoidCallback onStartStop;
  final VoidCallback? onOpenSettings;

  @override
  Widget build(BuildContext context) {
    final prediction = data.prediction;
    final remaining = data.remainingMs;
    final expired = prediction?.reason == PredictionReason.signalStale ||
        (remaining != null && remaining.isValid && remaining.earliestMs! <= 0);
    final signal =
        !data.active || expired ? SignalState.unknown : data.signalState;
    final hasRemaining = signal != SignalState.unknown &&
        remaining != null &&
        remaining.isValid &&
        remaining.earliestMs! > 0;
    final canCompare = data.active &&
        signal == SignalState.green &&
        hasRemaining &&
        prediction?.signalStateAtDecision == SignalState.green &&
        prediction?.arrivalIntervalMs?.isValid == true &&
        prediction?.greenRemainingIntervalMs?.isValid == true &&
        prediction?.reason == PredictionReason.intervalOverlap;
    final status = canCompare ? prediction!.status : PredictionStatus.unknown;
    final String heading;
    final String message;
    if (prediction == null) {
      heading = data.heading;
      message = data.message;
    } else {
      heading = switch (status) {
        PredictionStatus.possible => '가능 예상',
        PredictionStatus.unlikely => '도달 어려움 예상',
        PredictionStatus.unknown => '판단 보류',
      };
      final reason = !data.active
          ? PredictionReason.sessionInactive
          : expired
              ? PredictionReason.signalStale
              : prediction.reason != PredictionReason.intervalOverlap
                  ? prediction.reason
                  : signal == SignalState.unknown
                      ? PredictionReason.signalStale
                      : signal != SignalState.green
                          ? PredictionReason.signalNotGreen
                          : !hasRemaining
                              ? PredictionReason.timingUnverified
                              : prediction.reason;
      message = switch (status) {
        PredictionStatus.possible => '현재 속도 기준 도달 가능성이 있습니다. 통과를 보장하지 않습니다.',
        PredictionStatus.unlikely => '현재 속도 기준 남은 녹색 시간 안에 도달하기 어렵습니다.',
        PredictionStatus.unknown => _reasonMessage(reason),
      };
    }
    final signalLabel = switch (signal) {
      SignalState.green => '녹색 신호',
      SignalState.yellow => '황색 신호',
      SignalState.red => '적색 신호',
      SignalState.flashing => '점멸 신호',
      SignalState.unknown => '신호 정보 없음',
    };
    final signalColor = switch (signal) {
      SignalState.green => _accent,
      SignalState.yellow => const Color(0xFFFFD166),
      SignalState.red => const Color(0xFFFF8B8B),
      SignalState.flashing => const Color(0xFFFFD166),
      SignalState.unknown => Colors.white60,
    };
    final signalIcon = switch (signal) {
      SignalState.green => Icons.circle,
      SignalState.yellow => Icons.warning_rounded,
      SignalState.red => Icons.stop,
      SignalState.flashing => Icons.bolt,
      SignalState.unknown => Icons.help_outline,
    };
    final remainingLabel =
        hasRemaining ? '잔여 ${wholeSeconds(remaining)}' : '잔여시간 —';

    return SafeArea(
      child: LayoutBuilder(builder: (context, constraints) {
        final scale = MediaQuery.textScalerOf(context).scale(16) / 16;
        final compact = constraints.maxHeight < 680 || scale >= 1.5;
        final showMetrics = constraints.maxHeight >= 600 && scale < 2;
        final showGraph = !compact && canCompare;
        return Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: SingleChildScrollView(
              padding: EdgeInsets.fromLTRB(16, compact ? 8 : 16, 16, 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(data.directionLabel,
                      key: const ValueKey('driving-direction'),
                      style: const TextStyle(
                          fontSize: 16, fontWeight: FontWeight.w600)),
                  if (data.synthetic)
                    const Padding(
                      padding: EdgeInsets.only(top: 4),
                      child: Text('개발용 가상 데이터 · 실제 주행용 아님',
                          style: TextStyle(
                              color: Color(0xFFFFD166), fontSize: 14)),
                    ),
                  SizedBox(height: compact ? 8 : 16),
                  Semantics(
                    label: '$signalLabel, $remainingLabel',
                    excludeSemantics: true,
                    child: _Panel(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Row(
                            children: [
                              Icon(signalIcon,
                                  color: signalColor, size: compact ? 28 : 40),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Text(signalLabel,
                                    key: const ValueKey('driving-signal'),
                                    style: TextStyle(
                                        fontSize: compact ? 20 : 28,
                                        fontWeight: FontWeight.bold,
                                        color: signalColor)),
                              ),
                            ],
                          ),
                          const SizedBox(height: 6),
                          Text(remainingLabel,
                              key: const ValueKey('driving-remaining'),
                              style: TextStyle(
                                  fontSize: compact ? 20 : 32,
                                  fontWeight: FontWeight.w600)),
                        ],
                      ),
                    ),
                  ),
                  SizedBox(height: compact ? 8 : 16),
                  _Panel(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(heading,
                            key: ValueKey('driving-result-${status.name}'),
                            style: TextStyle(
                                color: status == PredictionStatus.possible
                                    ? _accent
                                    : Colors.white,
                                fontSize: compact ? 20 : 24,
                                fontWeight: FontWeight.bold)),
                        if (!compact) ...[
                          const SizedBox(height: 8),
                          Text(message,
                              style:
                                  const TextStyle(fontSize: 16, height: 1.4)),
                        ],
                      ],
                    ),
                  ),
                  if (showMetrics) ...[
                    const SizedBox(height: 16),
                    _Metrics(data: data),
                  ],
                  if (showGraph) ...[
                    const SizedBox(height: 16),
                    _Panel(
                      child: IntervalGraph(
                        arrival: prediction!.arrivalIntervalMs!,
                        greenRemaining: prediction.greenRemainingIntervalMs!,
                      ),
                    ),
                  ],
                  SizedBox(height: compact ? 12 : 20),
                  FilledButton(
                    style: FilledButton.styleFrom(
                        minimumSize: const Size.fromHeight(56)),
                    onPressed: onStartStop,
                    child: Text(data.active ? '주행 종료' : '주행 시작'),
                  ),
                  if (onOpenSettings != null) ...[
                    const SizedBox(height: 8),
                    OutlinedButton(
                      style: OutlinedButton.styleFrom(
                          minimumSize: const Size.fromHeight(48)),
                      onPressed: onOpenSettings,
                      child: const Text('위치 설정 열기'),
                    ),
                  ],
                  if (compact) ...[
                    const SizedBox(height: 16),
                    Text(message,
                        style: const TextStyle(fontSize: 16, height: 1.4)),
                  ],
                  const SizedBox(height: 16),
                  Text(data.phaseLabel,
                      style:
                          const TextStyle(fontSize: 14, color: Colors.white70)),
                  const SizedBox(height: 8),
                  const Text(
                      '신호등과 도로 상황을 직접 확인하세요.\n이 앱은 출발·가속·교차로 통과를 지시하지 않습니다.',
                      style: TextStyle(
                          fontSize: 14, color: Colors.white70, height: 1.4)),
                ],
              ),
            ),
          ),
        );
      }),
    );
  }
}

String _reasonMessage(PredictionReason reason) => switch (reason) {
      PredictionReason.sessionInactive => '주행 중이 아니어서 예측하지 않습니다.',
      PredictionReason.policyUncalibrated => '실측 검증과 운영 승인이 없어 예측을 보류합니다.',
      PredictionReason.signalStale => '신호 정보가 없거나 지연되어 판단을 보류합니다.',
      PredictionReason.timingUnverified => '신호 시간의 기준이 검증되지 않았습니다.',
      PredictionReason.locationInvalid => '위치 또는 정지선 거리의 정확도가 부족합니다.',
      PredictionReason.targetAmbiguous => '진행 방향에 맞는 신호를 확정하지 못했습니다.',
      PredictionReason.signalNotGreen => '현재 녹색 신호가 아니므로 도달 예측을 제공하지 않습니다.',
      PredictionReason.stoppedOrSlow => '정차·저속 상태에서는 도달 예측을 제공하지 않습니다.',
      PredictionReason.intervalOverlap => '도달 시간과 신호 시간의 오차 범위가 겹칩니다.',
    };

class _Panel extends StatelessWidget {
  const _Panel({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
            color: _surface, borderRadius: BorderRadius.circular(20)),
        child: child,
      );
}

class _Metrics extends StatelessWidget {
  const _Metrics({required this.data});
  final DrivingViewData data;

  @override
  Widget build(BuildContext context) {
    final speed = data.speedMps;
    final distance = data.distanceM;
    final speedLabel = speed != null && speed.isFinite && speed >= 0
        ? '${(speed * 3.6).round()} km/h'
        : '—';
    final distanceLabel = distance != null && distance.isValid
        ? '${distance.min!.floor()}–${distance.max!.ceil()} m'
        : '—';
    return Wrap(
      key: const ValueKey('driving-metrics'),
      spacing: 24,
      runSpacing: 8,
      children: [
        Text('현재 속도 $speedLabel', style: const TextStyle(fontSize: 16)),
        Text('정지선 거리 $distanceLabel', style: const TextStyle(fontSize: 16)),
      ],
    );
  }
}
