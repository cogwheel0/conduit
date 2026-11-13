import 'dart:async';

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
  final List<String> changed = [];

  @override
  void handle(
    NativeSheetEvent event, {
    SettingsEventSource source = SettingsEventSource.nativeSheet,
  }) {
    switch (event) {
      case NativeSheetDetailAppeared(:final detailId):
        appeared.add(detailId);
      case NativeSheetControlChanged(:final id):
        changed.add(id);
      default:
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

/// A page as the column sees it, holding [pending] text.
final class _Member implements SettingsColumnMember {
  _Member(this.pageId, this.pending);

  @override
  final String pageId;
  final Map<String, String> pending;

  @override
  bool get holdsUnsavedChanges => pending.isNotEmpty;

  @override
  NativeSheetDiscardPrompt? get discardPrompt => null;

  @override
  SettingsPageDraft get draft =>
      (pending: pending, committed: const {}, edits: false);

  @override
  void commitPendingText() {}
}

/// Synthetic pages: a list whose row leads to a form that asks before
/// dropping what is typed into it, a form leading to that form, and a note
/// that asks nothing.
final _pages = [
  NativeSheetDetailConfig(
    id: 'test-note',
    title: 'Test Note',
    items: [
      NativeSheetItemConfig(
        id: 'test-note-text',
        title: 'Note',
        kind: NativeSheetItemKind.textField,
        value: '',
      ),
    ],
  ),
  NativeSheetDetailConfig(
    id: 'test-outer',
    title: 'Test Outer',
    confirmActionId: 'test-outer-save',
    discardPrompt: const NativeSheetDiscardPrompt(
      title: 'Lose the outer draft?',
      message: 'What you typed goes.',
      discardLabel: 'Lose It',
      keepLabel: 'Keep Outer',
    ),
    items: [
      NativeSheetItemConfig(
        id: 'test-outer-name',
        title: 'Outer Name',
        kind: NativeSheetItemKind.textField,
        value: '',
      ),
      NativeSheetItemConfig(id: 'test-form', title: 'Test Form'),
    ],
  ),
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
        // A page its own feature draws, as the calendar is.
        builder: (_, state) => state.pathParameters['id'] == 'test-feature'
            ? const SettingsFeaturePage(
                pageId: 'test-feature',
                child: Scaffold(body: Text('Feature page')),
              )
            : SettingsDetailPage(
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

  testWidgets('another root row asks every page it would close that holds '
      'unsaved changes, the highest first', (tester) async {
    await _pump(tester, _tablet);
    await _openBeside(tester, 'test-outer');
    await tester.enterText(find.byType(EditableText), 'Outer draft');
    await tester.tap(_row('test-form'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(EditableText), 'Inner draft');
    await tester.pump();

    await tester.ensureVisible(_row(NativeSheetRoutes.appearance));
    await tester.tap(_row(NativeSheetRoutes.appearance));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Throw Away'));
    await tester.pumpAndSettle();
    // The form under it is asked too, and keeps its draft.
    await tester.tap(find.text('Keep Outer'));
    await tester.pumpAndSettle();
    check(_column(tester)).deepEquals(['test-outer', 'test-form']);

    await tester.tap(_row(NativeSheetRoutes.appearance));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Throw Away'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Lose It'));
    await tester.pumpAndSettle();
    check(_column(tester)).deepEquals([NativeSheetRoutes.appearance]);
  });

  testWidgets("a root row's page chosen again asks only the pages above it", (
    tester,
  ) async {
    await _pump(tester, _tablet);
    await _openBeside(tester, 'test-outer');
    await tester.enterText(find.byType(EditableText), 'Outer draft');
    await tester.tap(_row('test-form'));
    await tester.pumpAndSettle();

    await _openBeside(tester, 'test-outer');

    check(find.text('Lose the outer draft?').evaluate()).isEmpty();
    check(_column(tester)).deepEquals(['test-outer']);
    check(find.text('Outer draft').evaluate()).isNotEmpty();
  });

  testWidgets('narrowing keeps the text typed into a page, not sent', (
    tester,
  ) async {
    final rig = await _pump(tester, _tablet);
    await _openBeside(tester, 'test-form');
    await tester.enterText(find.byType(EditableText), 'Draft');
    await tester.pump();

    tester.view.physicalSize = const Size(800, 1280);
    await tester.pumpAndSettle();

    check(rig.router.state.uri.toString()).equals('/profile/page/test-form');
    check(rig.controller.changed).isEmpty();
    check(find.text('Draft').evaluate()).isNotEmpty();
  });

  testWidgets('widening again shows the pages beside the list as they were', (
    tester,
  ) async {
    final rig = await _pump(tester, _tablet);
    await _openBeside(tester, 'test-list');
    await tester.tap(_row('test-form'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(EditableText), 'Draft');
    await tester.pump();
    tester.view.physicalSize = const Size(800, 1280);
    await tester.pumpAndSettle();

    tester.view.physicalSize = _tablet;
    await tester.pumpAndSettle();

    check(_column(tester)).deepEquals(['test-list', 'test-form']);
    // The routes the narrow window opened are gone, not left.
    check(rig.router.state.uri.toString()).equals('/');
    check(rig.controller.closed)
      ..not((closed) => closed.contains('test-list'))
      ..not((closed) => closed.contains('test-form'));
    check(rig.controller.changed).isEmpty();
    check(find.text('Draft').evaluate()).isNotEmpty();

    // Narrowed once more, the same pages open over the list, and no more.
    tester.view.physicalSize = const Size(800, 1280);
    await tester.pumpAndSettle();
    check(rig.router.state.uri.toString()).equals('/profile/page/test-form');
    rig.router.pop();
    await tester.pumpAndSettle();
    rig.router.pop();
    await tester.pumpAndSettle();
    check(rig.router.state.uri.toString()).equals('/');
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
    // Already showing, neither describes itself again, which would start
    // a form's draft over.
    check(rig.controller.appeared).isEmpty();

    // The page under it, covered as it moved, describes itself once shown.
    rig.router.pop();
    await tester.pumpAndSettle();
    check(rig.controller.appeared).deepEquals(['test-list']);
    check(rig.controller.closed).contains('test-form');
  });

  testWidgets('text done in a page moves with it, still unsaved', (
    tester,
  ) async {
    await _pump(tester, _tablet);
    await _openBeside(tester, 'test-form');
    await tester.enterText(find.byType(EditableText), 'Draft');
    await tester.pump();
    (tester.state(find.byType(SettingsPageView).last) as SettingsColumnMember)
        .commitPendingText();
    await tester.pump();

    tester.view.physicalSize = const Size(800, 1280);
    await tester.pumpAndSettle();

    check(find.text('Draft').evaluate()).isNotEmpty();
    final moved = tester.state(
      find.byType(SettingsPageView).last,
    ) as SettingsColumnMember;
    check(moved.holdsUnsavedChanges).isTrue();
  });

  testWidgets('another root row keeps the text typed into a page that asks '
      'nothing, as Back does', (tester) async {
    final rig = await _pump(tester, _tablet);
    await _openBeside(tester, 'test-note');
    await tester.enterText(find.byType(EditableText), 'Remember the map');
    await tester.pump();

    await tester.ensureVisible(_row(NativeSheetRoutes.appearance));
    await tester.tap(_row(NativeSheetRoutes.appearance));
    await tester.pumpAndSettle();

    check(rig.controller.changed).contains('test-note-text');
  });

  testWidgets('widening leaves a question asked over the pages, and moves '
      'them once it is answered', (tester) async {
    final rig = await _pump(tester, _tablet);
    await _openBeside(tester, 'test-form');
    tester.view.physicalSize = const Size(800, 1280);
    await tester.pumpAndSettle();
    final asking = showDialog<void>(
      context: tester.element(find.byType(SettingsDetailPage).last),
      builder: (_) => const Text('A question'),
    );
    await tester.pumpAndSettle();

    tester.view.physicalSize = _tablet;
    await tester.pumpAndSettle();
    check(find.text('A question').evaluate()).isNotEmpty();
    check(rig.router.state.uri.toString()).equals('/profile/page/test-form');

    Navigator.of(tester.element(find.text('A question'))).pop();
    await asking;
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();

    check(rig.router.state.uri.toString()).equals('/');
    check(_column(tester)).deepEquals(['test-form']);
  });

  testWidgets('narrowing waits for a sheet open beside the list, then moves '
      'the pages', (tester) async {
    final rig = await _pump(tester, _tablet);
    await _openBeside(tester, 'test-form');
    final asking = showDialog<void>(
      context: tester.element(find.byType(SettingsDetailPage).last),
      useRootNavigator: false,
      builder: (_) => const Text('An event being written'),
    );
    await tester.pumpAndSettle();

    tester.view.physicalSize = const Size(800, 1280);
    await tester.pumpAndSettle();
    // Still two columns: moving would close the sheet and what it holds.
    check(find.text('An event being written').evaluate()).isNotEmpty();
    check(_column(tester)).deepEquals(['test-form']);

    Navigator.of(tester.element(find.text('An event being written'))).pop();
    await asking;
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();

    check(find.byType(SettingsColumns).evaluate()).isEmpty();
    check(rig.router.state.uri.toString()).equals('/profile/page/test-form');
  });

  testWidgets('widening leaves a sheet open over a page its own feature '
      'draws, and moves it once closed', (tester) async {
    final rig = await _pump(tester, const Size(800, 1280));
    unawaited(
      rig.router.pushNamed(
        RouteNames.settingsPage,
        pathParameters: {'id': 'test-feature'},
      ),
    );
    await tester.pumpAndSettle();
    final asking = showDialog<void>(
      context: tester.element(find.text('Feature page')),
      builder: (_) => const Text('An event being written'),
    );
    await tester.pumpAndSettle();

    tester.view.physicalSize = _tablet;
    await tester.pumpAndSettle();
    check(find.text('An event being written').evaluate()).isNotEmpty();
    check(rig.router.state.uri.toString()).equals('/profile/page/test-feature');

    Navigator.of(tester.element(find.text('An event being written'))).pop();
    await asking;
    await tester.pump(const Duration(milliseconds: 300));
    // The page in the column is drawn by its feature, which this rig
    // leaves loading: no settling.
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    check(rig.router.state.uri.toString()).equals('/');
    check(_column(tester)).deepEquals(['test-feature']);
  });

  test('a draft kept by one move outlasts the next, before its page is '
      'drawn', () {
    final move = SettingsColumnMove();
    final page = _Member('test-form', {'test-name': 'Draft'});
    move
      ..register(page)
      ..carry(['test-form'])
      ..unregister(page);

    // Moved back before the page opened again.
    move.carry(['test-form']);

    check(move.take('test-form')?.pending)
        .isNotNull()
        .deepEquals({'test-name': 'Draft'});
  });
}
