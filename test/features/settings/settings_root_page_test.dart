import 'package:checks/checks.dart';
import 'package:conduit/core/services/native_sheet_bridge.dart';
import 'package:conduit/features/settings/settings_controller.dart';
import 'package:conduit/features/settings/views/settings_root_page.dart';
import 'package:conduit/features/workspace/models/workspace_capabilities.dart';
import 'package:conduit/features/workspace/providers/workspace_capabilities_provider.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit_core/features/automations/providers/automation_providers.dart';
import 'package:conduit_core/features/calendar/providers/calendar_providers.dart';
import 'package:conduit_core/features/chat/providers/chat_providers.dart';
import 'package:conduit_core/features/direct_connections/providers/direct_connection_providers.dart';
import 'package:conduit_core/features/hermes/providers/hermes_providers.dart';
import 'package:conduit_core/features/integrations/providers/personal_connections_providers.dart';
import 'package:conduit_core/features/librechat/models/librechat_account.dart';
import 'package:conduit_core/features/librechat/providers/librechat_providers.dart';
import 'package:conduit_core/features/direct_connections/models/direct_connection_profile.dart';
import 'package:conduit/shared/theme/theme_providers.dart';
import 'package:conduit_core/services/settings_service.dart';
import 'package:conduit_core/models/user.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';

final class _ApiService extends Mock implements ApiService {}

final class _NoDirect extends DirectConnectionProfilesController {
  @override
  Future<List<DirectConnectionProfile>> build() async => const [];
}

final class _NoLibreChat extends LibreChatRegistryController {
  @override
  Future<LibreChatRegistry> build() async => const LibreChatRegistry();
}

/// Keeps what the root sends instead of acting on it.
final class _RecordingController extends SettingsController {
  final List<(String, Object?)> changes = [];

  @override
  void handle(
    NativeSheetEvent event, {
    SettingsEventSource source = SettingsEventSource.nativeSheet,
  }) {
    if (event case NativeSheetControlChanged(:final id, :final value)) {
      changes.add((id, value));
    }
  }
}

const _user = User(
  id: 'user-1',
  username: 'user',
  email: 'user@example.com',
  role: 'user',
);

Future<_RecordingController> _pumpRoot(
  WidgetTester tester, {
  required WorkspaceCapabilities capabilities,
}) async {
  final controller = _RecordingController();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        settingsControllerProvider.overrideWithValue(controller),
        reviewerModeProvider.overrideWithValue(false),
        isAuthLoadingProvider2.overrideWithValue(false),
        currentUserProvider2.overrideWithValue(_user),
        currentUserProvider.overrideWith((ref) async => _user),
        apiServiceProvider.overrideWithValue(_ApiService()),
        workspaceCapabilitiesProvider.overrideWith((ref) async => capabilities),
        appSettingsProvider.overrideWithValue(const AppSettings()),
        calendarAvailableProvider.overrideWithValue(false),
        personalConnectionsEntryVisibleProvider.overrideWithValue(false),
        scheduledTasksEntryVisibleProvider.overrideWithValue(false),
        chatDataControlsEntryVisibleProvider.overrideWithValue(false),
        openWebUiAccountsProvider.overrideWith((ref) async => const []),
        directConnectionProfilesProvider.overrideWith(_NoDirect.new),
        libreChatRegistryProvider.overrideWith(_NoLibreChat.new),
        hermesConnectionsProvider.overrideWithValue(const []),
        hermesEnabledProvider.overrideWithValue(false),
        appLocaleProvider.overrideWithValue(null),
      ],
      child: MaterialApp(
        localizationsDelegates: conduitLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const SettingsRootPage(),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return controller;
}

Finder _row(String id) => find.byKey(ValueKey<String>('settings-row-$id'));

void main() {
  testWidgets('the root offers Workspace to an account that may manage it, '
      'and the row opens it', (tester) async {
    final controller = await _pumpRoot(
      tester,
      capabilities: const WorkspaceCapabilities(
        models: WorkspaceSectionCapabilities.all,
      ),
    );

    await tester.scrollUntilVisible(_row(NativeSheetRoutes.workspace), 300);
    await tester.tap(_row(NativeSheetRoutes.workspace));
    await tester.pumpAndSettle();

    check(controller.changes).deepEquals([(NativeSheetRoutes.workspace, true)]);
  });

  testWidgets('the root leaves Workspace out without access to it', (
    tester,
  ) async {
    await _pumpRoot(tester, capabilities: const WorkspaceCapabilities());

    await tester.scrollUntilVisible(_row(NativeSheetRoutes.helpAbout), 300);

    check(_row(NativeSheetRoutes.workspace).evaluate()).isEmpty();
    // The rows around it are the native root's, in its order.
    check(_row(NativeSheetRoutes.appearance).evaluate()).isNotEmpty();
  });
}
