import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';

enum LocationBlocker {
  permissionDenied,
  permissionDeniedForever,
  preciseLocationOff,
  serviceOff,
  staleLocation,
  sensorError,
}

abstract interface class LocationGateway {
  Future<LocationBlocker?> authorize({required bool requestPermission});
  Stream<Position> positions();
  Stream<ServiceStatus> serviceStatus();
  Future<void> openSettings();
}

class PlatformLocationGateway implements LocationGateway {
  @override
  Future<LocationBlocker?> authorize({required bool requestPermission}) async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      return LocationBlocker.serviceOff;
    }
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied && requestPermission) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.deniedForever) {
      return LocationBlocker.permissionDeniedForever;
    }
    if (permission != LocationPermission.whileInUse &&
        permission != LocationPermission.always) {
      return LocationBlocker.permissionDenied;
    }
    if (await Geolocator.getLocationAccuracy() ==
        LocationAccuracyStatus.reduced) {
      return LocationBlocker.preciseLocationOff;
    }
    return null;
  }

  @override
  Stream<Position> positions() {
    final LocationSettings settings;
    if (!kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.iOS ||
            defaultTargetPlatform == TargetPlatform.macOS)) {
      settings = AppleSettings(
        accuracy: LocationAccuracy.bestForNavigation,
        distanceFilter: 0,
        activityType: ActivityType.automotiveNavigation,
        allowBackgroundLocationUpdates: false,
      );
    } else {
      settings = const LocationSettings(
        accuracy: LocationAccuracy.bestForNavigation,
        distanceFilter: 0,
      );
    }
    return Geolocator.getPositionStream(locationSettings: settings);
  }

  @override
  Stream<ServiceStatus> serviceStatus() => Geolocator.getServiceStatusStream();

  @override
  Future<void> openSettings() async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      await Geolocator.openLocationSettings();
    } else {
      await Geolocator.openAppSettings();
    }
  }
}
