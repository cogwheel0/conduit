import 'package:conduit/core/utils/native_sheet_utils.dart';

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
import 'package:conduit_core/features/push/models/push_status.dart';
import 'package:conduit_core/features/push/providers/push_providers.dart';
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
import 'package:conduit_core/ports/push_platform_port.dart' show PushTransport;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart' show Navigator, Scaffold;
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../features/push/push_test_support.dart';

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
  PushState? push,
  FakePushCoordinator? coordinator,
}) async {
  if (advanced) {
    await PreferencesStore.put(PreferenceKeys.advancedFeaturesEnabled, true);
  }
  // With notifications off the page shows only their switch.
  await PreferencesStore.put(PreferenceKeys.notificationsEnabled, true);
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
      pushStateIfUsedProvider.overrideWith(
        (ref) => push == null ? null : ref.watch(pushCoordinatorProvider),
      ),
      if (coordinator != null)
        pushCoordinatorProvider.overrideWith(() => coordinator),
      openWebUiAccountsProvider.overrideWith(
        (ref) async => const <OpenWebUiAccountEntry>[],
      ),
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

List<String> _ids(Iterable<PlatformNativeSheetItem> items) => [
  for (final item in items) item.id,
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

  testWidgets('with push off the sheet offers the push switch, the privacy '
      'explainer and the scheduled tasks toggle', (tester) async {
    final native = await _pumpApp(tester, advanced: false);

    await native.detailAppeared(_detail);

    final items = native.items(_detail);
    final ids = _ids(items);
    expect(
      ids,
      containsAllInOrder([
        'notifications-enabled',
        'push-enabled',
        'push-privacy',
        'notification-in-app-banner',
      ]),
    );
    expect(ids, contains('notification-scheduled'));
    expect(ids, isNot(contains(NativeSheetRoutes.pushTargets)));
    final toggle = items.singleWhere((item) => item.id == 'push-enabled');
    expect(toggle.kind, PlatformNativeSheetItemKind.toggle);
    expect(toggle.value, isFalse);
    expect(native.patches.last.detailSheets ?? const [], isEmpty);
  });

  testWidgets('with push on it lists every target with its status', (
    tester,
  ) async {
    final state = pushStateWith([
      const PushTargetState(target: pushOwuiTarget, status: PushStatus.on),
      const PushTargetState(
        target: pushHermesApiTarget,
        status: PushStatus.needsHermesPlugin,
        hermesInstallCommand: 'hermes plugins install x',
      ),
    ]);
    final native = await _pumpApp(
      tester,
      advanced: false,
      push: state,
      coordinator: FakePushCoordinator(state),
    );

    await native.detailAppeared(_detail);

    final row = native
        .items(_detail)
        .singleWhere((item) => item.id == NativeSheetRoutes.pushTargets);
    expect(row.title, 'Accounts');
    expect(row.subtitle, 'Push needs attention');
    final detail = native.patches.last.detailSheets!.single;
    expect(detail.id, NativeSheetRoutes.pushTargets);
    expect(detail.title, 'Accounts');
    final rows = [for (final s in detail.sections) ...s.items];
    final owui = rows.singleWhere(
      (item) => item.id == 'push-target:${pushOwuiTarget.scope}',
    );
    expect(owui.subtitle, 'On');
    expect(owui.dismissOnSelect, isTrue);
    expect(owui.actionId, 'push-target');
    expect(owui.actionValue, pushOwuiTarget.scope);
    final hermes = rows.singleWhere(
      (item) => item.id == 'push-target:${pushHermesApiTarget.scope}',
    );
    expect(hermes.title, 'Home Hermes');
    expect(hermes.subtitle, 'Needs the Conduit plugin in Hermes');
    expect(hermes.sfSymbol, 'exclamationmark.triangle');
  });

  testWidgets('the push switch turns push on', (tester) async {
    final fake = FakePushCoordinator(pushStateWith(const [], enabled: false));
    final native = await _pumpApp(
      tester,
      advanced: false,
      push: fake.initial,
      coordinator: fake,
    );
    await native.detailAppeared(_detail);

    await native.control('push-enabled', true);

    expect(fake.calls, ['setEnabled true']);
    final row = native
        .items(_detail)
        .singleWhere((item) => item.id == 'push-enabled');
    expect(row.value, isTrue);
  });

  testWidgets('a target row opens its detail sheet over the Notifications '
      'page', (tester) async {
    final state = pushStateWith([
      const PushTargetState(
        target: pushOwuiTarget,
        status: PushStatus.needsAdminSetup,
      ),
    ]);
    final native = await _pumpApp(
      tester,
      advanced: false,
      push: state,
      coordinator: FakePushCoordinator(state),
    );

    await native.control('push-target', pushOwuiTarget.scope);

    expect(native.pushed.single.path, Routes.notificationSettings);
    expect(native.pushed.single.extra, isA<NativeSheetNavigationOrigin>());
    expect(find.byKey(const Key('push-detail-status')), findsOneWidget);
    expect(find.text('Needs your admin to set up'), findsOneWidget);
  });

  testWidgets('a fix made in the sheet shows on the pages under it', (
    tester,
  ) async {
    final state = pushStateWith([
      const PushTargetState(
        target: pushOwuiTarget,
        status: PushStatus.needsAdminSetup,
      ),
    ]);
    final fake = FakePushCoordinator(state);
    final native = await _pumpApp(
      tester,
      advanced: false,
      push: state,
      coordinator: fake,
    );
    await native.control('push-target', pushOwuiTarget.scope);

    // Set up meanwhile, then the sheet is closed.
    fake.emit(
      pushStateWith([
        const PushTargetState(target: pushOwuiTarget, status: PushStatus.on),
      ]),
    );
    await tester.pumpAndSettle();
    Navigator.of(tester.element(find.byKey(const Key('push-detail-status'))))
        .pop();
    await tester.pumpAndSettle();

    final row = native
        .items(NativeSheetRoutes.pushTargets)
        .singleWhere(
          (item) => item.id == 'push-target:${pushOwuiTarget.scope}',
        );
    expect(row.subtitle, 'On');
  });

  testWidgets('a row for a target removed since opens the page alone', (
    tester,
  ) async {
    final state = pushStateWith([
      const PushTargetState(target: pushOwuiTarget, status: PushStatus.on),
    ]);
    final native = await _pumpApp(
      tester,
      advanced: false,
      push: state,
      coordinator: FakePushCoordinator(state),
    );

    await native.control('push-target', pushHermesApiTarget.scope);

    expect(native.pushed.single.path, Routes.notificationSettings);
    expect(find.byKey(const Key('push-detail-diagnostics')), findsNothing);
    expect(find.text('Push Notifications'), findsNothing);
  });

  testWidgets('push that can no longer work here can still be turned off', (
    tester,
  ) async {
    // The UnifiedPush distributor was removed while push was on.
    final fake = FakePushCoordinator(
      pushStateWith(const [], transports: const []),
    );
    final native = await _pumpApp(
      tester,
      advanced: false,
      push: fake.initial,
      coordinator: fake,
    );
    await native.detailAppeared(_detail);
    final row = native
        .items(_detail)
        .singleWhere((item) => item.id == 'push-enabled');
    expect(row.kind, PlatformNativeSheetItemKind.toggle);
    expect(row.value, isTrue);

    await native.control('push-enabled', false);
    expect(fake.calls, ['setEnabled false']);
    final off = native
        .items(_detail)
        .singleWhere((item) => item.id == 'push-enabled');
    // Off, it cannot be turned back on here.
    expect(off.kind, PlatformNativeSheetItemKind.info);
  });

  testWidgets('the scheduled tasks toggle is saved', (tester) async {
    final native = await _pumpApp(tester, advanced: false);
    await native.detailAppeared(_detail);

    await native.control('notification-scheduled', false);

    expect(
      PreferencesStore.getBool(PreferenceKeys.notificationScheduledEnabled),
      isFalse,
    );
  });

  PlatformNativeSheetItem item(_NativeSettings native, String id) =>
      native.items(_detail).singleWhere((item) => item.id == id);

  Future<void> onPlatform(
    Future<void> Function() body, {
    TargetPlatform platform = TargetPlatform.android,
  }) async {
    debugDefaultTargetPlatformOverride = platform;
    try {
      await body();
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  }

  testWidgets('without a relay iOS says why, and the switch stays off', (
    tester,
  ) async {
    await onPlatform(platform: TargetPlatform.iOS, () async {
      final fake = FakePushCoordinator(
        pushStateWith(const [], enabled: false, relayConfigured: false),
      );
      final native = await _pumpApp(
        tester,
        advanced: false,
        push: fake.initial,
        coordinator: fake,
      );
      await native.detailAppeared(_detail);

      final row = item(native, 'push-enabled');
      expect(row.subtitle, 'Not available in this build');
      expect(row.kind, PlatformNativeSheetItemKind.info);
      expect(
        _ids(native.items(_detail)),
        isNot(contains('push-get-distributor')),
      );
    });
  });

  testWidgets('Android without a relay points at UnifiedPush', (tester) async {
    await onPlatform(() async {
      final fake = FakePushCoordinator(
        pushStateWith(
          const [],
          enabled: false,
          relayConfigured: false,
          transports: const [PushTransport.fcm],
        ),
      );
      final native = await _pumpApp(
        tester,
        advanced: false,
        push: fake.initial,
        coordinator: fake,
      );
      await native.detailAppeared(_detail);

      expect(
        item(native, 'push-enabled').subtitle,
        'Not available in this build without a UnifiedPush distributor',
      );
      expect(
        item(native, 'push-get-distributor').url,
        'https://unifiedpush.org/users/distributors/',
      );
    });
  });

  testWidgets('blocked notifications offer the system settings', (
    tester,
  ) async {
    final state = pushStateWith([
      const PushTargetState(
        target: pushOwuiTarget,
        status: PushStatus.permissionDenied,
      ),
    ], permissionDenied: true);
    final native = await _pumpApp(
      tester,
      advanced: false,
      push: state,
      coordinator: FakePushCoordinator(state),
    );
    await native.detailAppeared(_detail);

    final row = item(native, 'push-permission-denied');
    expect(row.subtitle, 'Allow notifications for Conduit in system settings.');
    expect(row.showsDisclosure, isTrue);
  });

  testWidgets('with Advanced on, Android picks its delivery service and '
      'distributor', (tester) async {
    await onPlatform(() async {
      final fake = FakePushCoordinator(
        pushStateWith(
          const [
            PushTargetState(target: pushOwuiTarget, status: PushStatus.on),
          ],
          transports: const [PushTransport.fcm, PushTransport.unifiedPush],
        ),
        distributorList: const [
          'io.heckel.ntfy',
          'org.unifiedpush.distributor',
        ],
      );
      final native = await _pumpApp(
        tester,
        push: fake.initial,
        coordinator: fake,
      );
      await native.detailAppeared(_detail);
      expect(item(native, 'push-delivery:auto').checked, isTrue);
      expect(_ids(native.items(_detail)), contains('push-delivery:fcm'));

      await native.control('push-delivery:unifiedPush', true);
      expect(fake.calls, ['setAndroidTransport unifiedPush io.heckel.ntfy']);
      expect(item(native, 'push-delivery:unifiedPush').checked, isTrue);

      await native.control(
        'push-distributor:org.unifiedpush.distributor',
        true,
      );
      expect(
        fake.calls.last,
        'setAndroidTransport unifiedPush org.unifiedpush.distributor',
      );
    });
  });

  testWidgets('with no distributor, Android says where to get one', (
    tester,
  ) async {
    await onPlatform(() async {
      final fake = FakePushCoordinator(
        pushStateWith(
          const [
            PushTargetState(target: pushOwuiTarget, status: PushStatus.failed),
          ],
          transports: const [PushTransport.fcm],
          androidTransport: PushAndroidTransport.unifiedPush,
        ),
      );
      final native = await _pumpApp(
        tester,
        push: fake.initial,
        coordinator: fake,
      );
      await native.detailAppeared(_detail);

      expect(
        item(native, 'push-no-distributor').title,
        'No UnifiedPush distributor is installed.',
      );
      expect(_ids(native.items(_detail)), contains('push-distributor-get'));
    });
  });

  testWidgets('resetting the keys asks first, and is only under Advanced', (
    tester,
  ) async {
    await onPlatform(platform: TargetPlatform.iOS, () async {
      final state = pushStateWith(const [
        PushTargetState(target: pushOwuiTarget, status: PushStatus.on),
      ]);
      final fake = FakePushCoordinator(state);
      final native = await _pumpApp(tester, push: state, coordinator: fake);
      await native.detailAppeared(_detail);

      final reset = item(native, 'push-reset-keys');
      expect(reset.destructive, isTrue);
      expect(reset.confirmMessage, isNotEmpty);
      await native.control('push-reset-keys', true);
      expect(fake.calls, ['resetKeys']);
      // Android's delivery choice is not iOS's.
      expect(
        _ids(native.items(_detail)),
        isNot(contains('push-delivery:auto')),
      );
    });
  });

  testWidgets('without Advanced there is no delivery choice or reset', (
    tester,
  ) async {
    await onPlatform(() async {
      final state = pushStateWith(const [
        PushTargetState(target: pushOwuiTarget, status: PushStatus.on),
      ]);
      final native = await _pumpApp(
        tester,
        advanced: false,
        push: state,
        coordinator: FakePushCoordinator(state),
      );
      await native.detailAppeared(_detail);

      final ids = _ids(native.items(_detail));
      expect(ids, isNot(contains('push-delivery:auto')));
      expect(ids, isNot(contains('push-reset-keys')));
    });
  });

  testWidgets('a push switch that fails says so', (tester) async {
    final fake = FakePushCoordinator(pushStateWith(const [], enabled: false))
      ..setEnabledError = StateError('platform');
    final native = await _pumpApp(
      tester,
      advanced: false,
      push: fake.initial,
      coordinator: fake,
    );
    await native.detailAppeared(_detail);

    await native.control('push-enabled', true);

    expect(
      find.text('Something went wrong. Please try again.'),
      findsOneWidget,
    );
  });

  testWidgets('push stays on the page with notifications off', (tester) async {
    final state = pushStateWith(const [
      PushTargetState(target: pushOwuiTarget, status: PushStatus.on),
    ]);
    final native = await _pumpApp(
      tester,
      advanced: false,
      push: state,
      coordinator: FakePushCoordinator(state),
    );
    await native.detailAppeared(_detail);

    await native.control('notifications-enabled', false);

    final ids = _ids(native.items(_detail));
    expect(ids, contains('push-enabled'));
    expect(ids, isNot(contains('notification-in-app-banner')));
  });

  testWidgets('distributors that cannot be read say so, and are read again '
      'on Retry', (tester) async {
    await onPlatform(() async {
      final fake = FakePushCoordinator(
        pushStateWith(
          const [
            PushTargetState(target: pushOwuiTarget, status: PushStatus.on),
          ],
          transports: const [PushTransport.fcm],
          androidTransport: PushAndroidTransport.unifiedPush,
        ),
      )..distributorsError = StateError('offline');
      final native = await _pumpApp(
        tester,
        push: fake.initial,
        coordinator: fake,
      );
      await native.detailAppeared(_detail);
      final ids = _ids(native.items(_detail));
      expect(ids, contains(nativePushDistributorsRetryId));
      expect(ids, isNot(contains('push-distributors-loading')));

      fake.distributorsError = null;
      await native.control(nativePushDistributorsRetryId, true);

      expect(_ids(native.items(_detail)), contains('push-no-distributor'));
    });
  });

  testWidgets('a distributor installed since shows when the page opens '
      'again', (tester) async {
    await onPlatform(() async {
      final fake = FakePushCoordinator(
        pushStateWith(
          const [
            PushTargetState(target: pushOwuiTarget, status: PushStatus.on),
          ],
          transports: const [PushTransport.fcm],
          androidTransport: PushAndroidTransport.unifiedPush,
        ),
      );
      final native = await _pumpApp(
        tester,
        push: fake.initial,
        coordinator: fake,
      );
      await native.detailAppeared(_detail);
      expect(_ids(native.items(_detail)), contains('push-no-distributor'));

      fake.distributorList = const ['io.heckel.ntfy'];
      await native.detailAppeared(_detail);

      expect(item(native, 'push-distributor:io.heckel.ntfy').checked, isTrue);
    });
  });

  testWidgets('a key reset that fails says so', (tester) async {
    final state = pushStateWith(const [
      PushTargetState(target: pushOwuiTarget, status: PushStatus.on),
    ]);
    final fake = FakePushCoordinator(state)..resetKeysError = StateError('x');
    final native = await _pumpApp(tester, push: state, coordinator: fake);
    await native.detailAppeared(_detail);
    final drawn = native.patches.length;

    await native.control('push-reset-keys', true);

    expect(fake.calls, ['resetKeys']);
    expect(
      find.text('Something went wrong. Please try again.'),
      findsOneWidget,
    );
    // The page is drawn again once the reset has run its course.
    expect(
      native.patches.skip(drawn).map((patch) => patch.detailId),
      contains(_detail),
    );
  });

  testWidgets('a delivery change that fails says so', (tester) async {
    await onPlatform(() async {
      final fake = FakePushCoordinator(
        pushStateWith(
          const [
            PushTargetState(target: pushOwuiTarget, status: PushStatus.on),
          ],
          transports: const [PushTransport.fcm, PushTransport.unifiedPush],
        ),
      )..transportError = StateError('storage');
      final native = await _pumpApp(
        tester,
        push: fake.initial,
        coordinator: fake,
      );
      await native.detailAppeared(_detail);

      await native.control('push-delivery:fcm', true);

      expect(
        find.text('Something went wrong. Please try again.'),
        findsOneWidget,
      );
    });
  });
}
