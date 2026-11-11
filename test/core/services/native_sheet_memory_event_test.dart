import 'dart:async';

import 'package:conduit/core/providers/app_startup_providers.dart';
import 'package:conduit/core/router/app_router.dart';
import 'package:conduit/core/services/native_sheet_bridge.dart';
import 'package:conduit/main.dart';
import 'package:conduit/platform/conduit_platform_apis.g.dart';
import 'package:conduit/platform/flutter_key_value_store.dart';
import 'package:conduit/platform/quick_actions_service.dart';
import 'package:conduit/shared/services/navigation_service.dart';
import 'package:conduit_core/auth/api_auth_interceptor.dart';
import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit_core/features/chat/providers/chat_providers.dart'
    show chatWakelockCoordinatorProvider;
import 'package:conduit_core/models/model.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/models/server_memory.dart';
import 'package:conduit_core/models/server_user_settings.dart';
import 'package:conduit_core/models/user.dart';
import 'package:conduit_core/persistence/persistence_keys.dart';
import 'package:conduit_core/persistence/preferences_store.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/providers/openwebui_route_resolver.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/optimized_storage_service.dart';
import 'package:conduit_core/services/worker_manager.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart' show Scaffold;
import 'package:conduit/core/utils/native_sheet_utils.dart';
import 'package:conduit/features/settings/settings_pages.dart';
import 'package:conduit/l10n/app_localizations_en.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _server = ServerConfig(
  id: 'test-server',
  name: 'Test Server',
  url: 'https://example.com',
  isActive: true,
);

class _MockOptimizedStorageService extends Mock
    implements OptimizedStorageService {}

class _NoModels extends Models {
  @override
  Future<List<Model>> build() async => const <Model>[];
}

class _MemoryOn extends PersonalizationSettings {
  @override
  Future<ServerUserSettings> build() async =>
      const ServerUserSettings(memoryEnabled: true);
}

class _IdleStartup extends AppStartupFlow {
  @override
  FutureOr<void> build() {}

  @override
  void start() {}
}

class _IdleQuickActions extends QuickActionsCoordinator {
  @override
  FutureOr<void> build() {}
}

/// Checks no server addresses: the mocked storage keeps no servers, and a
/// check failing to read them would wait to run again past the test.
class _IdleRoutes extends OpenWebUiRouteResolver {
  @override
  OpenWebUiRouteStatus build() => const OpenWebUiRouteStatus();
}

final _applyDetailPatchChannel = BasicMessageChannel<Object?>(
  'dev.flutter.pigeon.conduit.NativeSheetHostApi.applyDetailPatch',
  NativeSheetHostApi.pigeonChannelCodec,
);

ServerMemory _memory({String? type, String? path}) => ServerMemory(
  id: 'm1',
  userId: 'user-1',
  content: 'Prefers metric units',
  updatedAtEpoch: 10,
  createdAtEpoch: 1,
  type: type,
  path: path,
);

typedef _Write = ({String content, String? type, String? path});

/// An [ApiService] that serves one memory and records what reached the server.
final class _MemoriesApi extends ApiService {
  _MemoriesApi() : super(serverConfig: _server, workerManager: WorkerManager());

  Map<String, dynamic> permissions = const {};
  final adds = <_Write>[];
  final updates = <_Write>[];
  final deleted = <String>[];

  @override
  Future<Map<String, dynamic>> getUserPermissions({
    ApiAuthSnapshot? authSnapshot,
  }) async => permissions;

  @override
  Future<List<ServerMemory>> getMemories({
    ApiAuthSnapshot? authSnapshot,
  }) async => [_memory(type: 'context', path: 'projects/conduit')];

  @override
  Future<ServerMemory> createMemory({
    required String content,
    String type = ServerMemory.userType,
    String? path,
    ApiAuthSnapshot? authSnapshot,
  }) async {
    adds.add((content: content, type: type, path: path));
    return _memory(type: type, path: path);
  }

  @override
  Future<ServerMemory> updateMemory({
    required String memoryId,
    required String content,
    String? type,
    String? path,
    ApiAuthSnapshot? authSnapshot,
  }) async {
    updates.add((content: content, type: type, path: path));
    return _memory(type: type, path: path);
  }

  @override
  Future<void> deleteMemory(
    String memoryId, {
    ApiAuthSnapshot? authSnapshot,
  }) async {
    deleted.add(memoryId);
  }
}

/// The real app with an Open WebUI account, driven the way the iOS sheet
/// drives it: through [NativeSheetBridge].
final class _NativeSettings {
  _NativeSettings(this.tester, this.api, this.container);

  final WidgetTester tester;
  final _MemoriesApi api;
  final ProviderContainer container;
  final patches = <PlatformNativeSheetApplyDetailPatchRequest>[];
  Object epoch = Object();

  PlatformNativeSheetApplyDetailPatchRequest patch(String detailId) =>
      patches.lastWhere((patch) => patch.detailId == detailId);

  List<PlatformNativeSheetItem> items(String detailId) => [
    ...patch(detailId).items,
    for (final section in patch(detailId).sections) ...section.items,
  ];

  Future<void> detailAppeared(String detailId) async {
    NativeSheetBridge.instance.onDetailAppeared(
      PlatformNativeSheetDetailAppearedEvent(detailId: detailId),
    );
    await tester.pumpAndSettle();
  }

  /// A tap or edit in the native sheet. Rows that close the sheet send their
  /// action id as the control id.
  Future<void> control(String id, Object? value) async {
    NativeSheetBridge.instance.onControlChanged(
      PlatformNativeSheetControlChangedEvent(id: id, value: value),
    );
    await tester.pumpAndSettle();
  }

  /// Another user signing in on the same server: same [ApiService], new
  /// auth session.
  void switchAccount() {
    epoch = Object();
    container.invalidate(openWebUiAuthSessionEpochProvider);
  }
}

Future<_NativeSettings> _pumpApp(
  WidgetTester tester, {
  bool advanced = false,
}) async {
  if (advanced) {
    PreferencesStore.debugOverride(await FlutterKeyValueStore.load());
    await PreferencesStore.put(PreferenceKeys.advancedFeaturesEnabled, true);
  }
  final api = _MemoriesApi();
  late final _NativeSettings native;
  final storage = _MockOptimizedStorageService();
  when(storage.getThemeMode).thenReturn(null);
  when(storage.getThemePaletteId).thenReturn(null);
  when(storage.getLocaleCode).thenReturn(null);
  when(storage.getReviewerMode).thenAnswer((_) async => false);
  when(storage.getServerConfigs).thenAnswer((_) async => const [_server]);
  when(storage.getServerConfigsStrict).thenAnswer((_) async => const [_server]);
  when(storage.getActiveServerId).thenAnswer((_) async => _server.id);
  when(() => storage.isUncommittedServerConfigCandidate(any()))
      .thenReturn(false);
  final container = ProviderContainer(
    overrides: [
      optimizedStorageServiceProvider.overrideWithValue(storage),
      modelsProvider.overrideWith(_NoModels.new),
      personalizationSettingsProvider.overrideWith(_MemoryOn.new),
      apiServiceProvider.overrideWithValue(api),
      currentUserProvider2.overrideWithValue(
        const User(
          id: 'user-1',
          username: 'user',
          email: 'user@example.com',
          role: 'user',
        ),
      ),
      openWebUiAuthSessionEpochProvider.overrideWith((ref) => native.epoch),
      appStartupFlowProvider.overrideWith(_IdleStartup.new),
      quickActionsCoordinatorProvider.overrideWith(_IdleQuickActions.new),
      openWebUiRouteResolverProvider.overrideWith(_IdleRoutes.new),
      userScopedProviderCleanupProvider.overrideWithValue(null),
      chatWakelockCoordinatorProvider.overrideWithValue(null),
      goRouterProvider.overrideWithValue(
        GoRouter(
          navigatorKey: NavigationService.navigatorKey,
          routes: [GoRoute(path: '/', builder: (_, _) => const Scaffold())],
        ),
      ),
    ],
  );
  addTearDown(container.dispose);
  native = _NativeSettings(tester, api, container);

  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockDecodedMessageHandler<Object?>(_applyDetailPatchChannel, (
        message,
      ) async {
        native.patches.add(
          (message! as List<Object?>).single!
              as PlatformNativeSheetApplyDetailPatchRequest,
        );
        return <Object?>[true];
      });

  await tester.pumpWidget(
    UncontrolledProviderScope(container: container, child: const ConduitApp()),
  );
  await tester.pumpAndSettle();
  await container.read(activeServerProvider.future);
  return native;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() => registerFallbackValue(_server));

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    PreferencesStore.debugOverride(await FlutterKeyValueStore.load());
    NativeSheetBridge.instance.debugIsIOSOverride = true;
  });

  tearDown(() {
    PreferencesStore.debugReset();
    NativeSheetBridge.instance.debugIsIOSOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockDecodedMessageHandler<Object?>(_applyDetailPatchChannel, null);
  });

  group('with Advanced off', () {
    testWidgets('the native memory editor stays a content box that saves a '
        'user memory', (tester) async {
      final native = await _pumpApp(tester);

      await native.detailAppeared('memory-manage');
      final add = native
          .patch('memory-manage')
          .detailSheets!
          .singleWhere((detail) => detail.id == 'memory-add');
      expect(add.confirmActionId, isNull);
      expect(add.items.map((item) => item.id), ['memory-add-content']);
      final edit = native
          .patch('memory-manage')
          .detailSheets!
          .singleWhere((detail) => detail.id == 'memory-edit:m1');
      expect(
        edit.sections.expand((section) => section.items).map((item) => item.id),
        isNot(contains('memory-type:m1')),
      );

      await native.control('memory-add-content', 'I prefer metric units');

      expect(native.api.adds, [
        (content: 'I prefer metric units', type: 'user', path: null),
      ]);
    });
  });

  group('with Advanced on', () {
    testWidgets('Add memory holds the text, type and path until Done', (
      tester,
    ) async {
      final native = await _pumpApp(tester, advanced: true);

      await native.detailAppeared('memory-manage');
      final add = native
          .patch('memory-manage')
          .detailSheets!
          .singleWhere((detail) => detail.id == 'memory-add');
      expect(add.confirmActionId, nativeMemoryNewSaveId);
      expect(
        add.sections.expand((section) => section.items).map((item) => item.id),
        [
          nativeMemoryNewContentId,
          nativeMemoryNewTypeId,
          nativeMemoryNewPathId,
        ],
      );

      await native.control(nativeMemoryNewContentId, 'Repo notes');
      await native.control(nativeMemoryNewTypeId, 'context');
      await native.control(nativeMemoryNewPathId, 'repos/a');
      expect(native.api.adds, isEmpty);
      await native.control(nativeMemoryNewSaveId, true);

      expect(native.api.adds, [
        (content: 'Repo notes', type: 'context', path: 'repos/a'),
      ]);
    });

    testWidgets('an Add Memory page left without Done starts empty the next '
        'time', (tester) async {
      final native = await _pumpApp(tester, advanced: true);
      await native.detailAppeared('memory-manage');

      await native.control(nativeMemoryNewContentId, 'Left behind');
      await native.control(nativeMemoryNewTypeId, 'context');
      // Back on the list, then Add Memory again.
      await native.detailAppeared('memory-manage');
      await native.control(nativeMemoryNewSaveId, true);
      expect(native.api.adds, isEmpty);

      await native.control(nativeMemoryNewContentId, 'Fresh');
      await native.control(nativeMemoryNewSaveId, true);
      expect(native.api.adds, [(content: 'Fresh', type: 'user', path: null)]);
    });

    testWidgets("a memory's page saves its type and path as they change", (
      tester,
    ) async {
      final native = await _pumpApp(tester, advanced: true);

      await native.detailAppeared('memory-manage');
      final detail = native
          .patch('memory-manage')
          .detailSheets!
          .singleWhere((detail) => detail.id == 'memory-edit:m1');
      final rows = detail.sections.expand((section) => section.items);
      final type = rows.singleWhere((item) => item.id == 'memory-type:m1');
      expect(type.value, 'context');
      expect(
        rows.singleWhere((item) => item.id == 'memory-path:m1').value,
        'projects/conduit',
      );
      expect(rows.map((item) => item.id), contains('memory-delete:m1'));

      await native.control('memory-type:m1', 'user');

      expect(native.api.updates, [
        (content: 'Prefers metric units', type: 'user', path: null),
      ]);
    });
  });

  group('memory permission', () {
    testWidgets('a denied account is offered no Memory row and no editor', (
      tester,
    ) async {
      final native = await _pumpApp(tester, advanced: true);
      await native.detailAppeared('memory-manage');
      native.api.permissions = const {
        'features': {'memories': false},
      };
      native.container.invalidate(memoriesPermittedProvider);

      await native.detailAppeared('ai-memory');
      expect(
        native.items('ai-memory').map((item) => item.id),
        isNot(contains('personalization-memory')),
      );

      await native.control(nativeMemoryNewContentId, 'denied');
      await native.control(nativeMemoryNewSaveId, true);
      await native.control('memory-add-content', 'denied');
      await native.control('memory-save:m1', 'denied');
      await native.control('memory-delete:m1', true);

      expect(native.api.adds, isEmpty);
      expect(native.api.updates, isEmpty);
      expect(native.api.deleted, isEmpty);
    });
  });

  group('account switch', () {
    testWidgets('a list left open cannot change the next account\'s '
        'memories', (tester) async {
      final native = await _pumpApp(tester, advanced: true);
      await native.detailAppeared('memory-manage');

      native.switchAccount();
      await tester.pumpAndSettle();
      await native.control(nativeMemoryNewContentId, 'from account A');
      await native.control(nativeMemoryNewSaveId, true);
      await native.control('memory-type:m1', 'user');
      await native.control('memory-add-content', 'from account A');
      await native.control('memory-save:m1', 'from account A');
      await native.control('memory-delete:m1', true);
      await native.control('memory-clear-all', true);

      expect(native.api.adds, isEmpty);
      expect(native.api.updates, isEmpty);
      expect(native.api.deleted, isEmpty);

      // The pages stay open with what was typed, and say why.
      final changed = AppLocalizationsEn().personalizationMemoryAccountChanged;
      final add = native.items('memory-add');
      expect(add.first.title, changed);
      expect(
        add.singleWhere((row) => row.id == 'memory-add-content').value,
        'from account A',
      );
      expect(native.items('memory-edit:m1').first.title, changed);
      expect(
        native.container.read(settingsPagesProvider).closeRequests.keys,
        isNot(anyOf(contains('memory-add'), contains('memory-edit:m1'))),
      );

      // The next account's own list works.
      await native.detailAppeared('memory-manage');
      await native.control('memory-add-content', 'from account B');
      expect(native.api.adds.map((write) => write.content), ['from account B']);
    });
  });
}
