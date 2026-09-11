import 'dart:math' as math;

import '../location/location_sample.dart';
import '../prediction/prediction.dart';
import 'driving_bundle.dart';

/// No target is cached: every fix must establish a current directed road and a
/// positive interval to the next supported stop. Route intent is never inferred.
class RoadMatcher {
  RoadMatcher(this.bundle)
      : _maxProjectionErrorM = bundle.roads
            .expand((road) => road.segments)
            .fold(
                0.0,
                (double error, segment) =>
                    math.max(error, segment.projectionErrorM)),
        _connections = _precomputeConnections(bundle);
  final DrivingBundle bundle;
  final double _maxProjectionErrorM;
  final List<List<double>> _connections;
  final List<_Frame> _history = [];
  String? _sessionId;
  int? _lastNow;

  void clear() {
    _history.clear();
    _sessionId = null;
    _lastNow = null;
  }

  MatchingResult update(LocationSample sample, int monotonicNow) {
    if (_sessionId != sample.sessionId) {
      clear();
      _sessionId = sample.sessionId;
    }
    final policy = bundle.matchingPolicy;
    if (!_validSample(sample, monotonicNow) ||
        (_lastNow != null && monotonicNow < _lastNow!) ||
        (_history.isNotEmpty &&
            (sample.deviceReceivedMonotonicMs <=
                    _history.last.sample.deviceReceivedMonotonicMs ||
                sample.measuredAtUtcMs <=
                    _history.last.sample.measuredAtUtcMs))) {
      clear();
      return _unsupported('Invalid, stale or nonmonotonic location');
    }
    _lastNow = monotonicNow;
    _history.removeWhere((frame) =>
        monotonicNow - frame.sample.deviceReceivedMonotonicMs >
        policy.maxHistoryAgeMs);
    if (bundle.hasUnlocatedBarrier) {
      _history.clear();
      return _unsupported('Catalog contains an unlocated stop barrier');
    }
    final point = GeoPoint(sample.longitude, sample.latitude);
    final uncertainty = sample.horizontalAccuracyM + policy.geometryErrorM;
    if (uncertainty + _maxProjectionErrorM > policy.candidateSearchRadiusM) {
      _history.clear();
      return _unsupported('Geometry uncertainty exceeds bounded search radius');
    }
    final candidates = <_Candidate>[];
    for (final segment
        in bundle.index.query(point, policy.candidateSearchRadiusM)) {
      if (angleDifference(sample.courseDeg!, segment.bearingDeg) +
              sample.courseAccuracyDeg! >
          policy.maxCourseErrorDeg) {
        continue;
      }
      final projection = segment.project(point);
      if (projection.crossTrackM > uncertainty + segment.projectionErrorM) {
        continue;
      }
      // Deduplicate the same position at an ordinary polyline vertex. Separate
      // positions on hairpins/self-near links remain competing candidates.
      if (candidates.any((candidate) =>
          candidate.projection.roadIndex == projection.roadIndex &&
          (candidate.projection.alongM - projection.alongM).abs() < 0.000001)) {
        continue;
      }
      candidates
          .add(_Candidate(projection, 1, sample.deviceReceivedMonotonicMs));
      if (candidates.length > 32) {
        _history.clear();
        return _ambiguous('Candidate density exceeds bounded history capacity');
      }
    }
    if (candidates.isEmpty) {
      _history.clear();
      return _unsupported(
          'No road consistent with location and course uncertainty');
    }
    final spatiallyCertain = _separated(candidates, uncertainty);
    final prior = _history.isEmpty ? null : _history.last;
    final viable = <_Candidate>[];
    for (final candidate in candidates) {
      var confirmations = 1;
      int? anchorAt;
      if (prior != null) {
        for (final previous in prior.candidates) {
          if (monotonicNow - previous.anchorAt > policy.maxHistoryAgeMs) {
            continue;
          }
          final travel =
              _connectedDistance(previous.projection, candidate.projection);
          final motionError = uncertainty +
              prior.sample.horizontalAccuracyM +
              policy.geometryErrorM +
              previous.projection.segment.projectionErrorM +
              candidate.projection.segment.projectionErrorM;
          final displacement = geoDistance(
              GeoPoint(prior.sample.longitude, prior.sample.latitude), point);
          if (travel == null ||
              travel < -motionError ||
              travel > displacement * 1.01 + motionError) {
            continue;
          }
          confirmations =
              math.max(confirmations, math.min(10, previous.confirmations + 1));
          anchorAt = anchorAt == null
              ? previous.anchorAt
              : math.max(anchorAt, previous.anchorAt);
        }
      }
      // Only an intrinsically separated observation renews a grade/road anchor.
      // Repeated overlap cannot keep an old unique observation alive forever.
      if (identical(candidate, spatiallyCertain)) {
        anchorAt = sample.deviceReceivedMonotonicMs;
      }
      if (prior == null || anchorAt != null) {
        viable.add(_Candidate(candidate.projection, confirmations,
            anchorAt ?? sample.deviceReceivedMonotonicMs));
      }
    }
    if (viable.isEmpty) {
      // Start a fresh observation chain, never retain a disconnected old target.
      _history.clear();
      _remember(sample, candidates);
      return _ambiguous('Directed history does not support the current road');
    }
    final selected = _separated(viable, uncertainty);
    _remember(sample, viable);
    if (selected == null) {
      return _ambiguous(
          'Competing roads, levels or positions remain plausible');
    }
    if (selected.confirmations < policy.confirmationSamples ||
        !_displacementConfirmed(selected, sample)) {
      return _ambiguous(
          'Insufficient recent directed displacement confirmation');
    }
    return _nextStop(selected.projection, uncertainty);
  }

  bool _validSample(LocationSample sample, int now) {
    final policy = bundle.matchingPolicy;
    return sample.sessionId.trim().isNotEmpty &&
        now >= 0 &&
        sample.deviceReceivedMonotonicMs >= 0 &&
        sample.measuredAtUtcMs >= 0 &&
        sample.deviceReceivedMonotonicMs <= now &&
        now - sample.deviceReceivedMonotonicMs <= policy.maxHistoryAgeMs &&
        sample.latitude.isFinite &&
        sample.latitude > -90 &&
        sample.latitude < 90 &&
        sample.longitude.isFinite &&
        sample.longitude >= -180 &&
        sample.longitude <= 180 &&
        sample.horizontalAccuracyM.isFinite &&
        sample.horizontalAccuracyM >= 0 &&
        sample.horizontalAccuracyM <= policy.maxHorizontalAccuracyM &&
        sample.courseDeg != null &&
        sample.courseDeg!.isFinite &&
        sample.courseDeg! >= 0 &&
        sample.courseDeg! < 360 &&
        sample.courseAccuracyDeg != null &&
        sample.courseAccuracyDeg!.isFinite &&
        sample.courseAccuracyDeg! >= 0 &&
        sample.courseAccuracyDeg! < policy.maxCourseErrorDeg;
  }

  void _remember(LocationSample sample, List<_Candidate> candidates) {
    if (_history.length == 10) _history.removeAt(0);
    _history.add(_Frame(sample, candidates));
  }

  _Candidate? _separated(List<_Candidate> candidates, double uncertainty) {
    if (candidates.length == 1) return candidates.single;
    _Candidate? best;
    for (final candidate in candidates) {
      if (best == null ||
          candidate.projection.crossTrackM < best.projection.crossTrackM) {
        best = candidate;
      }
    }
    final upper = best!.projection.crossTrackM +
        uncertainty +
        best.projection.segment.projectionErrorM;
    for (final other in candidates) {
      if (identical(best, other)) continue;
      final lower = math.max(
          0.0,
          other.projection.crossTrackM -
              uncertainty -
              other.projection.segment.projectionErrorM);
      if (upper + bundle.matchingPolicy.candidateSeparationM >= lower) {
        return null;
      }
    }
    return best;
  }

  bool _displacementConfirmed(_Candidate candidate, LocationSample current) {
    final policy = bundle.matchingPolicy;
    final end = GeoPoint(current.longitude, current.latitude);
    for (final frame in _history) {
      if (identical(frame.sample, current)) continue;
      final start = GeoPoint(frame.sample.longitude, frame.sample.latitude);
      final displacement = geoDistance(start, end);
      final error = current.horizontalAccuracyM +
          frame.sample.horizontalAccuracyM +
          2 * policy.geometryErrorM +
          0.01 * displacement;
      if (displacement - error < policy.minDisplacementM) continue;
      final angleError =
          math.asin((error / displacement).clamp(0.0, 1.0)) / radiansPerDegree;
      if (angleDifference(geoBearing(start, end), current.courseDeg!) +
              current.courseAccuracyDeg! +
              angleError >
          policy.maxCourseErrorDeg) {
        continue;
      }
      for (final previous in frame.candidates) {
        final distance =
            _connectedDistance(previous.projection, candidate.projection);
        if (distance != null &&
            distance > error &&
            distance <=
                displacement * 1.01 +
                    error +
                    previous.projection.segment.projectionErrorM +
                    candidate.projection.segment.projectionErrorM) {
          return true;
        }
      }
    }
    return false;
  }

  /// End-of-link to start-of-link distances, computed once. Floyd-Warshall is
  /// bounded by the catalog's 256-link limit; fixes do only constant-time lookups.
  static List<List<double>> _precomputeConnections(DrivingBundle bundle) {
    final roads = bundle.roads;
    final result = List.generate(roads.length,
        (_) => List<double>.filled(roads.length, double.infinity));
    for (var i = 0; i < roads.length; i++) {
      for (final next in bundle.outgoing[roads[i].toNodeId] ?? const <int>[]) {
        if (roads[i].level == roads[next].level) result[i][next] = 0;
      }
    }
    for (var k = 0; k < roads.length; k++) {
      for (var i = 0; i < roads.length; i++) {
        if (!result[i][k].isFinite) continue;
        for (var j = 0; j < roads.length; j++) {
          final distance = result[i][k] + roads[k].lengthM + result[k][j];
          if (distance <= bundle.matchingPolicy.maxRouteDistanceM &&
              distance < result[i][j]) {
            result[i][j] = distance;
          }
        }
      }
    }
    return result;
  }

  double? _connectedDistance(RoadProjection from, RoadProjection to) {
    if (from.roadIndex == to.roadIndex) return to.alongM - from.alongM;
    final distance = bundle.roads[from.roadIndex].lengthM -
        from.alongM +
        _connections[from.roadIndex][to.roadIndex] +
        to.alongM;
    return distance <= bundle.matchingPolicy.maxRouteDistanceM
        ? distance
        : null;
  }

  MatchingResult _nextStop(RoadProjection projection, double uncertainty) {
    final policy = bundle.matchingPolicy;
    var roadIndex = projection.roadIndex;
    var position = projection.alongM;
    var preceding = 0.0;
    var geometryError = projection.segment.projectionErrorM;
    final visited = <int>{};
    while (visited.add(roadIndex) && visited.length <= bundle.roads.length) {
      final road = bundle.roads[roadIndex];
      if (road.hasUnlocatedBarrier) {
        return _unsupported('Missing stop line prevents downstream selection');
      }
      for (var i = 0; i < road.stops.length; i++) {
        final stop = road.stops[i];
        final distance = preceding + stop.alongM - position;
        final error = uncertainty + geometryError + 0.01 * distance.abs();
        if (distance + error < 0) continue; // Definitely passed, never held.
        if (distance - error <= 0) {
          return _ambiguous('Location uncertainty crosses the stop line');
        }
        if (distance + error > policy.maxRouteDistanceM) {
          return _unsupported('Next stop exceeds bounded route distance');
        }
        if (stop.approach == null) {
          return _unsupported('Next stop is disabled or unreviewed');
        }
        if (i + 1 < road.stops.length &&
            road.stops[i + 1].alongM - stop.alongM <= 2 * error) {
          return _ambiguous('Stop barriers cannot be distinguished');
        }
        return MatchingResult(
            status: MatchingStatus.matched,
            reason: 'Directed road and next stop confirmed',
            approach: stop.approach,
            distanceM:
                NumericInterval(min: distance - error, max: distance + error));
      }
      preceding += road.lengthM - position;
      if (preceding > policy.maxRouteDistanceM) {
        return _unsupported('Route distance bound reached');
      }
      final outgoing = bundle.outgoing[road.toNodeId] ?? const <int>[];
      // A grade-changing/unknown outgoing edge cannot be silently discarded to
      // turn a fork into a unique path.
      if (outgoing.length > 1) {
        return _ambiguous('Fork requires observed branch intent');
      }
      if (outgoing.isEmpty) return _unsupported('No downstream reviewed stop');
      final next = outgoing.single;
      if (bundle.roads[next].level != road.level) {
        return _unsupported('Grade-changing path unsupported');
      }
      roadIndex = next;
      position = 0;
      geometryError += bundle.roads[next].segments.fold<double>(
          0.0, (double error, segment) => error + segment.projectionErrorM);
    }
    return _unsupported('Directed cycle cannot establish a unique next stop');
  }

  MatchingResult _unsupported(String reason) =>
      MatchingResult(status: MatchingStatus.unsupported, reason: reason);
  MatchingResult _ambiguous(String reason) =>
      MatchingResult(status: MatchingStatus.ambiguous, reason: reason);
}

class _Candidate {
  const _Candidate(this.projection, this.confirmations, this.anchorAt);
  final RoadProjection projection;
  final int confirmations, anchorAt;
}

class _Frame {
  const _Frame(this.sample, this.candidates);
  final LocationSample sample;
  final List<_Candidate> candidates;
}
