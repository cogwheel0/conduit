import 'package:checks/checks.dart';
import 'package:conduit/core/router/app_router.dart';
import 'package:conduit/core/services/navigation_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('direct-primary route policy', () {
    test('allows chat and app-local settings without Open WebUI', () {
      for (final location in <String>[
        Routes.chat,
        Routes.profile,
        Routes.audioSettings,
        Routes.appearanceSettings,
        Routes.chatSettings,
        Routes.dataConnectionSettings,
        Routes.directConnections,
        Routes.directConnectionEditorPath('profile_1'),
        Routes.hermesSettings,
        Routes.hermesJobs,
        Routes.about,
      ]) {
        check(isDirectOnlyAppLocation(location)).isTrue();
      }
    });

    test('does not expose Open WebUI-only surfaces', () {
      for (final location in <String>[
        Routes.accountSettings,
        Routes.personalization,
        Routes.notificationSettings,
        Routes.notes,
        Routes.channel,
      ]) {
        check(isDirectOnlyAppLocation(location)).isFalse();
      }
    });

    test('recognizes list and editor paths as direct connection routes', () {
      check(isDirectConnectionsLocation(Routes.directConnections)).isTrue();
      check(
        isDirectConnectionsLocation(
          Routes.directConnectionEditorPath('profile with spaces'),
        ),
      ).isTrue();
      check(isDirectConnectionsLocation(Routes.profile)).isFalse();
    });

    test('editor path percent-encodes profile ids', () {
      check(
        Routes.directConnectionEditorPath('local profile'),
      ).equals('/profile/direct-connections/local%20profile');
    });
  });
}
