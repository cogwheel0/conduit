import 'package:checks/checks.dart';
import 'package:conduit/platform/android_user_certificates.dart';
import 'package:conduit/platform/conduit_platform_apis.g.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class _MockUserCertificatesApi extends Mock
    implements UserCertificatesHostApi {}

const _syntheticPem = '''
-----BEGIN CERTIFICATE-----
c3ludGhldGlj
-----END CERTIFICATE-----
''';

void main() {
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  test('Android reports the certificates the user installed', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final api = _MockUserCertificatesApi();
    when(api.userCaCertificates).thenAnswer((_) async => [_syntheticPem]);

    check(await readAndroidUserCertificates(api: api))
        .deepEquals([_syntheticPem]);
  });

  test('a failed read reports none, so start-up goes on', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final api = _MockUserCertificatesApi();
    when(api.userCaCertificates)
        .thenThrow(PlatformException(code: 'channel-error'));

    check(await readAndroidUserCertificates(api: api)).isEmpty();
  });

  test('other platforms never ask', () async {
    for (final platform in [TargetPlatform.iOS, TargetPlatform.macOS]) {
      debugDefaultTargetPlatformOverride = platform;
      final api = _MockUserCertificatesApi();

      check(await readAndroidUserCertificates(api: api)).isEmpty();
      verifyNever(api.userCaCertificates);
    }
  });
}
