import 'package:checks/checks.dart';
import 'package:conduit/core/router/app_router.dart';
import 'package:conduit/core/services/navigation_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Hermes-only route policy', () {
    test('allows app-local profile and Hermes settings surfaces', () {
      for (final location in <String>[
        Routes.chat,
        Routes.profile,
        Routes.audioSettings,
        Routes.appCustomization,
        Routes.hermesSettings,
        Routes.hermesJobs,
        Routes.about,
      ]) {
        check(isHermesOnlyAppLocation(location)).isTrue();
      }
    });

    test('does not expose OpenWebUI-only surfaces', () {
      for (final location in <String>[
        Routes.accountSettings,
        Routes.personalization,
        Routes.notificationSettings,
        Routes.notes,
        Routes.channel,
      ]) {
        check(isHermesOnlyAppLocation(location)).isFalse();
      }
    });

    test('settled incomplete Hermes config opens settings, not splash', () {
      check(
        incompleteHermesDestination(secretsLoading: false),
      ).equals(Routes.hermesSettings);
      check(
        incompleteHermesDestination(secretsLoading: true),
      ).equals(Routes.splash);
    });
  });
}
