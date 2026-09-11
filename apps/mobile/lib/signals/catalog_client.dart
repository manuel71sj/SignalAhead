import 'dart:convert';
import 'dart:math' as math;

import 'package:http/http.dart' as http;

import '../location/location_sample.dart';

enum CoverageStatus {
  checking,
  unsupported,
  geometryUnavailable,
  offline,
  notConfigured
}

class CoverageResult {
  const CoverageResult(this.status, {this.catalogVersion});
  final CoverageStatus status;
  final String? catalogVersion;
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
          .get(base.resolve('/v1/catalog').replace(
            queryParameters: {'bbox': bbox},
          ))
          .timeout(const Duration(seconds: 5));
      if (response.statusCode != 200 ||
          response.bodyBytes.length > 1024 * 1024) {
        return const CoverageResult(CoverageStatus.offline);
      }
      final data = jsonDecode(response.body);
      if (data is! Map<String, dynamic> ||
          data['approaches'] is! List ||
          data['intersections'] is! List ||
          (data['catalogVersion'] != null &&
              data['catalogVersion'] is! String)) {
        return const CoverageResult(CoverageStatus.offline);
      }
      final approaches = data['approaches'] as List;
      // The current catalog contract contains IDs/reviews but no road polyline
      // or stop-line geometry. Never turn its nearest center into a target.
      return CoverageResult(
        approaches.isEmpty
            ? CoverageStatus.unsupported
            : CoverageStatus.geometryUnavailable,
        catalogVersion: data['catalogVersion'] as String?,
      );
    } on Exception {
      return const CoverageResult(CoverageStatus.offline);
    }
  }

  @override
  void close() => _client.close();
}
