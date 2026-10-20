import 'package:meta/meta.dart';

/// The platform's answer to "may this app read the device location".
///
/// Mirrors the states the mobile location plugins report, so a host adapter
/// is a one-to-one mapping.
enum LocationPermissionStatus {
  denied,
  deniedForever,
  whileInUse,
  always,
  unableToDetermine,
}

/// A position fix, reduced to what Open WebUI's `{{USER_LOCATION}}` needs.
@immutable
class LocationFix {
  const LocationFix({required this.latitude, required this.longitude});

  final double latitude;
  final double longitude;
}

/// Reads the device location.
///
/// A port because only a host with location services can answer: the mobile
/// app asks the OS, while the daemon and tests have no device to ask. The
/// decisions around it -- whether the user enabled location, the timeout, the
/// formatting Open WebUI expects, syncing it back to the server -- live in
/// the core's `LocationService`.
abstract interface class LocationPort {
  Future<bool> isLocationServiceEnabled();

  Future<LocationPermissionStatus> checkPermission();

  Future<LocationPermissionStatus> requestPermission();

  Future<LocationFix> currentPosition();

  /// The host's implementation, installed once at startup.
  static LocationPort hostDefault = const NullLocationPort();
}

/// Reports location services as disabled, so every lookup fails cleanly and
/// callers fall back to the stored location or `LOCATION_UNKNOWN`.
class NullLocationPort implements LocationPort {
  const NullLocationPort();

  @override
  Future<bool> isLocationServiceEnabled() async => false;

  @override
  Future<LocationPermissionStatus> checkPermission() async =>
      LocationPermissionStatus.denied;

  @override
  Future<LocationPermissionStatus> requestPermission() async =>
      LocationPermissionStatus.denied;

  @override
  Future<LocationFix> currentPosition() =>
      Future<LocationFix>.error(StateError('No location services'));
}
