import 'package:checks/checks.dart';
import 'package:conduit_core/features/hermes/models/hermes_capabilities.dart';
import 'package:conduit_core/features/hermes/models/hermes_session.dart';
import 'package:test/test.dart';

void main() {
  group('HermesCapabilities.apiOwnsSessions', () {
    test('is set only by an explicit run_unknown_resolution feature', () {
      check(
        HermesCapabilities.fromJson(const {
          'features': {'run_unknown_resolution': true, 'session_fork': true},
        }).apiOwnsSessions,
      ).isTrue();
      check(
        HermesCapabilities.fromJson(const {
          'features': {'session_fork': true},
          'endpoints': {
            'run_unknown_resolution': {
              'method': 'POST',
              'path': '/v1/runs/{run_id}/resolve-unknown',
            },
          },
        }).apiOwnsSessions,
      ).isFalse();
      check(HermesCapabilities.enabledByDefault.apiOwnsSessions).isFalse();
    });
  });

  group('isForeignHermesSessionSource', () {
    test('API-owned and unknown sources can be continued', () {
      for (final source in [null, '', '  ', 'api_server', 'bot_room']) {
        check(isForeignHermesSessionSource(source)).isFalse();
      }
    });

    test('sessions from other Hermes surfaces are foreign', () {
      for (final source in ['telegram', 'cli', 'desktop', 'cron', 'Mobile']) {
        check(isForeignHermesSessionSource(source)).isTrue();
      }
    });
  });
}
