import 'dart:async';

import 'package:checks/checks.dart';
import 'package:conduit/features/workspace/models/workspace_capabilities.dart';
import 'package:conduit/features/workspace/providers/workspace_capabilities_provider.dart';
import 'package:conduit/features/workspace/providers/workspace_model_relationships.dart';
import 'package:conduit/features/workspace/views/models/workspace_model_editor.dart';
import 'package:conduit/features/workspace/workspace_navigation.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit_core/features/workspace/models/workspace_common.dart';
import 'package:conduit_core/features/workspace/models/workspace_resources.dart';
import 'package:conduit_core/models/model.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/models/user.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/worker_manager.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  final view = binding.platformDispatcher.views.first;

  setUp(() {
    view.physicalSize = const Size(1200, 2400);
    view.devicePixelRatio = 1;
  });

  tearDown(() {
    view.resetPhysicalSize();
    view.resetDevicePixelRatio();
  });

  testWidgets('the detail page shows the values a save from the editor wrote', (
    tester,
  ) async {
    final api = _ModelApi();
    final router = GoRouter(
      initialLocation: '/detail',
      routes: [
        GoRoute(
          path: '/detail',
          builder: (_, _) => const Scaffold(
            body: WorkspaceModelEditorView(
              mode: WorkspaceRouteMode.detail,
              modelId: 'model-1',
            ),
          ),
        ),
        GoRoute(
          path: '/edit',
          builder: (_, _) => const Scaffold(
            body: WorkspaceModelEditorView(
              mode: WorkspaceRouteMode.edit,
              modelId: 'model-1',
            ),
          ),
        ),
      ],
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          reviewerModeProvider.overrideWithValue(false),
          apiServiceProvider.overrideWithValue(api),
          activeServerProvider.overrideWith(
            (ref) => const ServerConfig(
              id: 'workspace-server',
              name: 'Workspace Server',
              url: 'https://example.com',
            ),
          ),
          currentUserProvider2.overrideWithValue(
            const User(
              id: 'user-1',
              username: 'admin',
              email: 'admin@example.com',
              role: 'admin',
            ),
          ),
          authTokenProvider3.overrideWithValue('token-1'),
          workspaceCapabilitiesProvider.overrideWith(
            (ref) async => WorkspaceCapabilities.all,
          ),
          modelsProvider.overrideWith(_FakeModels.new),
          workspaceBaseModelsProvider.overrideWith((ref) async => const []),
        ],
        child: MaterialApp.router(
          routerConfig: router,
          localizationsDelegates: conduitLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
        ),
      ),
    );
    await tester.pumpAndSettle();
    check(_nameShown(tester)).equals('Model 1');

    unawaited(router.push('/edit'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('workspace-model-name')),
      'Renamed model',
    );
    await tester.tap(find.byKey(const Key('workspace-editor-save')));
    await tester.pumpAndSettle();

    check(api.updated).length.equals(1);
    // The editor popped; the detail page under it reloaded the saved record.
    check(find.byKey(const Key('workspace-editor-save')).evaluate()).isEmpty();
    check(_nameShown(tester)).equals('Renamed model');
  });
}

String? _nameShown(WidgetTester tester) {
  final field = find.descendant(
    of: find.byKey(const Key('workspace-model-name')),
    matching: find.byType(EditableText),
  );
  return tester.widget<EditableText>(field).controller.text;
}

class _ModelApi extends ApiService {
  _ModelApi()
    : super(
        serverConfig: const ServerConfig(
          id: 'workspace-server',
          name: 'Workspace Server',
          url: 'https://example.com',
        ),
        workerManager: WorkerManager(),
      );

  WorkspaceModelSummary _model = const WorkspaceModelSummary(
    id: 'model-1',
    name: 'Model 1',
    userId: 'user-1',
    writeAccess: true,
  );
  final updated = <WorkspaceModelForm>[];

  @override
  Future<WorkspacePagedResponse<WorkspaceModelSummary>> getWorkspaceModels({
    String? query,
    String? viewOption,
    String? tag,
    String? orderBy,
    String? direction,
    int page = 1,
  }) async => WorkspacePagedResponse(items: [_model], total: 1);

  @override
  Future<WorkspaceModelDetail?> getWorkspaceModel(String id) async => _model;

  @override
  Future<WorkspaceModelDetail?> updateWorkspaceModel(
    WorkspaceModelForm form,
  ) async {
    updated.add(form);
    return _model = WorkspaceModelSummary(
      id: form.id,
      name: form.name,
      userId: 'user-1',
      writeAccess: true,
    );
  }
}

class _FakeModels extends Models {
  @override
  Future<List<Model>> build() async {
    return const [Model(id: 'gpt-4', name: 'GPT-4')];
  }
}
