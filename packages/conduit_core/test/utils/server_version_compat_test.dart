import 'package:checks/checks.dart';
import 'package:conduit_core/utils/server_version_compat.dart';
import 'package:test/test.dart';

void main() {
  group('ServerVersionCompat.isAtLeast', () {
    test('compares against the minimum', () {
      check(ServerVersionCompat.isAtLeast('0.11.0', '0.11.0')).isTrue();
      check(ServerVersionCompat.isAtLeast('v0.12.3', '0.11.0')).isTrue();
      check(ServerVersionCompat.isAtLeast('0.10.9', '0.11.0')).isFalse();
    });

    test('fails open on an unknown version', () {
      check(ServerVersionCompat.isAtLeast(null, '0.11.0')).isTrue();
      check(ServerVersionCompat.isAtLeast('', '0.11.0')).isTrue();
      check(ServerVersionCompat.isAtLeast('main', '0.11.0')).isTrue();
    });
  });

  group('ServerVersionCompat.knownAtLeast', () {
    test('answers only for a version it can read', () {
      const pages = ServerVersionCompat.notePagesVersion;
      check(ServerVersionCompat.knownAtLeast('0.12.5', pages)).equals(true);
      check(ServerVersionCompat.knownAtLeast('v0.13.0', pages)).equals(true);
      check(ServerVersionCompat.knownAtLeast('0.12.4', pages)).equals(false);
      check(ServerVersionCompat.knownAtLeast(null, pages)).isNull();
      check(ServerVersionCompat.knownAtLeast('main', pages)).isNull();
    });

    test('a temporary chat needs its session from 0.13.0', () {
      const session = ServerVersionCompat.temporaryChatSessionVersion;
      check(ServerVersionCompat.knownAtLeast('0.13.0', session)).equals(true);
      check(ServerVersionCompat.knownAtLeast('0.12.5', session)).equals(false);
      check(ServerVersionCompat.knownAtLeast(null, session)).isNull();
    });
  });

  group('ServerVersionCompat.isSupported', () {
    test('the max supported version itself is supported', () {
      check(ServerVersionCompat.isSupported('0.13.3')).isTrue();
    });

    test('older versions are supported', () {
      for (final v in [
        '0.13.2',
        '0.13.1',
        '0.13.0',
        '0.12.5',
        '0.12.4',
        '0.12.3',
        '0.12.2',
        '0.12.1',
        '0.12.0',
        '0.11.4',
        '0.11.3',
        '0.10.2',
        '0.10.1',
        '0.10.0',
        '0.9.9',
        '0.6.5',
        '0.1.0',
        '0.0.1',
      ]) {
        check(because: v, ServerVersionCompat.isSupported(v)).isTrue();
      }
    });

    test('newer patch / minor / major versions are unsupported', () {
      for (final v in ['0.13.4', '0.14.0', '0.20.0', '1.0.0', '2.5.3']) {
        check(because: v, ServerVersionCompat.isSupported(v)).isFalse();
      }
    });

    test('tolerates a leading v prefix', () {
      check(ServerVersionCompat.isSupported('v0.13.3')).isTrue();
      check(ServerVersionCompat.isSupported('v0.13.4')).isFalse();
    });

    test('strips pre-release / build metadata before comparing', () {
      // A pre-release of the max version is treated as the max version.
      check(ServerVersionCompat.isSupported('0.13.3-dev')).isTrue();
      check(ServerVersionCompat.isSupported('0.13.3+build.7')).isTrue();
      // Metadata on a newer core still gates.
      check(ServerVersionCompat.isSupported('0.13.4-rc1')).isFalse();
    });

    test('partial versions are padded with zeros', () {
      check(ServerVersionCompat.isSupported('0.12')).isTrue();
      check(ServerVersionCompat.isSupported('0')).isTrue();
      check(ServerVersionCompat.isSupported('1')).isFalse();
    });

    test('fails open on null / empty / unparseable versions', () {
      for (final v in [null, '', '   ', 'nightly', 'unknown', 'abc.def']) {
        check(because: '$v', ServerVersionCompat.isSupported(v)).isTrue();
      }
    });

    test('isUnsupported is the inverse of isSupported', () {
      check(ServerVersionCompat.isUnsupported('0.13.4')).isTrue();
      check(ServerVersionCompat.isUnsupported('0.13.3')).isFalse();
      check(ServerVersionCompat.isUnsupported(null)).isFalse();
    });

    test('maxSupportedVersion constant parses as supported', () {
      check(
        ServerVersionCompat.isSupported(
          ServerVersionCompat.maxSupportedVersion,
        ),
      ).isTrue();
    });
  });
}
