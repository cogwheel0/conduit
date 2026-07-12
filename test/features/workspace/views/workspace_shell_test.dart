import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:conduit/core/models/user.dart';
import 'package:conduit/core/providers/app_providers.dart';
import 'package:conduit/core/services/native_sheet_bridge.dart';
import 'package:conduit/core/services/navigation_service.dart';
import 'package:conduit/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit/features/profile/views/profile_page.dart';
import 'package:conduit/features/workspace/models/workspace_capabilities.dart';
import 'package:conduit/features/workspace/models/workspace_resources.dart';
import 'package:conduit/features/workspace/providers/workspace_capabilities_provider.dart';
import 'package:conduit/features/workspace/providers/workspace_providers.dart';
import 'package:conduit/features/workspace/views/workspace_page.dart';
import 'package:conduit/features/workspace/workspace_navigation.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/shared/widgets/adaptive_route_shell.dart';

void main() {
  testWidgets('compact shell shows app bar section menu and collection', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(_workspaceHarness());
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('workspace-section-tabs')), findsOneWidget);
    expect(find.byKey(const Key('workspace-section-rail')), findsNothing);
    expect(find.byKey(const Key('workspace-list-models')), findsOneWidget);
    // The permission-gated create affordance renders for a manageable section.
    expect(find.byKey(const Key('workspace-create-models')), findsOneWidget);
    expect(find.byKey(const Key('workspace-search-models')), findsOneWidget);

    await tester.tap(find.byKey(const Key('workspace-section-tabs')));
    await tester.pumpAndSettle();

    expect(find.text('Models'), findsWidgets);
    expect(find.text('Tools'), findsOneWidget);
  });

  testWidgets('compact shell switches sections through the app bar menu', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final router = GoRouter(
      initialLocation: WorkspaceSection.models.path,
      routes: [
        for (final section in [WorkspaceSection.models, WorkspaceSection.tools])
          GoRoute(
            path: section.path,
            builder: (_, _) => WorkspacePage(section: section),
          ),
      ],
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          reviewerModeProvider.overrideWithValue(false),
          workspaceCapabilitiesProvider.overrideWith(
            (ref) async => _capabilities,
          ),
          workspaceModelsProvider.overrideWith(_TestWorkspaceModels.new),
          workspaceToolsProvider.overrideWith(_TestWorkspaceTools.new),
        ],
        child: MaterialApp.router(
          routerConfig: router,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('workspace-list-models')), findsOneWidget);

    await tester.tap(find.byKey(const Key('workspace-section-tabs')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Tools'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('workspace-list-tools')), findsOneWidget);
    expect(find.byKey(const Key('workspace-list-models')), findsNothing);
  });

  testWidgets('section changes retain a back button that exits workspace', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final router = GoRouter(
      initialLocation: '/origin',
      routes: [
        GoRoute(
          path: '/origin',
          builder: (_, _) => const Scaffold(body: Text('origin')),
        ),
        for (final section in [WorkspaceSection.models, WorkspaceSection.tools])
          GoRoute(
            path: section.path,
            builder: (_, _) => WorkspacePage(section: section),
          ),
      ],
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          reviewerModeProvider.overrideWithValue(false),
          workspaceCapabilitiesProvider.overrideWith(
            (ref) async => _capabilities,
          ),
          workspaceModelsProvider.overrideWith(_TestWorkspaceModels.new),
          workspaceToolsProvider.overrideWith(_TestWorkspaceTools.new),
        ],
        child: MaterialApp.router(
          routerConfig: router,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
        ),
      ),
    );
    await tester.pumpAndSettle();

    router.push(WorkspaceSection.models.path);
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('workspace-exit')), findsOneWidget);

    await tester.tap(find.byKey(const Key('workspace-section-tabs')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Tools'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('workspace-list-tools')), findsOneWidget);
    expect(find.byKey(const Key('workspace-exit')), findsOneWidget);

    await tester.tap(find.byKey(const Key('workspace-exit')));
    await tester.pumpAndSettle();

    expect(find.text('origin'), findsOneWidget);
  });

  testWidgets('tablet shell keeps section rail, list, and detail placeholder', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1024, 768);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(_workspaceHarness());
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('workspace-section-rail')), findsOneWidget);
    expect(find.byKey(const Key('workspace-list-models')), findsOneWidget);
    expect(
      find.byKey(const Key('workspace-select-placeholder')),
      findsOneWidget,
    );
  });

  testWidgets('tablet detail errors do not nest a route shell', (tester) async {
    tester.view.physicalSize = const Size(1024, 768);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      _workspaceHarness(
        mode: WorkspaceRouteMode.detail,
        resourceId: 'missing-model',
        detailError: StateError('missing'),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(AdaptiveRouteShell), findsOneWidget);
    expect(find.byIcon(Icons.error_outline), findsOneWidget);
    expect(find.text('Workspace · Models'), findsOneWidget);
  });

  testWidgets('gate never builds protected content for a denied section', (
    tester,
  ) async {
    await tester.pumpWidget(
      _workspaceHarness(capabilities: const WorkspaceCapabilities()),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('workspace-denied')), findsOneWidget);
    expect(find.byKey(const Key('workspace-list-models')), findsNothing);
  });

  testWidgets('ProfilePage exposes a permission-gated workspace entry', (
    tester,
  ) async {
    final originalErrorWidgetBuilder = ErrorWidget.builder;
    final router = GoRouter(
      initialLocation: '/profile',
      routes: [
        GoRoute(path: '/profile', builder: (_, _) => const ProfilePage()),
        GoRoute(
          path: Routes.workspace,
          name: RouteNames.workspace,
          builder: (_, _) => const Scaffold(body: Text('workspace target')),
        ),
      ],
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          reviewerModeProvider.overrideWithValue(false),
          isAuthLoadingProvider2.overrideWithValue(false),
          currentUserProvider2.overrideWithValue(_user),
          currentUserProvider.overrideWith((ref) async => _user),
          apiServiceProvider.overrideWithValue(null),
          workspaceCapabilitiesProvider.overrideWith(
            (ref) async => _capabilities,
          ),
        ],
        child: MaterialApp.router(
          routerConfig: router,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(NativeSheetRoutes.workspace, 'workspace-entry');
    expect(find.byKey(const Key('settings-category-account')), findsOneWidget);
    expect(find.byKey(const Key('settings-category-app')), findsOneWidget);

    await tester.scrollUntilVisible(
      find.byKey(const Key('settings-category-ai')),
      300,
    );
    expect(find.byKey(const Key('settings-category-ai')), findsOneWidget);

    await tester.scrollUntilVisible(
      find.byKey(const Key('settings-category-server')),
      300,
    );
    expect(find.byKey(const Key('settings-category-server')), findsOneWidget);
    expect(find.byKey(const Key('workspace-entry')), findsOneWidget);
    expect(find.byKey(const Key('data-connection-entry')), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const Key('settings-category-server')),
        matching: find.byKey(const Key('workspace-entry')),
      ),
      findsOneWidget,
    );

    await tester.scrollUntilVisible(
      find.byKey(const Key('settings-category-support')),
      300,
    );
    expect(find.byKey(const Key('settings-category-support')), findsOneWidget);

    await tester.scrollUntilVisible(
      find.byKey(const Key('workspace-entry')),
      -300,
    );
    await tester.tap(find.byKey(const Key('workspace-entry')));
    await tester.pumpAndSettle();
    expect(find.text('workspace target'), findsOneWidget);
    ErrorWidget.builder = originalErrorWidgetBuilder;
  });

  testWidgets('ProfilePage keeps Server category without workspace access', (
    tester,
  ) async {
    final originalErrorWidgetBuilder = ErrorWidget.builder;
    final router = GoRouter(
      initialLocation: '/profile',
      routes: [
        GoRoute(path: '/profile', builder: (_, _) => const ProfilePage()),
      ],
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          reviewerModeProvider.overrideWithValue(false),
          isAuthLoadingProvider2.overrideWithValue(false),
          currentUserProvider2.overrideWithValue(_user),
          currentUserProvider.overrideWith((ref) async => _user),
          apiServiceProvider.overrideWithValue(null),
          workspaceCapabilitiesProvider.overrideWith(
            (ref) async => const WorkspaceCapabilities(),
          ),
        ],
        child: MaterialApp.router(
          routerConfig: router,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(
      find.byKey(const Key('settings-category-server')),
      300,
    );

    expect(find.byKey(const Key('settings-category-server')), findsOneWidget);
    expect(find.byKey(const Key('workspace-entry')), findsNothing);
    expect(
      find.descendant(
        of: find.byKey(const Key('settings-category-server')),
        matching: find.byKey(const Key('data-connection-entry')),
      ),
      findsOneWidget,
    );
    ErrorWidget.builder = originalErrorWidgetBuilder;
  });
}

Widget _workspaceHarness({
  WorkspaceCapabilities capabilities = _capabilities,
  WorkspaceRouteMode mode = WorkspaceRouteMode.collection,
  String? resourceId,
  Object? detailError,
}) {
  return ProviderScope(
    overrides: [
      reviewerModeProvider.overrideWithValue(false),
      workspaceCapabilitiesProvider.overrideWith((ref) async => capabilities),
      workspaceModelsProvider.overrideWith(_TestWorkspaceModels.new),
      if (detailError != null && resourceId != null)
        workspaceModelDetailProvider(resourceId).overrideWith(
          (ref) => Future<WorkspaceModelDetail>.error(detailError),
        ),
    ],
    child: MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: WorkspacePage(
        section: WorkspaceSection.models,
        mode: mode,
        resourceId: resourceId,
      ),
    ),
  );
}

const _capabilities = WorkspaceCapabilities(
  models: WorkspaceSectionCapabilities.all,
  tools: WorkspaceSectionCapabilities.all,
);

const _user = User(
  id: 'user-1',
  username: 'user',
  email: 'user@example.com',
  role: 'user',
);

class _TestWorkspaceModels extends WorkspaceModels {
  @override
  Future<WorkspaceCollectionState<WorkspaceModelSummary>> build() async {
    return const WorkspaceCollectionState(
      items: [
        WorkspaceModelSummary(id: 'model-1', name: 'Model 1', userId: 'user-1'),
      ],
      total: 1,
    );
  }

  @override
  Future<void> refresh() async {}

  @override
  Future<void> loadMore() async {}

  @override
  Future<void> setQuery(String query) async {}
}

class _TestWorkspaceTools extends WorkspaceTools {
  @override
  Future<WorkspaceCollectionState<WorkspaceToolSummary>> build() async {
    return const WorkspaceCollectionState(
      items: [
        WorkspaceToolSummary(id: 'tool-1', name: 'Tool 1', userId: 'user-1'),
      ],
      total: 1,
    );
  }

  @override
  Future<void> refresh() async {}

  @override
  Future<void> loadMore() async {}

  @override
  Future<void> setQuery(String query) async {}
}
