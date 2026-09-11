import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:signalahead_mobile/location/location_sample.dart';
import 'package:signalahead_mobile/map_matching/driving_bundle.dart';
import 'package:signalahead_mobile/map_matching/road_matcher.dart';
import 'package:signalahead_mobile/prediction/prediction.dart';

Map<String, dynamic> fixture({bool overpass = false}) {
  final json = jsonDecode(File('../../fixtures/spatial/driving-catalog.json')
      .readAsStringSync()) as Map<String, dynamic>;
  if (!overpass) {
    roads(json).removeWhere(
        (dynamic road) => road['properties']['roadLinkId'] == 'upper');
  }
  return json;
}

List<dynamic> roads(Map<String, dynamic> json) =>
    json['spatial']['roads']['features'] as List<dynamic>;
List<dynamic> stops(Map<String, dynamic> json) =>
    json['spatial']['stopLines']['features'] as List<dynamic>;
Map<String, dynamic> approach(Map<String, dynamic> json, String road) =>
    (json['approaches'] as List)
        .cast<Map<String, dynamic>>()
        .singleWhere((item) => item['roadLinkId'] == road);
DrivingBundle decode(Map<String, dynamic> json) =>
    DrivingBundle.fromJson(json, syntheticFixture: true);

LocationSample fix(double longitude, double latitude, double course, int tick,
        {String session = 'drive',
        double accuracy = 1,
        double courseAccuracy = 2,
        int? utc}) =>
    LocationSample(
        sessionId: session,
        latitude: latitude,
        longitude: longitude,
        horizontalAccuracyM: accuracy,
        speedMps: 10,
        speedAccuracyMps: 0.5,
        courseDeg: course,
        courseAccuracyDeg: courseAccuracy,
        measuredAtUtcMs: utc ?? 100000 + tick * 1000,
        deviceReceivedMonotonicMs: tick * 1000);

MatchingResult feed(RoadMatcher matcher, List<LocationSample> samples) {
  MatchingResult? result;
  for (final sample in samples) {
    result = matcher.update(sample, sample.deviceReceivedMonotonicMs);
  }
  return result!;
}

List<LocationSample> west({int start = 1, String session = 'drive'}) => [
      fix(126.9991, 37, 90, start, session: session),
      fix(126.9993, 37, 90, start + 1, session: session),
      fix(126.9995, 37, 90, start + 2, session: session),
    ];

Map<String, dynamic> roadFeature(
        String id, String from, String to, List<List<double>> coordinates,
        {int level = 0}) =>
    {
      'type': 'Feature',
      'properties': {
        'roadLinkId': id,
        'fromNodeId': from,
        'toNodeId': to,
        'level': level,
        'source': 'synthetic'
      },
      'geometry': {'type': 'LineString', 'coordinates': coordinates},
    };

void main() {
  group('Directed roads and actual stop-line distances', () {
    final cases = <String, List<LocationSample>>{
      'west': west(),
      'east': [
        fix(127.0009, 37, 270, 1),
        fix(127.0007, 37, 270, 2),
        fix(127.0005, 37, 270, 3)
      ],
      'north': [
        fix(127, 37.0009, 180, 1),
        fix(127, 37.0007, 180, 2),
        fix(127, 37.0005, 180, 3)
      ],
      'south': [
        fix(127, 36.9991, 0, 1),
        fix(127, 36.9993, 0, 2),
        fix(127, 36.9995, 0, 3)
      ],
    };
    for (final entry in cases.entries) {
      test(
          '${entry.key} approach preserves provider identity and distance interval',
          () {
        final result = feed(RoadMatcher(decode(fixture())), entry.value);
        expect(result.status, MatchingStatus.matched);
        expect(result.approach!.approachKey, 'synthetic:${entry.key}-approach');
        expect(result.approach!.intersectionKey, 'synthetic:i1');
        expect(result.approach!.provider, 'synthetic');
        final expected =
            entry.key == 'west' || entry.key == 'east' ? 26.6413 : 33.3585;
        expect(result.distanceM!.min, lessThan(expected));
        expect(result.distanceM!.max, greaterThan(expected));
        expect(result.distanceM!.max! - result.distanceM!.min!,
            greaterThanOrEqualTo(2 * (2 + expected * 0.01)));
      });
    }

    test('a nearer intersection on another road is not the driving target', () {
      final json = fixture();
      final nearby = Map<String, dynamic>.from(
          (json['intersections'] as List).first as Map);
      nearby['intersectionKey'] = 'synthetic:near';
      nearby['sourceIntersectionId'] = 'near';
      nearby['coordinates'] = [126.9995, 37.0003];
      (json['intersections'] as List).add(nearby);
      final other = jsonDecode(jsonEncode(approach(json, 'west')))
          as Map<String, dynamic>;
      other.addAll({
        'approachKey': 'synthetic:parallel-approach',
        'intersectionKey': 'synthetic:near',
        'roadLinkId': 'parallel',
        'stopLineId': 'parallel-stop'
      });
      (json['approaches'] as List).add(other);
      stops(json).add({
        'type': 'Feature',
        'properties': {
          'source': 'synthetic',
          'stopLineId': 'parallel-stop',
          'intersectionKey': 'synthetic:near',
          'level': 0
        },
        'geometry': {
          'type': 'LineString',
          'coordinates': [
            [126.9996, 37.0002],
            [126.9996, 37.0004]
          ]
        }
      });
      final bundle = decode(json);
      expect(feed(RoadMatcher(bundle), west()).approach!.approachKey,
          'synthetic:west-approach');
      expect(
          feed(RoadMatcher(bundle), [
            fix(126.9991, 37.0003, 90, 1),
            fix(126.99925, 37.0003, 90, 2),
            fix(126.9994, 37.0003, 90, 3)
          ]).approach!.approachKey,
          'synthetic:parallel-approach');
    });

    test('GPS course alone cannot reverse the observed direction of travel',
        () {
      final result = feed(RoadMatcher(decode(fixture())), [
        fix(127.0003, 37, 270, 1),
        fix(127.0005, 37, 270, 2),
        fix(127.0007, 37, 270, 3)
      ]);
      expect(result.status, isNot(MatchingStatus.matched));
      expect(result.approach, isNull);
    });

    test('grade overlap cannot be resolved by coordinates and heading', () {
      final result = feed(RoadMatcher(decode(fixture(overpass: true))), west());
      expect(result.status, MatchingStatus.ambiguous);
      expect(result.approach, isNull);
      expect(result.distanceM, isNull);
    });

    test(
        'recent uniquely observed feeder establishes directed grade connectivity',
        () {
      final json = fixture(overpass: true);
      roads(json).add(roadFeature('feeder', 'f0', 'w', [
        [126.998, 37],
        [126.999, 37]
      ]));
      final result = feed(RoadMatcher(decode(json)), [
        fix(126.9983, 37, 90, 1),
        fix(126.9985, 37, 90, 2),
        fix(126.9987, 37, 90, 3),
        fix(126.9991, 37, 90, 4),
        fix(126.9993, 37, 90, 5),
        fix(126.9995, 37, 90, 6)
      ]);
      expect(result.status, MatchingStatus.matched);
      expect(result.approach!.approachKey, 'synthetic:west-approach');
    });

    test(
        'uncertainty at a stop immediately invalidates the old target; then advances',
        () {
      final matcher = RoadMatcher(decode(fixture()));
      expect(feed(matcher, west()).approach!.approachKey,
          'synthetic:west-approach');
      final crossing = matcher.update(fix(126.9998, 37, 90, 4), 4000);
      expect(crossing.status, MatchingStatus.ambiguous);
      expect(crossing.approach, isNull);
      final passed = matcher.update(fix(126.9999, 37, 90, 5), 5000);
      expect(passed.status, MatchingStatus.matched);
      expect(passed.approach!.approachKey, 'synthetic:eastward-approach');
      final nextRoad = matcher.update(fix(127.0003, 37, 90, 6), 6000);
      expect(nextRoad.approach!.approachKey, 'synthetic:eastward-approach');
    });

    test('a disabled or missing stop cannot be skipped to a later signal', () {
      for (final missing in [false, true]) {
        final json = fixture();
        final first = approach(json, 'west');
        first['enabledForOperation'] = false;
        if (missing) {
          first['stopLineId'] = null;
          stops(json).removeWhere((dynamic stop) =>
              stop['properties']['stopLineId'] == 'west-stop');
        }
        final result = feed(RoadMatcher(decode(json)), west());
        expect(result.status, MatchingStatus.unsupported);
        expect(result.approach, isNull);
      }
    });

    test('unassigned physical stop is a barrier ahead of the reviewed stop',
        () {
      final json = fixture();
      stops(json).add({
        'type': 'Feature',
        'properties': {
          'source': 'synthetic',
          'stopLineId': 'unreviewed',
          'intersectionKey': 'synthetic:i1',
          'level': 0
        },
        'geometry': {
          'type': 'LineString',
          'coordinates': [
            [126.99965, 36.9999],
            [126.99965, 37.0001]
          ]
        }
      });
      final result = feed(RoadMatcher(decode(json)), west());
      expect(result.status, MatchingStatus.unsupported);
      expect(result.approach, isNull);
    });

    test('a fork requires observed branch entry rather than smallest bearing',
        () {
      final json = fixture();
      roads(json).add(roadFeature('branch', 'i1', 'b1', [
        [127, 37],
        [127.0007, 37.0005]
      ]));
      final matcher = RoadMatcher(decode(json));
      expect(feed(matcher, west()).approach!.approachKey,
          'synthetic:west-approach');
      final fork = matcher.update(fix(126.9999, 37, 90, 4), 4000);
      expect(fork.status, MatchingStatus.ambiguous);
      expect(fork.approach, isNull);
      final entered = matcher.update(fix(127.0003, 37, 90, 5), 5000);
      expect(entered.approach!.approachKey, 'synthetic:eastward-approach');
    });
  });

  group('Bounded motion evidence and immediate invalidation', () {
    test(
        'stationary jitter and repeated source timestamps do not confirm motion',
        () {
      final matcher = RoadMatcher(decode(fixture()));
      for (var tick = 1; tick <= 40; tick++) {
        final result = matcher.update(
            fix(126.9995 + (tick.isEven ? 0.000001 : 0), 37, 90, tick),
            tick * 1000);
        expect(result.status, isNot(MatchingStatus.matched));
      }
      matcher.clear();
      final samples = west();
      for (var i = 0; i < samples.length; i++) {
        final result = matcher.update(
            fix(samples[i].longitude, 37, 90, i + 1, utc: 100000),
            (i + 1) * 1000);
        expect(result.status, isNot(MatchingStatus.matched));
      }
    });

    test(
        'session change, stale history, bad accuracy and bad course discard targets',
        () {
      final bundle = decode(fixture());
      final sessionMatcher = RoadMatcher(bundle);
      expect(feed(sessionMatcher, west()).status, MatchingStatus.matched);
      expect(
          sessionMatcher
              .update(fix(126.9996, 37, 90, 4, session: 'new'), 4000)
              .approach,
          isNull);
      final ageMatcher = RoadMatcher(bundle);
      expect(feed(ageMatcher, west()).status, MatchingStatus.matched);
      expect(
          ageMatcher.update(fix(126.9996, 37, 90, 20), 20000).approach, isNull);
      for (final invalid in [
        fix(126.9996, 37, 90, 4, accuracy: 16),
        fix(126.9996, 37, 90, 4, courseAccuracy: 40)
      ]) {
        final matcher = RoadMatcher(bundle);
        expect(feed(matcher, west()).status, MatchingStatus.matched);
        expect(
            matcher.update(invalid, 4000).status, MatchingStatus.unsupported);
      }
    });

    test('parallel roads inside the location uncertainty remain ambiguous', () {
      final json = fixture();
      final parallel = roads(json).singleWhere(
          (dynamic road) => road['properties']['roadLinkId'] == 'parallel');
      parallel['geometry']['coordinates'] = [
        [126.999, 37.00002],
        [127, 37.00002]
      ];
      expect(feed(RoadMatcher(decode(json)), west()).status,
          MatchingStatus.ambiguous);
    });
  });

  group('Full bundle trust and geometry validation', () {
    test('synthetic geometry cannot become an operational prediction policy',
        () {
      final json = fixture();
      expect(() => DrivingBundle.fromJson(json), throwsFormatException);
      json['spatial']['matchingPolicy']['approvedForOperation'] = true;
      json['spatial']['predictionPolicy']['approvedForOperation'] = true;
      expect(() => DrivingBundle.fromJson(json), throwsFormatException);
      final bundle = decode(json);
      final result = evaluatePrediction(
          PredictionInput(
              sessionActive: true,
              targetMatched: true,
              signalState: SignalState.green,
              signalFresh: true,
              timingQuality: TimingQuality.verified,
              locationValid: true,
              horizontalAccuracyM: 1,
              distanceM: const NumericInterval(min: 10, max: 20),
              speedMps: const NumericInterval(min: 5, max: 6),
              greenRemainingMs:
                  const IntervalMs(earliestMs: 10000, latestMs: 12000)),
          bundle.predictionPolicy);
      expect(result.reason, PredictionReason.policyUncalibrated);
    });

    test('rights denial and unapproved recorded policies fail closed', () {
      final denied = fixture();
      denied['sources']['synthetic']['rights']['deviceMatching']['allowed'] =
          false;
      expect(() => decode(denied), throwsFormatException);
      final unapproved = fixture();
      unapproved['sources']['synthetic']['origin'] = 'recorded';
      expect(() => DrivingBundle.fromJson(unapproved), throwsFormatException);
    });

    test(
        'missing enabled geometry, wrong grade and collinear stop are rejected',
        () {
      final missing = fixture();
      approach(missing, 'west')['stopLineId'] = null;
      expect(() => decode(missing), throwsFormatException);
      final grade = fixture();
      approach(grade, 'west')['level'] = 1;
      expect(() => decode(grade), throwsFormatException);
      final collinear = fixture();
      final stop = stops(collinear).singleWhere(
          (dynamic stop) => stop['properties']['stopLineId'] == 'west-stop');
      stop['geometry']['coordinates'] = [
        [126.9997, 37],
        [126.9999, 37]
      ];
      expect(() => decode(collinear), throwsFormatException);
    });

    test('repeated stop crossing and inconsistent shared nodes are rejected',
        () {
      final repeated = fixture();
      final road = roads(repeated).singleWhere(
          (dynamic road) => road['properties']['roadLinkId'] == 'west');
      road['geometry']['coordinates'] = [
        [126.999, 37],
        [126.9999, 37],
        [126.9996, 37],
        [127, 37]
      ];
      expect(() => decode(repeated), throwsFormatException);
      final shared = fixture();
      roads(shared).add(roadFeature('bad-shared', 'w', 'bad-end', [
        [126.9989, 37],
        [126.998, 37]
      ]));
      expect(() => decode(shared), throwsFormatException);
    });

    test('geometry and policy work bounds are enforced before matching', () {
      final oversized = fixture();
      for (var i = roads(oversized).length; i <= 256; i++) {
        roads(oversized).add(roadFeature('extra-$i', 'a-$i', 'z-$i', [
          [126.998, 37],
          [126.999, 37]
        ]));
      }
      expect(() => decode(oversized), throwsFormatException);
      final history = fixture();
      history['spatial']['matchingPolicy']['confirmationSamples'] = 11;
      expect(() => decode(history), throwsFormatException);
      final radius = fixture();
      radius['spatial']['matchingPolicy']['candidateSearchRadiusM'] = 2001;
      expect(() => decode(radius), throwsFormatException);
    });
  });
}
