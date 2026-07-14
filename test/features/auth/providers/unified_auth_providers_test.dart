import 'package:checks/checks.dart';
import 'package:conduit/core/providers/backend_mode_providers.dart';
import 'package:conduit/features/auth/providers/unified_auth_providers.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('completeOpenWebUiAuthentication', () {
    test('persists the preference after confirmed success', () async {
      final events = <String>[];

      final result = await completeOpenWebUiAuthentication(
        authenticate: () async {
          events.add('authenticated');
          return true;
        },
        persistPreference: () async {
          events.add('preference-persisted');
        },
      );
      events.add('returned');

      check(result).isTrue();
      check(
        events,
      ).deepEquals(['authenticated', 'preference-persisted', 'returned']);
    });

    test('does not persist the preference after a rejected attempt', () async {
      var persistCalls = 0;

      final result = await completeOpenWebUiAuthentication(
        authenticate: () async => false,
        persistPreference: () async => persistCalls++,
      );

      check(result).isFalse();
      check(persistCalls).equals(0);
    });

    test(
      'preference failure does not turn auth success into failure',
      () async {
        final result = await completeOpenWebUiAuthentication(
          authenticate: () async => true,
          persistPreference: () async => throw StateError('disk full'),
        );

        check(result).isTrue();
      },
    );

    test(
      'does not persist the preference when authentication throws',
      () async {
        var persistCalls = 0;

        await expectLater(
          completeOpenWebUiAuthentication(
            authenticate: () async => throw StateError('network failed'),
            persistPreference: () async => persistCalls++,
          ),
          throwsStateError,
        );

        check(persistCalls).equals(0);
      },
    );

    test(
      'successful optional OpenWebUI auth preserves direct primary',
      () async {
        var preferred = PreferredBackend.direct;
        var persistCalls = 0;

        final result = await completeOpenWebUiAuthentication(
          authenticate: () async => true,
          persistPreference: () => persistOpenWebUiBackendPreference(
            current: preferred,
            persist: (backend) async {
              persistCalls++;
              preferred = backend;
            },
          ),
        );

        check(result).isTrue();
        check(preferred).equals(PreferredBackend.direct);
        check(persistCalls).equals(0);
      },
    );

    test(
      'successful OpenWebUI auth selects owui for other primaries',
      () async {
        var preferred = PreferredBackend.hermes;

        await persistOpenWebUiBackendPreference(
          current: preferred,
          persist: (backend) async => preferred = backend,
        );

        check(preferred).equals(PreferredBackend.owui);
      },
    );
  });
}
