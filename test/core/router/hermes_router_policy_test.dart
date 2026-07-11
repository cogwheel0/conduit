import 'package:checks/checks.dart';
import 'package:conduit/core/router/app_router.dart';
import 'package:conduit/core/services/navigation_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('native-sheet destinations suppress the second page transition', () {
    check(
      usesNoTransitionForNativeSheet(const NativeSheetNavigationOrigin()),
    ).isTrue();
    check(usesNoTransitionForNativeSheet(null)).isFalse();
    check(usesNoTransitionForNativeSheet(true)).isFalse();
  });

  group('Hermes-only route policy', () {
    test('allows app-local profile and Hermes settings surfaces', () {
      for (final location in <String>[
        Routes.chat,
        Routes.profile,
        Routes.audioSettings,
        Routes.appearanceSettings,
        Routes.chatSettings,
        Routes.dataConnectionSettings,
        Routes.directConnections,
        Routes.directConnectionEditorPath('new'),
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

    test('incomplete Hermes waits while the active server is loading', () {
      check(
        incompleteHermesDestination(
          secretsLoading: false,
          activeServerLoading: true,
        ),
      ).equals(Routes.splash);
    });
  });
}
