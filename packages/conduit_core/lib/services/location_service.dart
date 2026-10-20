import 'package:conduit_core/utils/openwebui_request_variables.dart';

export 'package:conduit_core/utils/openwebui_request_variables.dart'
    show UserLocationSetting;

import 'dart:async';

import 'package:riverpod/riverpod.dart';
import 'package:meta/meta.dart';

import 'package:conduit_core/ports/location_port.dart';
import 'package:conduit_core/utils/debug_logger.dart';

import 'package:conduit_core/services/api_service.dart';

enum UserLocationFailureReason {
  servicesDisabled,
  permissionDenied,
  permissionDeniedForever,
  unavailable,
}

@immutable
class UserLocationResult {
  const UserLocationResult._({this.location, this.failureReason});

  const UserLocationResult.success(String location)
    : this._(location: location);

  const UserLocationResult.failure(UserLocationFailureReason failureReason)
    : this._(failureReason: failureReason);

  final String? location;
  final UserLocationFailureReason? failureReason;

  bool get hasLocation => location != null && location!.trim().isNotEmpty;
}

const Duration _defaultLocationLookupTimeout = Duration(seconds: 8);

class LocationService {
  /// Reads the device through [port], or through the host's
  /// [LocationPort.hostDefault] when none is given.
  const LocationService({LocationPort? port}) : _port = port;

  final LocationPort? _port;

  LocationPort get _location => _port ?? LocationPort.hostDefault;

  Duration get locationLookupTimeout => _defaultLocationLookupTimeout;

  Future<bool> isLocationServiceEnabled() {
    return _location.isLocationServiceEnabled();
  }

  Future<LocationPermissionStatus> checkLocationPermission() {
    return _location.checkPermission();
  }

  Future<LocationPermissionStatus> requestLocationPermission() {
    return _location.requestPermission();
  }

  Future<LocationFix> fetchCurrentPosition() {
    return _location.currentPosition();
  }

  Future<UserLocationResult> resolveCurrentLocation() async {
    try {
      final servicesEnabled = await isLocationServiceEnabled();
      if (!servicesEnabled) {
        DebugLogger.info('location-services-disabled', scope: 'location');
        return const UserLocationResult.failure(
          UserLocationFailureReason.servicesDisabled,
        );
      }

      var permission = await checkLocationPermission();
      if (permission == LocationPermissionStatus.denied) {
        permission = await requestLocationPermission();
      }

      if (permission == LocationPermissionStatus.deniedForever) {
        DebugLogger.warning(
          'location-permission-denied-forever',
          scope: 'location',
        );
        return const UserLocationResult.failure(
          UserLocationFailureReason.permissionDeniedForever,
        );
      }

      if (!_isGranted(permission)) {
        DebugLogger.info('location-permission-denied', scope: 'location');
        return const UserLocationResult.failure(
          UserLocationFailureReason.permissionDenied,
        );
      }

      final position = await fetchCurrentPosition().timeout(
        locationLookupTimeout,
      );
      final formatted = formatUserLocationCoordinates(
        latitude: position.latitude,
        longitude: position.longitude,
      );
      return UserLocationResult.success(formatted);
    } on TimeoutException {
      DebugLogger.warning(
        'location-resolution-timeout',
        scope: 'location',
        data: {'timeoutMs': locationLookupTimeout.inMilliseconds},
      );
      return const UserLocationResult.failure(
        UserLocationFailureReason.unavailable,
      );
    } catch (error, stackTrace) {
      DebugLogger.error(
        'location-resolution-failed',
        scope: 'location',
        error: error,
        stackTrace: stackTrace,
      );
      return const UserLocationResult.failure(
        UserLocationFailureReason.unavailable,
      );
    }
  }

  Future<UserLocationResult> refreshAndSyncUserLocation(ApiService? api) async {
    final result = await resolveCurrentLocation();
    if (!result.hasLocation || api == null) {
      return result;
    }

    try {
      await api.updateUserInfo({'location': result.location!.trim()});
    } catch (error, stackTrace) {
      DebugLogger.error(
        'location-sync-failed',
        scope: 'location',
        error: error,
        stackTrace: stackTrace,
      );
    }

    return result;
  }

  Future<String?> resolveLocationForUserSettings(
    Map<String, dynamic>? userSettings, {
    ApiService? api,
  }) async {
    final setting = extractUserLocationSetting(userSettings);
    if (setting.autoRefreshEnabled) {
      final result = await refreshAndSyncUserLocation(api);
      if (result.hasLocation) {
        return result.location!.trim();
      }
    }
    return setting.legacyLocation;
  }

  bool _isGranted(LocationPermissionStatus permission) {
    switch (permission) {
      case LocationPermissionStatus.always:
      case LocationPermissionStatus.whileInUse:
        return true;
      default:
        return false;
    }
  }
}

final locationServiceProvider = Provider<LocationService>((ref) {
  return const LocationService();
});
