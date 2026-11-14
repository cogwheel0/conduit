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

/// Counts every question the service puts to the device.
class _CountingPort implements LocationPort {
  int asked = 0;

  @override
  Future<bool> isLocationServiceEnabled() async {
    asked++;
    return true;
  }

  @override
  Future<LocationPermissionStatus> checkPermission() async {
    asked++;
    return LocationPermissionStatus.whileInUse;
  }

  @override
  Future<LocationPermissionStatus> requestPermission() async {
    asked++;
    return LocationPermissionStatus.whileInUse;
  }

  @override
  Future<LocationFix> currentPosition() async {
    asked++;
    return const LocationFix(latitude: 51.50142, longitude: -0.14189);
  }
}

const _fix = '51.501, -0.142 (lat, long)';
const _on = <String, dynamic>{
  'ui': <String, dynamic>{'userLocation': true},
};
const _off = <String, dynamic>{
  'ui': <String, dynamic>{'userLocation': false},
};
const _typed = <String, dynamic>{
  'ui': <String, dynamic>{'userLocation': 'Port Wren'},
};

void main() {
  group('LocationLookupPolicy', () {
    test('the phone asks for every request while the setting is on', () async {
      final port = _CountingPort();
      final service = LocationService(port: port);

      final location = await service.resolveLocationForRequest(
        _on,
        prompts: const <String?>['You are a helpful assistant.'],
      );

      check(location).equals(_fix);
      check(port.asked).isGreaterThan(0);
    });

    test('the Mac asks only for a request that names the variable', () async {
      final port = _CountingPort();
      final service = LocationService(
        port: port,
        policy: LocationLookupPolicy.whenNamedAndAllowed,
      );

      final unnamed = await service.resolveLocationForRequest(
        _on,
        prompts: const <String?>['You are a helpful assistant.', null],
      );
      check(unnamed).isNull();
      check(port.asked).equals(0);

      final named = await service.resolveLocationForRequest(
        _on,
        prompts: const <String?>[null, 'The user is near {{USER_LOCATION}}.'],
      );
      check(named).equals(_fix);
      check(port.asked).isGreaterThan(0);
    });

    test('the Mac never asks while the setting is off', () async {
      final port = _CountingPort();
      final service = LocationService(
        port: port,
        policy: LocationLookupPolicy.whenNamedAndAllowed,
      );

      final off = await service.resolveLocationForRequest(
        _off,
        prompts: const <String?>['Near {{USER_LOCATION}}.'],
      );
      check(off).isNull();

      // A place the user typed still fills the variable.
      final typed = await service.resolveLocationForRequest(
        _typed,
        prompts: const <String?>['Near {{USER_LOCATION}}.'],
      );
      check(typed).equals('Port Wren');
      check(port.asked).equals(0);
    });

    test('a template asks on the phone whatever the setting says', () async {
      final port = _CountingPort();
      final service = LocationService(port: port);

      check(await service.resolveLocationForPromptTemplate(_off)).equals(_fix);
      check(port.asked).isGreaterThan(0);
    });

    test('a template asks on the Mac only while the setting is on', () async {
      final port = _CountingPort();
      final service = LocationService(
        port: port,
        policy: LocationLookupPolicy.whenNamedAndAllowed,
      );

      check(await service.resolveLocationForPromptTemplate(_off))
          .equals(userLocationUnknown);
      check(await service.resolveLocationForPromptTemplate(_typed))
          .equals('Port Wren');
      check(port.asked).equals(0);

      check(await service.resolveLocationForPromptTemplate(_on)).equals(_fix);
      check(port.asked).isGreaterThan(0);
    });

    test('a template with no answer from the device says so', () async {
      const service = LocationService(
        port: NullLocationPort(),
        policy: LocationLookupPolicy.whenNamedAndAllowed,
      );

      check(await service.resolveLocationForPromptTemplate(_on))
          .equals(userLocationUnknown);
    });

    test('only the exact variable counts', () {
      check(namesUserLocation('At {{USER_LOCATION}}.')).isTrue();
      check(namesUserLocation('At {{ USER_LOCATION }}.')).isFalse();
      check(namesUserLocation('At {{user_location}}.')).isFalse();
      check(namesUserLocation(null)).isFalse();
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
