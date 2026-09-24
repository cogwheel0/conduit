import 'package:conduit_core/utils/openwebui_request_variables.dart';

export 'package:conduit_core/utils/openwebui_request_variables.dart'
    show UserLocationSetting;

import 'dart:async';

import 'package:riverpod/riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:meta/meta.dart';

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

@visibleForTesting
String formatUserLocationCoordinatesForTest({
  required double latitude,
  required double longitude,
}) {
  return formatUserLocationCoordinates(
    latitude: latitude,
    longitude: longitude,
  );
}

@visibleForTesting
UserLocationSetting extractUserLocationSettingForTest(
  Map<String, dynamic>? userSettings,
) {
  return extractUserLocationSetting(userSettings);
}

const Duration _defaultLocationLookupTimeout = Duration(seconds: 8);

class LocationService {
  const LocationService();

  Duration get locationLookupTimeout => _defaultLocationLookupTimeout;

  Future<bool> isLocationServiceEnabled() {
    return Geolocator.isLocationServiceEnabled();
  }

  Future<LocationPermission> checkLocationPermission() {
    return Geolocator.checkPermission();
  }

  Future<LocationPermission> requestLocationPermission() {
    return Geolocator.requestPermission();
  }

  Future<Position> fetchCurrentPosition() {
    return Geolocator.getCurrentPosition(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.medium,
      ),
    );
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
      if (permission == LocationPermission.denied) {
        permission = await requestLocationPermission();
      }

      if (permission == LocationPermission.deniedForever) {
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

  bool _isGranted(LocationPermission permission) {
    switch (permission) {
      case LocationPermission.always:
      case LocationPermission.whileInUse:
        return true;
      default:
        return false;
    }
  }
}

final locationServiceProvider = Provider<LocationService>((ref) {
  return const LocationService();
});
