import 'dart:convert';
import 'dart:math' as math;

import 'package:http/http.dart' as http;

import '../location/location_sample.dart';
import '../map_matching/driving_bundle.dart';

enum CoverageStatus {
  checking,
  supported,
  unsupported,
  geometryUnavailable,
  offline,
  notConfigured
}

class CoverageResult {
  const CoverageResult(this.status, {this.bundle});
  final CoverageStatus status;
  final DrivingBundle? bundle;
  String? get catalogVersion => bundle?.catalogVersion;
}

abstract interface class CatalogClient {
  Future<CoverageResult> coverage(LocationSample sample);
  void close();
}

class HttpCatalogClient implements CatalogClient {
  HttpCatalogClient(this.baseUri) : _client = http.Client();
  final Uri? baseUri;
  final http.Client _client;

  @override
  Future<CoverageResult> coverage(LocationSample sample) async {
    final base = baseUri;
    if (base == null) return const CoverageResult(CoverageStatus.notConfigured);
    // Only a bounded nearby catalog query leaves the device, never raw history.
    const latitudeRadius = 0.005;
    final longitudeRadius = math.min(
      0.02,
      latitudeRadius / math.cos(sample.latitude * math.pi / 180).abs(),
    );
    final bbox = [
      math.max(-180, sample.longitude - longitudeRadius),
      math.max(-89.9999, sample.latitude - latitudeRadius),
      math.min(180, sample.longitude + longitudeRadius),
      math.min(89.9999, sample.latitude + latitudeRadius),
    ].join(',');
    try {
      final response = await _client
          .get(base.resolve('/v1/driving-bundle').replace(
            queryParameters: {'bbox': bbox},
          ))
          .timeout(const Duration(seconds: 5));
      if (response.statusCode != 200 ||
          response.bodyBytes.length > 1024 * 1024) {
        return const CoverageResult(CoverageStatus.offline);
      }
      final data = jsonDecode(response.body);
      if (data is! Map<String, dynamic> || !data.containsKey('catalog')) {
        return const CoverageResult(CoverageStatus.offline);
      }
      final catalog = data['catalog'];
      if (catalog == null) {
        return const CoverageResult(CoverageStatus.unsupported);
      }
      if (catalog is! Map<String, dynamic>) {
        return const CoverageResult(CoverageStatus.geometryUnavailable);
      }
      try {
        final bundle = DrivingBundle.fromJson(catalog);
        return CoverageResult(CoverageStatus.supported, bundle: bundle);
      } on FormatException {
        return const CoverageResult(CoverageStatus.geometryUnavailable);
      }
    } on Exception {
      return const CoverageResult(CoverageStatus.offline);
    }
  }

  @override
  void close() => _client.close();
}
