import 'package:checks/checks.dart';
import 'package:conduit/core/utils/server_version_compat.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ServerVersionCompat.isSupported', () {
    test('the max supported version itself is supported', () {
      check(ServerVersionCompat.isSupported('0.10.1')).isTrue();
    });

    test('older versions are supported', () {
      for (final v in ['0.10.0', '0.9.9', '0.6.5', '0.1.0', '0.0.1']) {
        check(because: v, ServerVersionCompat.isSupported(v)).isTrue();
      }
    });

    test('newer patch / minor / major versions are unsupported', () {
      for (final v in ['0.10.2', '0.11.0', '0.20.0', '1.0.0', '2.5.3']) {
        check(because: v, ServerVersionCompat.isSupported(v)).isFalse();
      }
    });

    test('tolerates a leading v prefix', () {
      check(ServerVersionCompat.isSupported('v0.10.1')).isTrue();
      check(ServerVersionCompat.isSupported('v0.11.0')).isFalse();
    });

    test('strips pre-release / build metadata before comparing', () {
      // A pre-release of the max version is treated as the max version.
      check(ServerVersionCompat.isSupported('0.10.1-dev')).isTrue();
      check(ServerVersionCompat.isSupported('0.10.1+build.7')).isTrue();
      // Metadata on a newer core still gates.
      check(ServerVersionCompat.isSupported('0.11.0-rc1')).isFalse();
    });

    test('partial versions are padded with zeros', () {
      check(ServerVersionCompat.isSupported('0.10')).isTrue();
      check(ServerVersionCompat.isSupported('0')).isTrue();
      check(ServerVersionCompat.isSupported('1')).isFalse();
    });

    test('fails open on null / empty / unparseable versions', () {
      for (final v in [null, '', '   ', 'nightly', 'unknown', 'abc.def']) {
        check(because: '$v', ServerVersionCompat.isSupported(v)).isTrue();
      }
    });

    test('isUnsupported is the inverse of isSupported', () {
      check(ServerVersionCompat.isUnsupported('0.11.0')).isTrue();
      check(ServerVersionCompat.isUnsupported('0.10.1')).isFalse();
      check(ServerVersionCompat.isUnsupported(null)).isFalse();
    });

    test('maxSupportedVersion constant parses as supported', () {
      check(
        ServerVersionCompat.isSupported(ServerVersionCompat.maxSupportedVersion),
      ).isTrue();
    });
  });
}
