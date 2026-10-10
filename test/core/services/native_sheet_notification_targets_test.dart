import 'dart:async';

import 'package:conduit/core/providers/app_startup_providers.dart';
import 'package:conduit/core/router/app_router.dart';
import 'package:conduit/core/services/native_sheet_bridge.dart';
import 'package:conduit/main.dart';
import 'package:conduit/platform/conduit_platform_apis.g.dart';
import 'package:conduit/platform/flutter_key_value_store.dart';
import 'package:conduit/platform/quick_actions_service.dart';
import 'package:conduit/shared/services/navigation_service.dart';
import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit_core/features/notifications/models/notification_target.dart';
import 'package:conduit_core/features/notifications/providers/notification_target_providers.dart';
import 'package:conduit_core/features/chat/providers/chat_providers.dart'
    show chatWakelockCoordinatorProvider;
import 'package:conduit_core/models/backend_config.dart';
import 'package:conduit_core/models/model.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/models/user.dart';
import 'package:conduit_core/persistence/persistence_keys.dart';
import 'package:conduit_core/persistence/preferences_store.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/providers/openwebui_route_resolver.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/optimized_storage_service.dart';
import 'package:conduit_core/services/worker_manager.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart' show Scaffold;
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

class _Config extends BackendConfigNotifier {
  _Config(this._config);

  final BackendConfig _config;

  @override
  Future<BackendConfig?> build() async => _config;
}

/// The account's webhook destinations, without a server round trip.
class _Targets extends NotificationTargets {
  _Targets(this._count);

  final int? _count;

  @override
  Future<NotificationTargetsData> build() async {
    final count = _count;
    if (count == null) throw StateError('list unavailable');
    return NotificationTargetsData(
      targets: [
        for (var i = 0; i < count; i++)
          NotificationTarget(
            id: 'target-$i',
            type: NotificationTarget.webhookType,
            enabled: true,
            events: const <String>[],
            delivery: NotificationTarget.deliveryAlways,
          ),
      ],
    );
  }
}

final _applyDetailPatchChannel = BasicMessageChannel<Object?>(
  'dev.flutter.pigeon.conduit.NativeSheetHostApi.applyDetailPatch',
  NativeSheetHostApi.pigeonChannelCodec,
);

/// The real app with an Open WebUI account, driven the way the iOS sheet
/// drives it: through [NativeSheetBridge].
final class _NativeSettings {
  _NativeSettings(this.tester);

  final WidgetTester tester;
  final patches = <PlatformNativeSheetApplyDetailPatchRequest>[];

  /// Where the router went: path and the extra it carried, in order.
  final pushed = <({String path, Object? extra})>[];

  List<PlatformNativeSheetItem> items(String detailId) {
    final patch = patches.lastWhere((patch) => patch.detailId == detailId);
    return [
      ...patch.items,
      for (final section in patch.sections) ...section.items,
    ];
  }

  Future<void> detailAppeared(String detailId) async {
    NativeSheetBridge.instance.onDetailAppeared(
      PlatformNativeSheetDetailAppearedEvent(detailId: detailId),
    );
    await tester.pumpAndSettle();
  }

  /// A tap in the native sheet. Rows that close the sheet send their action id
  /// as the control id.
  Future<void> control(String id, Object? value) async {
    NativeSheetBridge.instance.onControlChanged(
      PlatformNativeSheetControlChangedEvent(id: id, value: value),
    );
    await tester.pumpAndSettle();
  }
}

Future<_NativeSettings> _pumpApp(
  WidgetTester tester, {
  bool advanced = true,
  bool serverEnabled = true,
  Map<String, dynamic> permissions = const {
    'features': {'webhooks': true},
  },
  int? targetCount = 0,
  bool signedIn = true,
}) async {
  if (advanced) {
    await PreferencesStore.put(PreferenceKeys.advancedFeaturesEnabled, true);
  }
  final native = _NativeSettings(tester);
  final api = ApiService(serverConfig: _server, workerManager: WorkerManager());
  addTearDown(api.dispose);
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

  Widget routePage(String name) => Scaffold(body: Text(name));
  final router = GoRouter(
    navigatorKey: NavigationService.navigatorKey,
    routes: [
      GoRoute(path: '/', builder: (_, _) => routePage('home')),
      GoRoute(
        path: Routes.notificationSettings,
        name: RouteNames.notificationSettings,
        builder: (_, state) {
          native.pushed.add((path: state.uri.path, extra: state.extra));
          return routePage('notifications page');
        },
      ),
    ],
  );
  // The real router provider attaches itself; this stand-in must as well, or
  // a native action has no router to navigate.
  NavigationService.attachRouter(router);
  addTearDown(router.dispose);
  final container = ProviderContainer(
    overrides: [
      optimizedStorageServiceProvider.overrideWithValue(storage),
      modelsProvider.overrideWith(_NoModels.new),
      apiServiceProvider.overrideWithValue(api),
      // Signed in to it, as the user above, unless the test says otherwise.
      openWebUiAccountAvailableProvider.overrideWithValue(signedIn),
      currentUserProvider2.overrideWithValue(
        const User(
          id: 'user-1',
          username: 'user',
          email: 'user@example.com',
          role: 'user',
        ),
      ),
      backendConfigProvider.overrideWith(
        () => _Config(
          BackendConfig(
            serverId: _server.id,
            enableUserWebhooks: serverEnabled,
          ),
        ),
      ),
      userPermissionsProvider.overrideWith((ref) async => permissions),
      notificationTargetsProvider.overrideWith(() => _Targets(targetCount)),
      appStartupFlowProvider.overrideWith(_IdleStartup.new),
      quickActionsCoordinatorProvider.overrideWith(_IdleQuickActions.new),
      openWebUiRouteResolverProvider.overrideWith(_IdleRoutes.new),
      userScopedProviderCleanupProvider.overrideWithValue(null),
      chatWakelockCoordinatorProvider.overrideWithValue(null),
      goRouterProvider.overrideWithValue(router),
    ],
  );
  addTearDown(container.dispose);

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

const _detail = NativeSheetRoutes.notificationSettings;
const _localToggles = [
  'notifications-enabled',
  'push-enabled',
  'push-privacy',
  'notification-in-app-banner',
  'notification-system',
  'notification-sound',
  'notification-sound-always',
  'notification-chat',
  'notification-channel',
  'notification-scheduled',
];

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

  testWidgets('a permitted account with Advanced on is offered the Webhook '
      'destinations row beside the local toggles', (tester) async {
    final native = await _pumpApp(tester);

    await native.detailAppeared(_detail);

    final ids = native.items(_detail).map((item) => item.id).toList();
    expect(ids, containsAll(_localToggles));
    final row = native
        .items(_detail)
        .singleWhere((item) => item.id == 'notification-targets');
    expect(row.title, 'Webhook destinations');
    expect(row.dismissOnSelect, isTrue);
    expect(row.actionId, 'notification-targets');
    expect(row.sfSymbol, 'bell.and.waves.left.and.right');
    expect(row.subtitle, 'None');
    // What destinations are lives under the row, not in its subtitle.
    final group = native.patches.last.sections.last;
    expect(group.items.single.id, 'notification-targets');
    expect(
      group.footer,
      'Your Open WebUI server sends events to these URLs, even while this '
      'app is closed.',
    );
  });

  testWidgets('without a signed-in account there are no channels to notify', (
    tester,
  ) async {
    final native = await _pumpApp(tester, signedIn: false);

    await native.detailAppeared(_detail);

    final ids = native.items(_detail).map((item) => item.id).toList();
    expect(ids, isNot(contains('notification-channel')));
    expect(ids, contains('notification-scheduled'));
  });

  testWidgets('the local toggles show before the destinations group is added', (
    tester,
  ) async {
    final native = await _pumpApp(tester, targetCount: 2);

    await native.detailAppeared(_detail);

    final patches = native.patches.where((p) => p.detailId == _detail).toList();
    expect(patches, hasLength(2));
    List<String> ids(PlatformNativeSheetApplyDetailPatchRequest patch) => [
      for (final section in patch.sections) ...section.items.map((i) => i.id),
    ];
    expect(ids(patches.first), _localToggles);
    expect(ids(patches.last), [..._localToggles, 'notification-targets']);
    expect(native.items(_detail).last.subtitle, '2 destinations');
  });

  testWidgets('an unreadable list leaves the row without a count', (
    tester,
  ) async {
    final native = await _pumpApp(tester, targetCount: null);

    await native.detailAppeared(_detail);

    final row = native.items(_detail).last;
    expect(row.id, 'notification-targets');
    expect(row.subtitle, isNull);
  });

  testWidgets('tapping it closes the sheet and opens the Notifications page '
      'with the native-sheet origin', (tester) async {
    final native = await _pumpApp(tester);
    await native.detailAppeared(_detail);

    await native.control('notification-targets', true);

    expect(find.text('notifications page'), findsOneWidget);
    expect(native.pushed, hasLength(1));
    expect(native.pushed.single.path, Routes.notificationSettings);
    expect(native.pushed.single.extra, isA<NativeSheetNavigationOrigin>());
  });

  group('without a row', () {
    // Each is a reason the account is not offered webhook destinations. The
    // local toggles must be unaffected, and a stale tap must go nowhere.
    final cases =
        <
          String,
          ({
            bool advanced,
            bool serverEnabled,
            Map<String, dynamic> permissions,
          })
        >{
          'Advanced off': (
            advanced: false,
            serverEnabled: true,
            permissions: const {
              'features': {'webhooks': true},
            },
          ),
          'server flag off': (
            advanced: true,
            serverEnabled: false,
            permissions: const {
              'features': {'webhooks': true},
            },
          ),
          'permission missing': (
            advanced: true,
            serverEnabled: true,
            permissions: const {},
          ),
        };

    for (final MapEntry(:key, :value) in cases.entries) {
      testWidgets(key, (tester) async {
        final native = await _pumpApp(
          tester,
          advanced: value.advanced,
          serverEnabled: value.serverEnabled,
          permissions: value.permissions,
        );

        await native.detailAppeared(_detail);

        final ids = native.items(_detail).map((item) => item.id).toList();
        expect(ids, containsAll(_localToggles));
        expect(ids, isNot(contains('notification-targets')));

        await native.control('notification-targets', true);

        expect(find.text('notifications page'), findsNothing);
        expect(native.pushed, isEmpty);
        expect(
          find.text("That option isn't available right now."),
          findsOneWidget,
        );
      });
    }
  });
}
