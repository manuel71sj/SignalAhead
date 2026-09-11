import 'dart:math' as math;

import '../prediction/prediction.dart';

enum MatchingStatus { matched, ambiguous, unsupported }

class MatchedApproach {
  const MatchedApproach(
      {required this.provider,
      required this.intersectionKey,
      required this.approachKey,
      required this.catalogVersion});
  final String provider;
  final String intersectionKey;
  final String approachKey;
  final String catalogVersion;
  String get movement => 'straight';
}

class MatchingResult {
  const MatchingResult(
      {required this.status,
      required this.reason,
      this.approach,
      this.distanceM});
  final MatchingStatus status;
  final MatchedApproach? approach;
  final NumericInterval? distanceM;
  final String reason;
}

/// Values have no production defaults. Synthetic decoding never grants approval.
class MatchingPolicy {
  MatchingPolicy._(Map<String, dynamic> json, bool synthetic)
      : maxHorizontalAccuracyM = _positive(json['maxHorizontalAccuracyM']),
        maxCourseErrorDeg = _positive(json['maxCourseErrorDeg']),
        candidateSearchRadiusM = _positive(json['candidateSearchRadiusM']),
        candidateSeparationM = _positive(json['candidateSeparationM']),
        minDisplacementM = _positive(json['minDisplacementM']),
        maxHistoryAgeMs =
            _integer(json['maxHistoryAgeMs'], minimum: 1, maximum: 30000),
        confirmationSamples =
            _integer(json['confirmationSamples'], minimum: 2, maximum: 10),
        maxRouteDistanceM = _positive(json['maxRouteDistanceM']),
        geometryErrorM = _positive(json['geometryErrorM'], zero: true) {
    _keys(json, const [
      'policyVersion',
      'approvedForOperation',
      'measurementEvidence',
      'maxHorizontalAccuracyM',
      'maxCourseErrorDeg',
      'candidateSearchRadiusM',
      'candidateSeparationM',
      'minDisplacementM',
      'maxHistoryAgeMs',
      'confirmationSamples',
      'maxRouteDistanceM',
      'geometryErrorM'
    ]);
    _text(json['policyVersion']);
    _text(json['measurementEvidence']);
    final approved = _boolean(json['approvedForOperation']);
    if ((!synthetic && !approved) ||
        maxCourseErrorDeg >= 90 ||
        candidateSearchRadiusM > 2000 ||
        maxRouteDistanceM > 2000) {
      throw const FormatException('Unapproved or unsafe matching policy');
    }
  }
  final double maxHorizontalAccuracyM, maxCourseErrorDeg;
  final double candidateSearchRadiusM, candidateSeparationM, minDisplacementM;
  final double maxRouteDistanceM, geometryErrorM;
  final int maxHistoryAgeMs, confirmationSamples;
}

class GeoPoint {
  const GeoPoint(this.longitude, this.latitude);
  final double longitude, latitude;
  bool same(GeoPoint other) =>
      longitude == other.longitude && latitude == other.latitude;
}

const earthRadiusM = 6371008.8;
const radiansPerDegree = math.pi / 180;

double geoDistance(GeoPoint a, GeoPoint b) {
  final lat = (b.latitude - a.latitude) * radiansPerDegree / 2;
  final lon = (b.longitude - a.longitude) * radiansPerDegree / 2;
  final h = math.sin(lat) * math.sin(lat) +
      math.cos(a.latitude * radiansPerDegree) *
          math.cos(b.latitude * radiansPerDegree) *
          math.sin(lon) *
          math.sin(lon);
  return 2 * earthRadiusM * math.asin(math.sqrt(h.clamp(0.0, 1.0)));
}

double geoBearing(GeoPoint a, GeoPoint b) {
  final lat1 = a.latitude * radiansPerDegree;
  final lat2 = b.latitude * radiansPerDegree;
  final lon = (b.longitude - a.longitude) * radiansPerDegree;
  return (math.atan2(
                  math.sin(lon) * math.cos(lat2),
                  math.cos(lat1) * math.sin(lat2) -
                      math.sin(lat1) * math.cos(lat2) * math.cos(lon)) /
              radiansPerDegree +
          360) %
      360;
}

double angleDifference(double a, double b) => ((a - b + 540) % 360 - 180).abs();

class RoadSegment {
  RoadSegment(this.roadIndex, this.start, this.end, this.offsetM)
      : lengthM = geoDistance(start, end),
        bearingDeg = geoBearing(start, end),
        longitudeScale = earthRadiusM *
            radiansPerDegree *
            math.cos((start.latitude + end.latitude) * radiansPerDegree / 2),
        bounds = GeoBounds.points(start, end) {
    final dx = (end.longitude - start.longitude) * longitudeScale;
    final dy =
        (end.latitude - start.latitude) * earthRadiusM * radiansPerDegree;
    x = dx;
    y = dy;
    squaredLength = dx * dx + dy * dy;
    // CRS84 lines are straight in the coordinate plane, not surveyed geodesics.
    // Include variation of the local longitude scale, even near the poles.
    final cos1 = math.cos(start.latitude * radiansPerDegree);
    final cos2 = math.cos(end.latitude * radiansPerDegree);
    final minCos = math.min(cos1, cos2);
    final maxCos =
        start.latitude * end.latitude <= 0 ? 1.0 : math.max(cos1, cos2);
    projectionErrorM = lengthM * (0.01 + (maxCos - minCos) / minCos) +
        (math.sqrt(squaredLength) - lengthM).abs();
  }
  final int roadIndex;
  final GeoPoint start, end;
  final double offsetM, lengthM, bearingDeg, longitudeScale;
  final GeoBounds bounds;
  late final double x, y, squaredLength, projectionErrorM;

  RoadProjection project(GeoPoint point) {
    final px = ((point.longitude - start.longitude + 540) % 360 - 180) *
        longitudeScale;
    final py =
        (point.latitude - start.latitude) * earthRadiusM * radiansPerDegree;
    final t = ((px * x + py * y) / squaredLength).clamp(0.0, 1.0);
    final projected = GeoPoint(
        start.longitude + t * (end.longitude - start.longitude),
        start.latitude + t * (end.latitude - start.latitude));
    return RoadProjection(
        this, offsetM + t * lengthM, geoDistance(point, projected));
  }
}

class RoadProjection {
  const RoadProjection(this.segment, this.alongM, this.crossTrackM);
  final RoadSegment segment;
  final double alongM, crossTrackM;
  int get roadIndex => segment.roadIndex;
}

class RoadStop {
  const RoadStop(this.alongM, this.approach);
  final double alongM;

  /// Null is a known stop barrier without a supported, enabled approach.
  final MatchedApproach? approach;
}

class DirectedRoad {
  DirectedRoad(
      {required this.id,
      required this.fromNodeId,
      required this.toNodeId,
      required this.level,
      required List<RoadSegment> segments,
      required List<RoadStop> stops,
      required this.hasUnlocatedBarrier})
      : segments = List.unmodifiable(segments),
        stops = List.unmodifiable(stops),
        lengthM = segments.last.offsetM + segments.last.lengthM;
  final String id, fromNodeId, toNodeId;
  final int level;
  final List<RoadSegment> segments;
  final List<RoadStop> stops;
  final bool hasUnlocatedBarrier;
  final double lengthM;
}

class GeoBounds {
  const GeoBounds(this.west, this.south, this.east, this.north);
  factory GeoBounds.points(GeoPoint a, GeoPoint b) => GeoBounds(
      math.min(a.longitude, b.longitude),
      math.min(a.latitude, b.latitude),
      math.max(a.longitude, b.longitude),
      math.max(a.latitude, b.latitude));
  final double west, south, east, north;
  bool intersects(GeoBounds b) =>
      west <= b.east && east >= b.west && south <= b.north && north >= b.south;
  GeoBounds union(GeoBounds b) => GeoBounds(
      math.min(west, b.west),
      math.min(south, b.south),
      math.max(east, b.east),
      math.max(north, b.north));
}

/// A static balanced bounding-box index; no per-fix full polyline reconstruction.
class RoadSpatialIndex {
  RoadSpatialIndex(List<RoadSegment> segments)
      : _root = _IndexNode.build(segments, 0);
  final _IndexNode? _root;
  List<RoadSegment> query(GeoPoint point, double radiusM) {
    final latitudeRadius = radiusM / (earthRadiusM * radiansPerDegree);
    final extremeLatitude =
        math.min(89.999999999, point.latitude.abs() + latitudeRadius);
    final longitudeRadius = math.min(
        180.0, latitudeRadius / math.cos(extremeLatitude * radiansPerDegree));
    final hits = <RoadSegment>[];
    final south = point.latitude - latitudeRadius;
    final north = point.latitude + latitudeRadius;
    if (longitudeRadius == 180) {
      _root?.query(GeoBounds(-180, south, 180, north), hits);
      return hits;
    }
    final west = point.longitude - longitudeRadius;
    final east = point.longitude + longitudeRadius;
    _root?.query(GeoBounds(west, south, east, north), hits);
    if (west < -180) {
      _root?.query(GeoBounds(west + 360, south, 180, north), hits);
    }
    if (east > 180) {
      _root?.query(GeoBounds(-180, south, east - 360, north), hits);
    }
    return hits;
  }
}

class _IndexNode {
  _IndexNode(this.bounds, this.left, this.right, this.segment);
  final GeoBounds bounds;
  final _IndexNode? left, right;
  final RoadSegment? segment;
  static _IndexNode? build(List<RoadSegment> values, int depth) {
    if (values.isEmpty) return null;
    if (values.length == 1) {
      return _IndexNode(values.single.bounds, null, null, values.single);
    }
    final sorted = List<RoadSegment>.of(values)
      ..sort((a, b) => depth.isEven
          ? (a.bounds.west + a.bounds.east)
              .compareTo(b.bounds.west + b.bounds.east)
          : (a.bounds.south + a.bounds.north)
              .compareTo(b.bounds.south + b.bounds.north));
    final middle = sorted.length ~/ 2;
    final left = build(sorted.sublist(0, middle), depth + 1)!;
    final right = build(sorted.sublist(middle), depth + 1)!;
    return _IndexNode(left.bounds.union(right.bounds), left, right, null);
  }

  void query(GeoBounds area, List<RoadSegment> result) {
    if (!bounds.intersects(area)) return;
    if (segment != null) {
      result.add(segment!);
      return;
    }
    left?.query(area, result);
    right?.query(area, result);
  }
}

class DrivingBundle {
  DrivingBundle._(
      this.catalogVersion,
      this.predictionPolicy,
      this.syntheticFixture,
      this.matchingPolicy,
      List<DirectedRoad> roads,
      Map<String, List<int>> outgoing,
      this.hasUnlocatedBarrier)
      : roads = List.unmodifiable(roads),
        outgoing = Map.unmodifiable(outgoing
            .map((key, value) => MapEntry(key, List<int>.unmodifiable(value)))),
        index = RoadSpatialIndex([for (final road in roads) ...road.segments]);

  final String catalogVersion;
  final PredictionPolicy predictionPolicy;
  final bool syntheticFixture;
  final MatchingPolicy matchingPolicy;
  final List<DirectedRoad> roads;
  final Map<String, List<int>> outgoing;
  final RoadSpatialIndex index;
  final bool hasUnlocatedBarrier;

  factory DrivingBundle.fromJson(Map<String, dynamic> json,
      {bool syntheticFixture = false}) {
    _keys(json, const [
      'schemaVersion',
      'kind',
      'catalogVersion',
      'sources',
      'intersections',
      'approaches',
      'disabledRegions',
      'spatial'
    ]);
    if (json['schemaVersion'] != 'sa-contract-1' ||
        json['kind'] != 'ApproachCatalog') {
      throw const FormatException('Expected ApproachCatalog');
    }
    final version = _text(json['catalogVersion']);
    final spatial = _object(json['spatial']);
    _keys(spatial, const [
      'crs',
      'roads',
      'stopLines',
      'matchingPolicy',
      'predictionPolicy'
    ]);
    if (spatial['crs'] != 'OGC:CRS84') {
      throw const FormatException('CRS84 required');
    }
    final policy =
        MatchingPolicy._(_object(spatial['matchingPolicy']), syntheticFixture);
    final prediction =
        _prediction(_object(spatial['predictionPolicy']), syntheticFixture);
    final sources = _object(json['sources']);
    if (sources.isEmpty || sources.length > 256) {
      throw const FormatException('Source bound');
    }
    for (final entry in sources.entries) {
      final source = _object(entry.value);
      _keys(source,
          const ['sourceId', 'provider', 'revision', 'origin', 'crs', 'rights'],
          optional: const ['evidence']);
      if (_text(source['sourceId']) != entry.key ||
          source['crs'] != 'OGC:CRS84' ||
          source['origin'] != (syntheticFixture ? 'synthetic' : 'recorded')) {
        throw const FormatException('Source identity, origin or CRS is unsafe');
      }
      _provider(source['provider']);
      _text(source['revision']);
      if (source.containsKey('evidence')) _text(source['evidence']);
      final rights = _object(source['rights']);
      _keys(rights,
          const ['storage', 'processing', 'redistribution', 'deviceMatching']);
      for (final value in rights.values) {
        final right = _object(value);
        _keys(right, const ['allowed', 'evidence']);
        if (!_boolean(right['allowed'])) {
          throw const FormatException('Unapproved geometry rights');
        }
        _text(right['evidence']);
      }
    }
    void sourceReference(dynamic value) {
      if (!sources.containsKey(_text(value))) {
        throw const FormatException('Missing source');
      }
    }

    final intersections = <String, Map<String, dynamic>>{};
    final identities = <String>{};
    for (final value in _list(json['intersections'], maximum: 256)) {
      final intersection = _object(value);
      _keys(intersection, const [
        'intersectionKey',
        'provider',
        'sourceIntersectionId',
        'rawSourceIdentity',
        'name',
        'coordinates',
        'source'
      ]);
      final key = _text(intersection['intersectionKey']);
      if (!identities.add(key) ||
          key !=
              '${_provider(intersection['provider'])}:${_text(intersection['sourceIntersectionId'])}') {
        throw const FormatException('Invalid provider-scoped intersection');
      }
      _text(intersection['name']);
      final raw = _object(intersection['rawSourceIdentity']);
      if (raw.values.any((v) =>
          v != null &&
          v is! String &&
          v is! bool &&
          (v is! num || !v.isFinite))) {
        throw const FormatException('Invalid raw identity');
      }
      _point(intersection['coordinates']);
      sourceReference(intersection['source']);
      if (_object(sources[intersection['source']])['provider'] !=
          intersection['provider']) {
        throw const FormatException(
            'Intersection provider differs from source');
      }
      intersections[key] = intersection;
    }
    if (intersections.isEmpty) throw const FormatException('No intersections');
    final disabled = <String>{};
    for (final value in _list(json['disabledRegions'], maximum: 1024)) {
      final region = _object(value);
      _keys(
          region, const ['regionKey', 'reason', 'effectiveFromCatalogVersion']);
      disabled.add(_text(region['regionKey']));
      _text(region['effectiveFromCatalogVersion']);
      if (!const [
        'RIGHTS_UNVERIFIED',
        'GEOMETRY_UNVERIFIED',
        'SIGNAL_UNAVAILABLE',
        'POLICY_DISABLED'
      ].contains(region['reason'])) {
        throw const FormatException('Unknown disable reason');
      }
    }
    // Check all counts before intersections and index construction (quadratic work).
    var vertices = 0;
    List<_Line> lines(dynamic value, bool road) {
      final collection = _object(value);
      _keys(collection, const ['type', 'features']);
      if (collection['type'] != 'FeatureCollection') {
        throw const FormatException('FeatureCollection required');
      }
      final output = <_Line>[];
      final ids = <String>{};
      for (final item in _list(collection['features'], maximum: 256)) {
        final feature = _object(item);
        _keys(feature, const ['type', 'properties', 'geometry']);
        if (feature['type'] != 'Feature') {
          throw const FormatException('Feature required');
        }
        final properties = _object(feature['properties']);
        _keys(
            properties,
            road
                ? const [
                    'roadLinkId',
                    'fromNodeId',
                    'toNodeId',
                    'level',
                    'source'
                  ]
                : const ['stopLineId', 'intersectionKey', 'level', 'source']);
        final id = _text(properties[road ? 'roadLinkId' : 'stopLineId']);
        if (!ids.add(id)) {
          throw const FormatException('Duplicate geometry identity');
        }
        sourceReference(properties['source']);
        _integer(properties['level'], minimum: -9007199254740991);
        if (road) {
          _text(properties['fromNodeId']);
          _text(properties['toNodeId']);
        } else if (!intersections
            .containsKey(_text(properties['intersectionKey']))) {
          throw const FormatException('Stop intersection missing');
        }
        final geometry = _object(feature['geometry']);
        _keys(geometry, const ['type', 'coordinates']);
        if (geometry['type'] != 'LineString') {
          throw const FormatException('LineString required');
        }
        final coordinates = _list(geometry['coordinates'], maximum: 4096);
        vertices += coordinates.length;
        if (coordinates.length < 2 || vertices > 4096) {
          throw const FormatException('Vertex bound');
        }
        final points = coordinates.map(_point).toList(growable: false);
        for (var i = 1; i < points.length; i++) {
          if (points[i].same(points[i - 1]) ||
              (points[i].longitude - points[i - 1].longitude).abs() >= 180 ||
              geoDistance(points[i - 1], points[i]) * 1.01 >= 2000) {
            throw const FormatException(
                'Degenerate, antimeridian or overlong segment');
          }
        }
        output.add(_Line(id, properties, points));
      }
      return output;
    }

    final roadLines = lines(spatial['roads'], true);
    final stopLines = lines(spatial['stopLines'], false);
    if (roadLines.isEmpty) throw const FormatException('No road geometry');
    final roadIds = {
      for (var i = 0; i < roadLines.length; i++) roadLines[i].id: i
    };
    final stopIds = {for (final stop in stopLines) stop.id: stop};
    final nodes = <String, GeoPoint>{};
    final nodeLevels = <String, int>{};
    final segments = <List<RoadSegment>>[];
    final outgoing = <String, List<int>>{};
    for (var i = 0; i < roadLines.length; i++) {
      final road = roadLines[i];
      for (final entry in [
        MapEntry(road.properties['fromNodeId'] as String, road.points.first),
        MapEntry(road.properties['toNodeId'] as String, road.points.last)
      ]) {
        if (nodes.containsKey(entry.key) &&
            (!nodes[entry.key]!.same(entry.value) ||
                nodeLevels[entry.key] != road.properties['level'])) {
          throw const FormatException(
              'Shared node coordinate or level mismatch');
        }
        nodes[entry.key] = entry.value;
        nodeLevels[entry.key] = road.properties['level'] as int;
      }
      outgoing
          .putIfAbsent(road.properties['fromNodeId'] as String, () => [])
          .add(i);
      var distance = 0.0;
      final parts = <RoadSegment>[];
      for (var j = 1; j < road.points.length; j++) {
        final segment =
            RoadSegment(i, road.points[j - 1], road.points[j], distance);
        parts.add(segment);
        distance += segment.lengthM;
      }
      segments.add(parts);
    }
    final crossingCache =
        List.generate(roadLines.length, (_) => <String, List<double>>{});
    List<double> crossingsFor(int roadIndex, _Line stop) =>
        crossingCache[roadIndex].putIfAbsent(
            stop.id, () => _crossings(segments[roadIndex], stop.points));
    final roadStops = List.generate(roadLines.length, (_) => <RoadStop>[]);
    final missingBarriers = <int>{};
    final assignedStops = <String>{};
    var unlocatedBarrier = false;
    for (final value in _list(json['approaches'], maximum: 1024)) {
      final approach = _object(value);
      _keys(approach, const [
        'approachKey',
        'intersectionKey',
        'movement',
        'enabledForOperation',
        'roadLinkId',
        'stopLineId',
        'level',
        'sourceDirectionCode',
        'directionReview',
        'geometryReview',
        'source'
      ]);
      final key = _text(approach['approachKey']);
      if (!identities.add(key)) {
        throw const FormatException('Duplicate catalog identity');
      }
      final intersection = intersections[_text(approach['intersectionKey'])];
      if (intersection == null) {
        throw const FormatException('Missing approach intersection');
      }
      sourceReference(approach['source']);
      if (!const ['straight', 'left', 'uturn', 'bus', 'bicycle', 'pedestrian']
              .contains(approach['movement']) ||
          !const ['nt', 'et', 'st', 'wt', 'ne', 'se', 'sw', 'nw']
              .contains(approach['sourceDirectionCode'])) {
        throw const FormatException('Unknown movement or direction');
      }
      var reviewed = true;
      for (final field in ['directionReview', 'geometryReview']) {
        final review = _object(approach[field]);
        _keys(review, const ['verified', 'evidence']);
        reviewed = _boolean(review['verified']) && reviewed;
        _text(review['evidence']);
      }
      final enabled = _boolean(approach['enabledForOperation']);
      final roadId =
          approach['roadLinkId'] == null ? null : _text(approach['roadLinkId']);
      final stopId =
          approach['stopLineId'] == null ? null : _text(approach['stopLineId']);
      final level = approach['level'] == null
          ? null
          : _integer(approach['level'], minimum: -9007199254740991);
      final roadIndex = roadIds[roadId];
      final stop = stopIds[stopId];
      if ((roadId != null && roadIndex == null) ||
          (stopId != null && stop == null)) {
        throw const FormatException('Unresolved approach geometry reference');
      }
      if (enabled &&
          (!reviewed ||
              approach['movement'] != 'straight' ||
              roadIndex == null ||
              stop == null ||
              level == null)) {
        throw const FormatException(
            'Enabled approach lacks reviewed straight geometry');
      }
      if (roadIndex == null) {
        unlocatedBarrier = true;
        continue;
      }
      if (stop == null) {
        missingBarriers.add(roadIndex);
        continue;
      }
      if (level == null ||
          level != roadLines[roadIndex].properties['level'] ||
          level != stop.properties['level'] ||
          stop.properties['intersectionKey'] != approach['intersectionKey']) {
        throw const FormatException('Stop identity or grade mismatch');
      }
      final crossings = crossingsFor(roadIndex, stop);
      if (crossings.length != 1) {
        throw const FormatException('Stop must cross road exactly once');
      }
      assignedStops.add(stop.id);
      final provider = intersection['provider'] as String;
      final blocked = disabled.contains('provider:$provider') ||
          disabled.contains('intersection:${approach['intersectionKey']}') ||
          disabled.contains('approach:$key');
      roadStops[roadIndex].add(RoadStop(
          crossings.single,
          enabled && reviewed && !blocked
              ? MatchedApproach(
                  provider: provider,
                  intersectionKey: intersection['intersectionKey'] as String,
                  approachKey: key,
                  catalogVersion: version)
              : null));
    }
    // Unmapped physical stop lines are barriers, never silently skipped. A stop
    // assigned to another directed approach does not imply a stop in this lane.
    for (final stop
        in stopLines.where((stop) => !assignedStops.contains(stop.id))) {
      for (var i = 0; i < roadLines.length; i++) {
        if (roadLines[i].properties['level'] != stop.properties['level']) {
          continue;
        }
        for (final distance in crossingsFor(i, stop)) {
          roadStops[i].add(RoadStop(distance, null));
        }
      }
    }
    final roads = <DirectedRoad>[];
    for (var i = 0; i < roadLines.length; i++) {
      roadStops[i].sort((a, b) => a.alongM.compareTo(b.alongM));
      final road = roadLines[i];
      roads.add(DirectedRoad(
          id: road.id,
          fromNodeId: road.properties['fromNodeId'] as String,
          toNodeId: road.properties['toNodeId'] as String,
          level: road.properties['level'] as int,
          segments: segments[i],
          stops: roadStops[i],
          hasUnlocatedBarrier: missingBarriers.contains(i)));
    }
    return DrivingBundle._(version, prediction, syntheticFixture, policy, roads,
        outgoing, unlocatedBarrier);
  }
}

class _Line {
  const _Line(this.id, this.properties, this.points);
  final String id;
  final Map<String, dynamic> properties;
  final List<GeoPoint> points;
}

/// Same planar crossing semantics as tools/spatial-audit; arc length is in meters.
List<double> _crossings(List<RoadSegment> road, List<GeoPoint> stop) {
  final crossings = <String, double>{};
  for (final segment in road) {
    final a = segment.start, b = segment.end;
    final rx = b.longitude - a.longitude, ry = b.latitude - a.latitude;
    for (var i = 1; i < stop.length; i++) {
      final c = stop[i - 1], d = stop[i];
      if (!segment.bounds.intersects(GeoBounds.points(c, d))) continue;
      final sx = d.longitude - c.longitude, sy = d.latitude - c.latitude;
      final qx = c.longitude - a.longitude, qy = c.latitude - a.latitude;
      final determinant = rx * sy - ry * sx;
      if (determinant == 0) {
        if (qx * ry - qy * rx == 0) {
          throw const FormatException('Collinear stop line');
        }
        continue;
      }
      final t = (qx * sy - qy * sx) / determinant;
      final u = (qx * ry - qy * rx) / determinant;
      if (t < 0 || t > 1 || u < 0 || u > 1) continue;
      final point = GeoPoint(a.longitude + t * rx, a.latitude + t * ry);
      final key =
          '${point.longitude.toStringAsFixed(12)}:${point.latitude.toStringAsFixed(12)}';
      final distance = segment.offsetM + geoDistance(a, point);
      if (crossings.containsKey(key) &&
          (crossings[key]! - distance).abs() > 0.000001) {
        throw const FormatException('Road revisits stop line');
      }
      crossings[key] = distance;
    }
  }
  return crossings.values.toList(growable: false);
}

PredictionPolicy _prediction(Map<String, dynamic> json, bool synthetic) {
  _keys(json, const [
    'schemaVersion',
    'kind',
    'policyVersion',
    'approvedForOperation',
    'maxSignalAgeMs',
    'clockSkewBudgetMs',
    'minimumSpeedMps',
    'maxHorizontalAccuracyM',
    'extraSafetyMarginMs',
    'measurementEvidence'
  ]);
  if (json['schemaVersion'] != 'sa-contract-1' ||
      json['kind'] != 'PredictionPolicy') {
    throw const FormatException('PredictionPolicy required');
  }
  final version = _text(json['policyVersion']);
  final evidence = _text(json['measurementEvidence']);
  final approved = _boolean(json['approvedForOperation']);
  if (!synthetic && !approved) {
    throw const FormatException('Prediction policy not approved');
  }
  final age = _integer(json['maxSignalAgeMs'], minimum: 1);
  final skew = _integer(json['clockSkewBudgetMs']);
  final speed = _positive(json['minimumSpeedMps']);
  final accuracy = _positive(json['maxHorizontalAccuracyM']);
  final margin = _integer(json['extraSafetyMarginMs']);
  return synthetic
      ? PredictionPolicy.syntheticFixture(
          maxSignalAgeMs: age,
          clockSkewBudgetMs: skew,
          minimumSpeedMps: speed,
          maxHorizontalAccuracyM: accuracy,
          extraSafetyMarginMs: margin)
      : PredictionPolicy(
          policyVersion: version,
          approvedForOperation: approved,
          measurementEvidence: evidence,
          maxSignalAgeMs: age,
          clockSkewBudgetMs: skew,
          minimumSpeedMps: speed,
          maxHorizontalAccuracyM: accuracy,
          extraSafetyMarginMs: margin);
}

Map<String, dynamic> _object(dynamic value) {
  if (value is! Map<String, dynamic>) {
    throw const FormatException('Object required');
  }
  return value;
}

List<dynamic> _list(dynamic value, {required int maximum}) {
  if (value is! List || value.length > maximum) {
    throw const FormatException('Array bound');
  }
  return value;
}

void _keys(Map<String, dynamic> json, List<String> required,
    {List<String> optional = const []}) {
  if (required.any((key) => !json.containsKey(key)) ||
      json.keys
          .any((key) => !required.contains(key) && !optional.contains(key))) {
    throw const FormatException('Missing or unknown fields');
  }
}

String _text(dynamic value) {
  if (value is! String || value.trim().isEmpty || value.length > 4096) {
    throw const FormatException('Nonblank bounded string required');
  }
  return value;
}

String _provider(dynamic value) {
  final text = _text(value);
  if (!RegExp(r'^[a-z][a-z0-9._-]{0,63}$').hasMatch(text)) {
    throw const FormatException('Invalid provider');
  }
  return text;
}

bool _boolean(dynamic value) {
  if (value is! bool) throw const FormatException('Boolean required');
  return value;
}

int _integer(dynamic value, {int minimum = 0, int maximum = 9007199254740991}) {
  if (value is! int || value < minimum || value > maximum) {
    throw const FormatException('Integer bound');
  }
  return value;
}

double _positive(dynamic value, {bool zero = false}) {
  if (value is! num || !value.isFinite || (zero ? value < 0 : value <= 0)) {
    throw const FormatException('Finite policy number required');
  }
  return value.toDouble();
}

GeoPoint _point(dynamic value) {
  if (value is! List ||
      value.length != 2 ||
      value.any((v) => v is! num || !v.isFinite) ||
      value[0] < -180 ||
      value[0] > 180 ||
      value[1] <= -90 ||
      value[1] >= 90) {
    throw const FormatException('Finite CRS84 longitude/latitude required');
  }
  return GeoPoint((value[0] as num).toDouble(), (value[1] as num).toDouble());
}
