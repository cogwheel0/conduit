import 'package:checks/checks.dart';
import 'package:conduit/core/services/native_sheet_bridge.dart';
import 'package:conduit/features/settings/settings_controller.dart';
import 'package:conduit/features/settings/settings_page_module.dart';
import 'package:conduit/features/settings/settings_pages.dart';
import 'package:conduit/features/settings/views/settings_columns.dart';
import 'package:conduit/features/settings/views/settings_page_view.dart';
import 'package:conduit/features/settings/views/settings_root_page.dart';
import 'package:conduit/features/workspace/models/workspace_capabilities.dart';
import 'package:conduit/features/workspace/providers/workspace_capabilities_provider.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit/shared/theme/theme_providers.dart';
import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit_core/features/automations/providers/automation_providers.dart';
import 'package:conduit_core/features/calendar/providers/calendar_providers.dart';
import 'package:conduit_core/features/chat/providers/chat_providers.dart';
import 'package:conduit_core/features/direct_connections/models/direct_connection_profile.dart';
import 'package:conduit_core/features/direct_connections/providers/direct_connection_providers.dart';
import 'package:conduit_core/features/hermes/providers/hermes_providers.dart';
import 'package:conduit_core/features/integrations/providers/personal_connections_providers.dart';
import 'package:conduit_core/features/librechat/models/librechat_account.dart';
import 'package:conduit_core/features/librechat/providers/librechat_providers.dart';
import 'package:conduit_core/models/user.dart';
import 'package:conduit_core/navigation/routes.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/settings_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
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

/// Keeps what the pages tell it instead of acting on it.
final class _RecordingController extends SettingsController {
  final List<String> closed = [];
  final List<String> appeared = [];

  @override
  void handle(
    NativeSheetEvent event, {
    SettingsEventSource source = SettingsEventSource.nativeSheet,
  }) {
    if (event case NativeSheetDetailAppeared(:final detailId)) {
      appeared.add(detailId);
    }
  }

  @override
  void pageClosed(String detailId, {List<SettingsPageModule>? modules}) {
    closed.add(detailId);
  }
}

const _user = User(
  id: 'user-1',
  username: 'user',
  email: 'user@example.com',
  role: 'user',
);

/// Two synthetic pages: a list whose row leads to a form that asks before
/// dropping what is typed into it.
final _pages = [
  NativeSheetDetailConfig(
    id: 'test-list',
    title: 'Test List',
    items: [NativeSheetItemConfig(id: 'test-form', title: 'Test Form')],
  ),
  NativeSheetDetailConfig(
    id: 'test-form',
    title: 'Test Form',
    confirmActionId: 'test-save',
    discardPrompt: const NativeSheetDiscardPrompt(
      title: 'Throw it away?',
      message: 'What you typed goes.',
      discardLabel: 'Throw Away',
      keepLabel: 'Keep It',
    ),
    items: [
      NativeSheetItemConfig(
        id: 'test-name',
        title: 'Name',
        kind: NativeSheetItemKind.textField,
        value: '',
      ),
    ],
  ),
];

/// The app's Settings with a window of [size] logical pixels.
Future<({_RecordingController controller, GoRouter router})> _pump(
  WidgetTester tester,
  Size size,
) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.reset);
  final controller = _RecordingController();
  final router = GoRouter(
    routes: [
      GoRoute(path: '/', builder: (_, _) => const SettingsRootPage()),
      GoRoute(
        path: Routes.settingsPage,
        name: RouteNames.settingsPage,
        builder: (_, state) => SettingsDetailPage(
          detailId: state.pathParameters['id']!,
          reopened: state.extra is SettingsPageReopened,
        ),
      ),
    ],
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        settingsControllerProvider.overrideWithValue(controller),
        reviewerModeProvider.overrideWithValue(false),
        isAuthLoadingProvider2.overrideWithValue(false),
        currentUserProvider2.overrideWithValue(_user),
        currentUserProvider.overrideWith((ref) async => _user),
        apiServiceProvider.overrideWithValue(_ApiService()),
        workspaceCapabilitiesProvider.overrideWith(
          (ref) async => const WorkspaceCapabilities(),
        ),
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
      child: MaterialApp.router(
        routerConfig: router,
        localizationsDelegates: conduitLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
      ),
    ),
  );
  await tester.pumpAndSettle();
  ProviderScope.containerOf(tester.element(find.byType(SettingsRootPage)))
      .read(settingsPagesProvider.notifier)
      .register(_pages);
  await tester.pumpAndSettle();
  return (controller: controller, router: router);
}

Finder _row(String id) => find.byKey(ValueKey<String>('settings-row-$id'));

/// The pages the column beside the root list shows, first to top.
List<String> _column(WidgetTester tester) => tester
    .state<SettingsColumnsState>(find.byType(SettingsColumns))
    .openPageIds;

Future<void> _openBeside(WidgetTester tester, String id) async {
  await tester
      .state<SettingsColumnsState>(find.byType(SettingsColumns))
      .openRootPage(id);
  await tester.pumpAndSettle();
}

const _tablet = Size(1280, 800);

void main() {
  testWidgets('a tablet window shows the root list beside its first page', (
    tester,
  ) async {
    final rig = await _pump(tester, _tablet);

    final columns = tester.state<SettingsColumnsState>(
      find.byType(SettingsColumns),
    );
    check(columns.selectedId).isNotNull();
    check(_column(tester)).deepEquals([columns.selectedId!]);
    check(find.byType(SettingsDetailPage).evaluate()).length.equals(1);
    // The root list stays, and the router opened nothing.
    check(_row(NativeSheetRoutes.appearance).evaluate()).isNotEmpty();
    check(rig.router.state.uri.toString()).equals('/');
  });

  testWidgets("another root row's page replaces the one beside the list", (
    tester,
  ) async {
    final rig = await _pump(tester, _tablet);

    await tester.ensureVisible(_row(NativeSheetRoutes.appearance));
    await tester.tap(_row(NativeSheetRoutes.appearance));
    await tester.pumpAndSettle();

    check(_column(tester)).deepEquals([NativeSheetRoutes.appearance]);
    check(
      tester
          .state<SettingsColumnsState>(find.byType(SettingsColumns))
          .selectedId,
    ).equals(NativeSheetRoutes.appearance);
    check(rig.router.state.uri.toString()).equals('/');
  });

  testWidgets('a page beside the list opens the next one in its column', (
    tester,
  ) async {
    final rig = await _pump(tester, _tablet);
    await _openBeside(tester, 'test-list');

    await tester.tap(_row('test-form'));
    await tester.pumpAndSettle();

    check(_column(tester)).deepEquals(['test-list', 'test-form']);
    check(_row(NativeSheetRoutes.appearance).evaluate()).isNotEmpty();
    check(rig.router.state.uri.toString()).equals('/');
  });

  testWidgets('another root row asks first when the page beside the list '
      'holds unsaved changes', (tester) async {
    final rig = await _pump(tester, _tablet);
    await _openBeside(tester, 'test-form');
    await tester.enterText(find.byType(EditableText), 'Draft');
    await tester.pump();

    await tester.ensureVisible(_row(NativeSheetRoutes.appearance));
    await tester.tap(_row(NativeSheetRoutes.appearance));
    await tester.pumpAndSettle();
    check(find.text('Throw it away?').evaluate()).isNotEmpty();
    await tester.tap(find.text('Keep It'));
    await tester.pumpAndSettle();
    check(_column(tester)).deepEquals(['test-form']);

    await tester.tap(_row(NativeSheetRoutes.appearance));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Throw Away'));
    await tester.pumpAndSettle();
    check(_column(tester)).deepEquals([NativeSheetRoutes.appearance]);
    // The form was closed for good.
    check(rig.controller.closed).contains('test-form');
  });

  testWidgets('a phone keeps one column, each page pushed over the root', (
    tester,
  ) async {
    final rig = await _pump(tester, const Size(400, 800));

    check(find.byType(SettingsColumns).evaluate()).isEmpty();
    await tester.scrollUntilVisible(_row(NativeSheetRoutes.appearance), 200);
    await tester.tap(_row(NativeSheetRoutes.appearance));
    await tester.pumpAndSettle();

    check(rig.router.state.uri.toString())
        .equals('/profile/page/${NativeSheetRoutes.appearance}');
    check(
      find
          .byWidgetPredicate(
            (widget) =>
                widget is SettingsDetailPage &&
                widget.detailId == NativeSheetRoutes.appearance,
          )
          .evaluate(),
    ).isNotEmpty();
  });

  testWidgets('a phone on its side keeps one column', (tester) async {
    await _pump(tester, const Size(900, 400));

    check(find.byType(SettingsColumns).evaluate()).isEmpty();
  });

  testWidgets('narrowing past two columns pushes the pages beside the list '
      'over it, keeping what they hold', (tester) async {
    final rig = await _pump(tester, _tablet);
    await _openBeside(tester, 'test-list');
    await tester.tap(_row('test-form'));
    await tester.pumpAndSettle();
    rig.controller.appeared.clear();

    tester.view.physicalSize = const Size(800, 1280);
    await tester.pumpAndSettle();

    check(find.byType(SettingsColumns).evaluate()).isEmpty();
    check(rig.router.state.uri.toString()).equals('/profile/page/test-form');
    // Moved, not left: neither page was closed.
    check(rig.controller.closed).not((closed) => closed.contains('test-list'));
    check(rig.controller.closed).not((closed) => closed.contains('test-form'));
    // The page on top describes itself again; the one under it waits until
    // it shows, so it can't put a loading page over the one above.
    check(rig.controller.appeared).deepEquals(['test-form']);

    rig.router.pop();
    await tester.pumpAndSettle();
    check(rig.controller.appeared).deepEquals(['test-form', 'test-list']);
  });
}
