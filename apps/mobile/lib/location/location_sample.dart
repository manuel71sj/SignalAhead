class LocationSample {
  const LocationSample({
    required this.sessionId,
    required this.latitude,
    required this.longitude,
    required this.horizontalAccuracyM,
    required this.speedMps,
    required this.speedAccuracyMps,
    required this.courseDeg,
    required this.courseAccuracyDeg,
    required this.measuredAtUtcMs,
    required this.deviceReceivedMonotonicMs,
  });

  final String sessionId;
  final double latitude;
  final double longitude;
  final double horizontalAccuracyM;
  final double? speedMps;
  final double? speedAccuracyMps;
  final double? courseDeg;
  final double? courseAccuracyDeg;
  final int measuredAtUtcMs;
  final int deviceReceivedMonotonicMs;

  static double? nonNegativeOrNull(double value) {
    if (!value.isFinite || value < 0) {
      return null;
    }
    return value;
  }

  static double? courseOrNull(double value) {
    if (!value.isFinite || value < 0 || value >= 360) {
      return null;
    }
    return value;
  }

  Map<String, Object?> toJson() => {
        'schemaVersion': 'sa-contract-1',
        'kind': 'LocationSample',
        'sessionId': sessionId,
        'latitude': latitude,
        'longitude': longitude,
        'horizontalAccuracyM': horizontalAccuracyM,
        'speedMps': speedMps,
        'speedAccuracyMps': speedAccuracyMps,
        'courseDeg': courseDeg,
        'courseAccuracyDeg': courseAccuracyDeg,
        'measuredAtUtcMs': measuredAtUtcMs,
        'deviceReceivedMonotonicMs': deviceReceivedMonotonicMs,
      };
}
