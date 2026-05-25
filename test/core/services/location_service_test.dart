import 'dart:async';

import 'package:checks/checks.dart';
import 'package:conduit/core/services/api_service.dart';
import 'package:conduit/core/services/location_service.dart';
import 'package:geolocator/geolocator.dart';
import 'package:flutter_test/flutter_test.dart';

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
  Future<LocationPermission> checkLocationPermission() async {
    return LocationPermission.whileInUse;
  }

  @override
  Future<Position> fetchCurrentPosition() {
    return Completer<Position>().future;
  }
}

void main() {
  group('formatUserLocationCoordinatesForTest', () {
    test('matches OpenWebUI coordinate formatting', () {
      final formatted = formatUserLocationCoordinatesForTest(
        latitude: 12.34567,
        longitude: 67.89012,
      );

      check(formatted).equals('12.346, 67.890 (lat, long)');
    });
  });

  group('extractUserLocationSettingForTest', () {
    test('treats boolean toggle as auto refresh', () {
      final setting = extractUserLocationSettingForTest({
        'ui': {'userLocation': true},
      });

      check(setting.autoRefreshEnabled).isTrue();
      check(setting.legacyLocation).isNull();
    });

    test('treats string toggle as auto refresh', () {
      final setting = extractUserLocationSettingForTest({
        'ui': {'userLocation': 'true'},
      });

      check(setting.autoRefreshEnabled).isTrue();
      check(setting.legacyLocation).isNull();
    });

    test('preserves legacy stored location strings', () {
      final setting = extractUserLocationSettingForTest({
        'ui': {'userLocation': '48.857, 2.352 (lat, long)'},
      });

      check(setting.autoRefreshEnabled).isFalse();
      check(setting.legacyLocation).equals('48.857, 2.352 (lat, long)');
    });
  });

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
