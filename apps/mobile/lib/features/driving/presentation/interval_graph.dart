import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../prediction/prediction.dart';

/// Outward-rounded whole seconds; a positive subsecond bound is never shown as 0.
String wholeSeconds(IntervalMs interval) {
  final earliest = interval.earliestMs!;
  final latest = interval.latestMs!;
  if (latest < 1000) return '1초 미만';
  final lower = earliest < 1000 ? '1 미만' : '${earliest ~/ 1000}';
  final upper = (latest / 1000).ceil();
  return lower == '$upper' ? '$upper초' : '$lower–$upper초';
}

/// Both uncertainty intervals share a zero and extent. No phase is extrapolated.
class IntervalGraph extends StatelessWidget {
  const IntervalGraph({
    super.key,
    required this.arrival,
    required this.greenRemaining,
  });

  final IntervalMs arrival;
  final IntervalMs greenRemaining;

  @override
  Widget build(BuildContext context) {
    final maximumMs = math.max(arrival.latestMs!, greenRemaining.latestMs!);
    final unitMs = maximumMs >= 120000 ? 60000 : 1000;
    final unit = unitMs == 60000 ? '분' : '초';
    final step = math.max(1, (maximumMs / (unitMs * 4)).ceil());
    final extentMs = step * 4 * unitMs;
    return Semantics(
      label: '현재부터 같은 시간축, 0부터 ${step * 4}$unit. '
          '녹색 잔여시간 ${greenRemaining.earliestMs}부터 ${greenRemaining.latestMs}밀리초. '
          '정지선 도달시간 ${arrival.earliestMs}부터 ${arrival.latestMs}밀리초. '
          '각 막대의 양 끝은 가장 이른 시간과 가장 늦은 시간이며 사선 영역은 오차 범위입니다.',
      excludeSemantics: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text('현재부터의 시간 · 오차 범위',
              style: TextStyle(fontSize: 14, color: Colors.white70)),
          const SizedBox(height: 8),
          Text('녹색 잔여 ${wholeSeconds(greenRemaining)}',
              style: const TextStyle(fontSize: 14)),
          const SizedBox(height: 4),
          CustomPaint(
            size: const Size(double.infinity, 28),
            painter: _IntervalPainter(
                interval: greenRemaining,
                extentMs: extentMs,
                color: const Color(0xFF69DBB6)),
          ),
          const SizedBox(height: 8),
          Text('정지선 도달 ${wholeSeconds(arrival)}',
              style: const TextStyle(fontSize: 14)),
          const SizedBox(height: 4),
          CustomPaint(
            size: const Size(double.infinity, 28),
            painter: _IntervalPainter(
                interval: arrival,
                extentMs: extentMs,
                color: const Color(0xFF9BC7FF)),
          ),
          const SizedBox(height: 4),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('0', style: TextStyle(fontSize: 12)),
              Text('${step * 2}', style: const TextStyle(fontSize: 12)),
              Text('${step * 4}$unit', style: const TextStyle(fontSize: 12)),
            ],
          ),
          const SizedBox(height: 4),
          const Text('막대 양 끝: 가장 이른 시간–가장 늦은 시간',
              style: TextStyle(fontSize: 12, color: Colors.white70)),
        ],
      ),
    );
  }
}

class _IntervalPainter extends CustomPainter {
  const _IntervalPainter({
    required this.interval,
    required this.extentMs,
    required this.color,
  });

  final IntervalMs interval;
  final int extentMs;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    // Inset endpoint strokes, not the data, so even a bound on the axis is visible.
    const inset = 2.0;
    final width = math.max(0.0, size.width - inset * 2);
    final axis = Paint()
      ..color = Colors.white24
      ..strokeWidth = 1;
    final center = size.height / 2;
    canvas.drawLine(Offset(inset, center), Offset(inset + width, center), axis);
    for (var tick = 0; tick <= 4; tick++) {
      final x = inset + width * tick / 4;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), axis);
    }
    final left = inset + width * interval.earliestMs! / extentMs;
    final right = inset + width * interval.latestMs! / extentMs;
    final range = Rect.fromLTRB(left, 5, right, size.height - 5);
    canvas.drawRect(range, Paint()..color = color.withValues(alpha: 0.25));
    final ink = Paint()
      ..color = color
      ..strokeWidth = 2;
    canvas.save();
    canvas.clipRect(range);
    for (var x = left - size.height; x <= right; x += 8) {
      canvas.drawLine(Offset(x, size.height), Offset(x + size.height, 0), ink);
    }
    canvas.restore();
    canvas.drawLine(Offset(left, 3), Offset(left, size.height - 3), ink);
    canvas.drawLine(Offset(right, 3), Offset(right, size.height - 3), ink);
  }

  @override
  bool shouldRepaint(_IntervalPainter oldDelegate) =>
      oldDelegate.interval.earliestMs != interval.earliestMs ||
      oldDelegate.interval.latestMs != interval.latestMs ||
      oldDelegate.extentMs != extentMs ||
      oldDelegate.color != color;
}
