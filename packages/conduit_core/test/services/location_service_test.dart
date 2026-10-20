import 'dart:async';

import 'package:checks/checks.dart';
import 'package:conduit_core/ports/location_port.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/location_service.dart';
import 'package:test/test.dart';

class _FakeLocationService extends LocationService {
  _FakeLocationService(this._result);

  final UserLocationResult _result;

  @override
  Future<UserLocationResult> refreshAndSyncUserLocation(ApiService? api) async {
    return _result;
  }
}

class _HangingLocationService extends LocationService {
  const _HangingLocationService();

  @override
  Duration get locationLookupTimeout => const Duration(milliseconds: 10);

  @override
  Future<bool> isLocationServiceEnabled() async => true;

  @override
  Future<LocationPermissionStatus> checkLocationPermission() async {
    return LocationPermissionStatus.whileInUse;
  }

  @override
  Future<LocationFix> fetchCurrentPosition() {
    return Completer<LocationFix>().future;
  }
}

void main() {
  group('resolveLocationForUserSettings', () {
    test('uses fresh location when auto refresh is enabled', () async {
      final service = _FakeLocationService(
        const UserLocationResult.success('12.346, 67.890 (lat, long)'),
      );

      final location = await service.resolveLocationForUserSettings({
        'ui': {'userLocation': true},
      });

      check(location).equals('12.346, 67.890 (lat, long)');
    });

    test('falls back to legacy location strings', () async {
      const service = LocationService();

      final location = await service.resolveLocationForUserSettings({
        'ui': {'userLocation': '40.713, -74.006 (lat, long)'},
      });

      check(location).equals('40.713, -74.006 (lat, long)');
    });

    test('root false overrides legacy ui coordinate', () async {
      const service = LocationService();

      final location = await service.resolveLocationForUserSettings({
        'userLocation': false,
        'ui': {'userLocation': '40.713, -74.006 (lat, long)'},
      });

      check(location).isNull();
    });

    test('returns null when location is disabled', () async {
      const service = LocationService();

      final location = await service.resolveLocationForUserSettings({
        'ui': {'userLocation': false},
      });

      check(location).isNull();
    });
  });

  group('resolveCurrentLocation', () {
    test('times out stalled location lookups', () async {
      const service = _HangingLocationService();

      final result = await service.resolveCurrentLocation();

      check(result.hasLocation).isFalse();
      check(result.failureReason).equals(UserLocationFailureReason.unavailable);
    });
  });
}
