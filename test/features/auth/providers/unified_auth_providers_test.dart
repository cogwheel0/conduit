import 'package:checks/checks.dart';
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
  });
}
