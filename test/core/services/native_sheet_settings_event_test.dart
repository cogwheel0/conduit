import 'dart:async';

import 'package:checks/checks.dart';
import 'package:conduit/core/providers/app_startup_providers.dart';
import 'package:conduit/core/router/app_router.dart';
import 'package:conduit/core/services/native_sheet_bridge.dart';
import 'package:conduit/core/services/native_sheet_hydration_service.dart';
import 'package:conduit/core/utils/native_sheet_utils.dart';
import 'package:conduit/main.dart';
import 'package:conduit/platform/flutter_key_value_store.dart';
import 'package:conduit/platform/quick_actions_service.dart';
import 'package:conduit/platform/conduit_platform_apis.g.dart';
import 'package:conduit/shared/services/navigation_service.dart';
import 'package:conduit_core/features/chat/providers/chat_providers.dart'
    show chatDataControlsEntryVisibleProvider, chatWakelockCoordinatorProvider;
import 'package:conduit_core/features/automations/providers/automation_providers.dart'
    show scheduledTasksEntryVisibleProvider;
import 'package:conduit_core/features/calendar/providers/calendar_providers.dart'
    show calendarAvailableProvider;
import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit_core/features/integrations/providers/personal_connections_providers.dart';
import 'package:conduit_core/models/user.dart';
import 'package:conduit_core/models/model.dart';
import 'package:conduit_core/persistence/persistence_keys.dart';
import 'package:conduit_core/persistence/preferences_store.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/providers/openwebui_route_resolver.dart';
import 'package:conduit_core/services/optimized_storage_service.dart';
import 'package:conduit_core/services/settings_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart' show LicensePage, Scaffold;
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

final _applyDetailPatchChannel = BasicMessageChannel<Object?>(
  'dev.flutter.pigeon.conduit.NativeSheetHostApi.applyDetailPatch',
  NativeSheetHostApi.pigeonChannelCodec,
);

final _dismissChannel = BasicMessageChannel<Object?>(
  'dev.flutter.pigeon.conduit.NativeSheetHostApi.dismiss',
  NativeSheetHostApi.pigeonChannelCodec,
);

const _unavailable = "That option isn't available right now.";

const _ada = User(
  id: 'user-1',
  username: 'ada',
  email: 'ada@example.com',
  role: 'user',
);

class _SignedInUser extends Notifier<User?> {
  @override
  User? build() => null;

  void signIn(User? user) => state = user;
}

final _signedInUser = NotifierProvider<_SignedInUser, User?>(
  _SignedInUser.new,
);

/// Records every detail patch the app sends to the native sheet.
List<PlatformNativeSheetApplyDetailPatchRequest> _recordPatches() {
  final patches = <PlatformNativeSheetApplyDetailPatchRequest>[];
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockDecodedMessageHandler<Object?>(_applyDetailPatchChannel, (
        message,
      ) async {
        patches.add(
          (message! as List<Object?>).single!
              as PlatformNativeSheetApplyDetailPatchRequest,
        );
        return <Object?>[true];
      });
  return patches;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    PreferencesStore.debugOverride(await FlutterKeyValueStore.load());
    NativeSheetBridge.instance.debugIsIOSOverride = true;
  });

  tearDown(() {
    PreferencesStore.debugReset();
    NativeSheetBridge.instance.debugIsIOSOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      ..setMockDecodedMessageHandler<Object?>(_applyDetailPatchChannel, null)
      ..setMockDecodedMessageHandler<Object?>(_dismissChannel, null);
  });

  /// Boots [ConduitApp] with the platform seams idle, so a native sheet event
  /// can be delivered through the real bridge and its effect observed.
  Future<ProviderContainer> pumpApp(
    WidgetTester tester, {
    List<GoRoute> routes = const <GoRoute>[],
    List<Override> overrides = const <Override>[],
  }) async {
    final storage = _MockOptimizedStorageService();
    when(storage.getThemeMode).thenReturn(null);
    when(storage.getThemePaletteId).thenReturn(null);
    when(storage.getLocaleCode).thenReturn(null);
    when(storage.getReviewerMode).thenAnswer((_) async => false);
    final router = GoRouter(
      navigatorKey: NavigationService.navigatorKey,
      routes: [
        GoRoute(
          path: '/',
          builder: (_, _) => const Scaffold(body: SizedBox.shrink()),
        ),
        ...routes,
      ],
    );
    // The real router provider attaches itself; the override must do the same,
    // or a native action has nothing to navigate.
    NavigationService.attachRouter(router);
    addTearDown(router.dispose);
    final container = ProviderContainer(
      overrides: [
        optimizedStorageServiceProvider.overrideWithValue(storage),
        modelsProvider.overrideWith(_NoModels.new),
        appStartupFlowProvider.overrideWith(_IdleStartup.new),
        quickActionsCoordinatorProvider.overrideWith(_IdleQuickActions.new),
        openWebUiRouteResolverProvider.overrideWith(_IdleRoutes.new),
        userScopedProviderCleanupProvider.overrideWithValue(null),
        chatWakelockCoordinatorProvider.overrideWithValue(null),
        goRouterProvider.overrideWithValue(router),
        ...overrides,
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const ConduitApp(),
      ),
    );
    await tester.pump();
    return container;
  }

  for (final visible in <bool>[true, false]) {
    testWidgets(
      visible
          ? 'the native Personal connections action opens the list from the sheet'
          : 'the native Personal connections action does nothing once hidden',
      (tester) async {
        Object? extra;
        var opened = 0;
        await pumpApp(
          tester,
          routes: [
            GoRoute(
              path: Routes.personalConnections,
              name: RouteNames.personalConnections,
              builder: (_, state) {
                opened++;
                extra = state.extra;
                return const SizedBox.shrink();
              },
            ),
          ],
          overrides: [
            personalConnectionsEntryVisibleProvider.overrideWithValue(visible),
          ],
        );

        NativeSheetBridge.instance.onControlChanged(
          PlatformNativeSheetControlChangedEvent(
            id: NativeSheetRoutes.personalConnections,
            value: true,
          ),
        );
        await tester.pumpAndSettle();

        // Advanced, the server or the account can change while the sheet is
        // open; a row that went stale must not navigate.
        expect(opened, visible ? 1 : 0);
        if (visible) expect(extra, isA<NativeSheetNavigationOrigin>());
        // The sheet has already closed, so a stale row says why nothing
        // opened instead of failing silently.
        expect(find.text(_unavailable), visible ? findsNothing : findsOneWidget);
      },
    );
  }

  for (final visible in <bool>[true, false]) {
    testWidgets(
      visible
          ? 'the native Scheduled tasks action opens the list from the sheet'
          : 'the native Scheduled tasks action does nothing once hidden',
      (tester) async {
        Object? extra;
        var opened = 0;
        await pumpApp(
          tester,
          routes: [
            GoRoute(
              path: Routes.scheduledTasks,
              name: RouteNames.scheduledTasks,
              builder: (_, state) {
                opened++;
                extra = state.extra;
                return const SizedBox.shrink();
              },
            ),
          ],
          overrides: [
            scheduledTasksEntryVisibleProvider.overrideWithValue(visible),
          ],
        );

        NativeSheetBridge.instance.onControlChanged(
          PlatformNativeSheetControlChangedEvent(
            id: NativeSheetRoutes.scheduledTasks,
            value: true,
          ),
        );
        await tester.pumpAndSettle();

        // Advanced, the server or the account can change while the sheet is
        // open; a row that went stale must not navigate.
        expect(opened, visible ? 1 : 0);
        if (visible) expect(extra, isA<NativeSheetNavigationOrigin>());
        // The sheet has already closed, so a stale row says why nothing
        // opened instead of failing silently.
        expect(find.text(_unavailable), visible ? findsNothing : findsOneWidget);
      },
    );
  }

  for (final visible in <bool>[true, false]) {
    testWidgets(
      visible
          ? 'the native Calendar action opens the agenda from the sheet'
          : 'the native Calendar action does nothing once hidden',
      (tester) async {
        Object? extra;
        var opened = 0;
        await pumpApp(
          tester,
          routes: [
            GoRoute(
              path: Routes.calendar,
              name: RouteNames.calendar,
              builder: (_, state) {
                opened++;
                extra = state.extra;
                return const SizedBox.shrink();
              },
            ),
          ],
          overrides: [calendarAvailableProvider.overrideWithValue(visible)],
        );

        NativeSheetBridge.instance.onControlChanged(
          PlatformNativeSheetControlChangedEvent(
            id: NativeSheetRoutes.calendar,
            value: true,
          ),
        );
        await tester.pumpAndSettle();

        // The server or the account can change while the sheet is open; a
        // row that went stale must not navigate.
        expect(opened, visible ? 1 : 0);
        if (visible) expect(extra, isA<NativeSheetNavigationOrigin>());
        // The sheet has already closed, so a stale row says why nothing
        // opened instead of failing silently.
        expect(find.text(_unavailable), visible ? findsNothing : findsOneWidget);
      },
    );
  }

  for (final visible in <bool>[true, false]) {
    testWidgets(
      visible
          ? 'the native Data controls action opens the page from the sheet'
          : 'the native Data controls action does nothing once hidden',
      (tester) async {
        Object? extra;
        var opened = 0;
        await pumpApp(
          tester,
          routes: [
            GoRoute(
              path: Routes.chatDataControls,
              name: RouteNames.chatDataControls,
              builder: (_, state) {
                opened++;
                extra = state.extra;
                return const SizedBox.shrink();
              },
            ),
          ],
          overrides: [
            chatDataControlsEntryVisibleProvider.overrideWithValue(visible),
          ],
        );

        NativeSheetBridge.instance.onControlChanged(
          PlatformNativeSheetControlChangedEvent(
            id: NativeSheetRoutes.chatDataControls,
            value: true,
          ),
        );
        await tester.pumpAndSettle();

        // Advanced or the account can change while the sheet is open; a row
        // that went stale must not navigate. The sheet has already closed, so
        // the page opens with no second transition over it.
        expect(opened, visible ? 1 : 0);
        if (visible) expect(extra, isA<NativeSheetNavigationOrigin>());
        // The sheet has already closed, so a stale row says why nothing
        // opened instead of failing silently.
        expect(find.text(_unavailable), visible ? findsNothing : findsOneWidget);
      },
    );
  }

  testWidgets(
    'the native Advanced toggle saves its boolean and refreshes Chats',
    (tester) async {
      final patches = <PlatformNativeSheetApplyDetailPatchRequest>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockDecodedMessageHandler<Object?>(_applyDetailPatchChannel, (
            message,
          ) async {
            patches.add(
              (message! as List<Object?>).single!
                  as PlatformNativeSheetApplyDetailPatchRequest,
            );
            return <Object?>[true];
          });
      final container = await pumpApp(tester);

      bool saved() =>
          container.read(appSettingsProvider).advancedFeaturesEnabled;
      check(saved()).isFalse();

      // A non-boolean payload from the platform is ignored.
      NativeSheetBridge.instance.onControlChanged(
        PlatformNativeSheetControlChangedEvent(
          id: 'advanced-features',
          value: 'true',
        ),
      );
      await tester.pump();
      await tester.pump();
      check(saved()).isFalse();
      check(patches.where((p) => p.detailId == 'chats')).isEmpty();

      NativeSheetBridge.instance.onControlChanged(
        PlatformNativeSheetControlChangedEvent(
          id: 'advanced-features',
          value: true,
        ),
      );
      await tester.pump();
      await tester.pump();

      check(saved()).isTrue();
      check(PreferencesStore.getBool(PreferenceKeys.advancedFeaturesEnabled))
          .equals(true);
      final chats = patches.lastWhere((p) => p.detailId == 'chats');
      final advanced = [for (final section in chats.sections) ...section.items]
          .singleWhere((item) => item.id == 'advanced-features');
      check(advanced.value).equals(true);
    },
  );

  group('the open Settings root', () {
    List<String> rootRows(PlatformNativeSheetApplyDetailPatchRequest patch) =>
        [for (final section in patch.sections) ...section.items.map((i) => i.id)];

    testWidgets('gains and loses the Advanced group as Advanced is toggled', (
      tester,
    ) async {
      final patches = _recordPatches();
      final container = await pumpApp(
        tester,
        overrides: [
          // Personal connections follow Advanced, as they do for an account
          // the server lets keep them.
          personalConnectionsEntryVisibleProvider.overrideWith(
            (ref) => ref.watch(
              appSettingsProvider.select((s) => s.advancedFeaturesEnabled),
            ),
          ),
        ],
      );
      container
          .read(nativeSheetHydrationServiceProvider)
          .rememberProfileRoot(null);

      NativeSheetBridge.instance.onControlChanged(
        PlatformNativeSheetControlChangedEvent(
          id: 'advanced-features',
          value: true,
        ),
      );
      await tester.pumpAndSettle();

      final on = patches.lastWhere((p) => p.detailId == 'profile-menu');
      check(on.title).equals('Settings');
      final advanced = on.sections.singleWhere((s) => s.title == 'Advanced');
      check(advanced.footer).equals(
        'Shown because Advanced is on in Settings > Chat.',
      );
      check(
        advanced.items.map((i) => i.id),
      ).deepEquals([NativeSheetRoutes.personalConnections]);

      NativeSheetBridge.instance.onControlChanged(
        PlatformNativeSheetControlChangedEvent(
          id: 'advanced-features',
          value: false,
        ),
      );
      await tester.pumpAndSettle();

      final off = patches.lastWhere((p) => p.detailId == 'profile-menu');
      check(off.sections.map((s) => s.title)).not(
        (it) => it.contains('Advanced'),
      );
      check(rootRows(off)).not(
        (it) => it.contains(NativeSheetRoutes.personalConnections),
      );
      // A tap on the row it just lost is answered, not ignored.
      NativeSheetBridge.instance.onControlChanged(
        PlatformNativeSheetControlChangedEvent(
          id: NativeSheetRoutes.personalConnections,
          value: true,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text(_unavailable), findsOneWidget);
    });

    testWidgets('is not rebuilt once another account signed in', (
      tester,
    ) async {
      final patches = _recordPatches();
      final container = await pumpApp(
        tester,
        overrides: [
          currentUserProvider2.overrideWith((ref) => ref.watch(_signedInUser)),
        ],
      );
      container.read(_signedInUser.notifier).signIn(_ada);
      final service = container.read(nativeSheetHydrationServiceProvider);
      service.rememberProfileRoot(
        const NativeProfileRootAccount(
          displayName: 'Ada',
          email: 'ada@example.com',
        ),
      );

      check(await service.refreshProfileRoot()).isTrue();
      final rebuilt = patches.lastWhere((p) => p.detailId == 'profile-menu');
      // Still Ada's: her card first, her own rows after it.
      final card = rebuilt.sections.first.items.first;
      check(card.id).equals(nativeAccountsDetailId);
      check(card.title).equals('Ada');
      check(rootRows(rebuilt)).contains(NativeSheetRoutes.profile);

      patches.clear();
      container
          .read(_signedInUser.notifier)
          .signIn(_ada.copyWith(id: 'user-2', email: 'grace@example.com'));
      check(await service.refreshProfileRoot()).isFalse();
      check(patches).isEmpty();
    });

    testWidgets('nothing is sent when no Settings root is on record', (
      tester,
    ) async {
      final patches = _recordPatches();
      final container = await pumpApp(tester);

      check(
        await container
            .read(nativeSheetHydrationServiceProvider)
            .refreshProfileRoot(),
      ).isFalse();
      check(patches.where((p) => p.detailId == 'profile-menu')).isEmpty();
    });
  });

  testWidgets('the native citation titles toggle saves its boolean', (
    tester,
  ) async {
    final container = await pumpApp(tester);
    bool saved() => container.read(appSettingsProvider).citationShowTitles;
    check(saved()).isFalse();

    NativeSheetBridge.instance.onControlChanged(
      PlatformNativeSheetControlChangedEvent(
        id: 'citation-show-titles',
        value: 'yes',
      ),
    );
    await tester.pumpAndSettle();
    check(saved()).isFalse();

    NativeSheetBridge.instance.onControlChanged(
      PlatformNativeSheetControlChangedEvent(
        id: 'citation-show-titles',
        value: true,
      ),
    );
    await tester.pumpAndSettle();
    check(saved()).isTrue();
  });

  testWidgets('Licenses open as the sheet closes itself, with no second '
      'dismiss or wait', (tester) async {
    var dismissCalls = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockDecodedMessageHandler<Object?>(_dismissChannel, (_) async {
          dismissCalls++;
          return <Object?>[true];
        });
    await pumpApp(tester);

    NativeSheetBridge.instance.onControlChanged(
      PlatformNativeSheetControlChangedEvent(
        id: NativeSheetRoutes.openSourceLicenses,
        value: true,
      ),
    );
    // The page is pushed straight away, well inside the old fixed delay.
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    expect(find.byType(LicensePage), findsOneWidget);
    check(dismissCalls).equals(0);
  });
}
