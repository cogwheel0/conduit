import 'package:conduit_core/conduit_core.dart';
import 'package:geolocator/geolocator.dart';

/// The mobile [LocationPort], backed by the OS location services through
/// `geolocator`.
class GeolocatorLocationPort implements LocationPort {
  const GeolocatorLocationPort();

  @override
  Future<bool> isLocationServiceEnabled() {
    return Geolocator.isLocationServiceEnabled();
  }

  @override
  Future<LocationPermissionStatus> checkPermission() async {
    return _toStatus(await Geolocator.checkPermission());
  }

  @override
  Future<LocationPermissionStatus> requestPermission() async {
    return _toStatus(await Geolocator.requestPermission());
  }

  @override
  Future<LocationFix> currentPosition() async {
    final position = await Geolocator.getCurrentPosition(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.medium,
      ),
    );
    return LocationFix(
      latitude: position.latitude,
      longitude: position.longitude,
    );
  }

  static LocationPermissionStatus _toStatus(LocationPermission permission) {
    return switch (permission) {
      LocationPermission.denied => LocationPermissionStatus.denied,
      LocationPermission.deniedForever =>
        LocationPermissionStatus.deniedForever,
      LocationPermission.whileInUse => LocationPermissionStatus.whileInUse,
      LocationPermission.always => LocationPermissionStatus.always,
      LocationPermission.unableToDetermine =>
        LocationPermissionStatus.unableToDetermine,
    };
  }
}
