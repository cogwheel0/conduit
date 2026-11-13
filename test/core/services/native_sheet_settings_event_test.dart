import 'dart:async';

import 'package:checks/checks.dart';
import 'package:conduit/l10n/app_localizations.dart';
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
    show chatWakelockCoordinatorProvider;
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
import 'package:material_ui/material_ui.dart' show Scaffold;
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

final AppLocalizations _l10nEn = lookupAppLocalizations(const Locale('en'));

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

final _signedInUser = NotifierProvider<_SignedInUser, User?>(_SignedInUser.new);

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

  testWidgets('native automatic actions persist and reject stale reordering', (
    tester,
  ) async {
    final patches = _recordPatches();
    final container = await pumpApp(tester);
    for (final automatic in [false, true]) {
      NativeSheetBridge.instance.onControlChanged(
        PlatformNativeSheetControlChangedEvent(
          id: 'message-actions-automatic',
          value: automatic,
        ),
      );
      await tester.pumpAndSettle();
      expect(
        container.read(appSettingsProvider).inlineMessageActions,
        automatic ? isNull : defaultInlineMessageActions,
      );
      expect(
        (await SettingsService.loadSettings()).inlineMessageActions,
        automatic ? isNull : defaultInlineMessageActions,
      );
    }
    expect(
      patches.where((patch) => patch.detailId == 'message-actions'),
      hasLength(2),
    );
    NativeSheetBridge.instance.onControlChanged(
      PlatformNativeSheetControlChangedEvent(
        id: 'message-actions-reorder',
        value: [
          'message-action:tts',
          'message-action:copy',
          'message-action:regenerate',
        ],
      ),
    );
    await tester.pumpAndSettle();
    expect(container.read(appSettingsProvider).inlineMessageActions, isNull);
    NativeSheetBridge.instance.onControlChanged(
      PlatformNativeSheetControlChangedEvent(
        id: 'message-action:share',
        value: true,
      ),
    );
    await tester.pumpAndSettle();
    expect(container.read(appSettingsProvider).inlineMessageActions, isNull);
  });

  testWidgets(
    'native message action reordering saves and rejects stale choices',
    (tester) async {
      final patches = _recordPatches();
      final container = await pumpApp(tester);
      await container
          .read(appSettingsProvider.notifier)
          .setInlineMessageActions(defaultInlineMessageActions);
      NativeSheetBridge.instance.onControlChanged(
        PlatformNativeSheetControlChangedEvent(
          id: 'message-actions-reorder',
          value: [
            'message-action:regenerate',
            'message-action:copy',
            'message-action:tts',
          ],
        ),
      );
      await tester.pumpAndSettle();
      expect(container.read(appSettingsProvider).inlineMessageActions, [
        'regenerate',
        'copy',
        'tts',
      ]);
      expect((await SettingsService.loadSettings()).inlineMessageActions, [
        'regenerate',
        'copy',
        'tts',
      ]);
      expect(
        patches.where((patch) => patch.detailId == 'message-actions'),
        isEmpty,
      );
      for (final invalid in [
        ['message-action:share', 'message-action:copy', 'message-action:tts'],
        ['message-action:copy', 'message-action:copy', 'message-action:tts'],
        ['message-action:copy'],
        [
          'message-action:regenerate',
          'message-action:copy',
          'message-action:tts',
          1,
        ],
      ]) {
        NativeSheetBridge.instance.onControlChanged(
          PlatformNativeSheetControlChangedEvent(
            id: 'message-actions-reorder',
            value: invalid,
          ),
        );
        await tester.pumpAndSettle();
        expect(container.read(appSettingsProvider).inlineMessageActions, [
          'regenerate',
          'copy',
          'tts',
        ]);
      }
    },
  );

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
    List<String> rootRows(PlatformNativeSheetApplyDetailPatchRequest patch) => [
      for (final section in patch.sections) ...section.items.map((i) => i.id),
    ];

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
      // The group has no heading, like every root group; its footer says
      // why it is there.
      final advanced = on.sections.singleWhere(
        (s) => s.footer == 'Shown because Advanced is turned on in Chats.',
      );
      check(advanced.title).isNull();
      check(advanced.items.map((i) => i.id))
          .deepEquals([NativeSheetRoutes.personalConnections]);

      NativeSheetBridge.instance.onControlChanged(
        PlatformNativeSheetControlChangedEvent(
          id: 'advanced-features',
          value: false,
        ),
      );
      await tester.pumpAndSettle();

      final off = patches.lastWhere((p) => p.detailId == 'profile-menu');
      check(off.sections.map((s) => s.footer)).not(
        (it) => it.contains('Shown because Advanced is turned on in Chats.'),
      );
      check(rootRows(off))
          .not((it) => it.contains(NativeSheetRoutes.personalConnections));
      // The page of the row it just lost, still open, says why it is closed.
      NativeSheetBridge.instance.onDetailAppeared(
        PlatformNativeSheetDetailAppearedEvent(
          detailId: NativeSheetRoutes.personalConnections,
        ),
      );
      await tester.pumpAndSettle();
      final page = patches.lastWhere(
        (p) => p.detailId == NativeSheetRoutes.personalConnections,
      );
      check(page.items.map((item) => item.title)).deepEquals([
        _l10nEn.advancedRequiredMessage(_l10nEn.personalConnectionsTitle),
      ]);
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
      // Still Ada's: her card first, opening her profile, her own rows
      // after it.
      final card = rebuilt.sections.first.items.first;
      check(card.id).equals(NativeSheetRoutes.profile);
      check(card.title).equals('Ada');
      check(rootRows(rebuilt)).contains(NativeSheetRoutes.notificationSettings);

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

  testWidgets('the native sidebar toggle saves only boolean values', (
    tester,
  ) async {
    final container = await pumpApp(tester);
    expect(container.read(appSettingsProvider).slidingSidebarEnabled, isFalse);
    // A value that is not a boolean leaves the setting as it was, whichever
    // way it was set.
    for (final (value, expected) in [
      ('yes', false),
      (true, true),
      ('no', true),
      (false, false),
    ]) {
      NativeSheetBridge.instance.onControlChanged(
        PlatformNativeSheetControlChangedEvent(
          id: 'sliding-sidebar',
          value: value,
        ),
      );
      await tester.pumpAndSettle();
      expect(
        container.read(appSettingsProvider).slidingSidebarEnabled,
        expected,
      );
    }
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

  testWidgets('the native Computer toggle saves only booleans', (tester) async {
    final container = await pumpApp(tester);
    bool saved() => container.read(appSettingsProvider).computerEnabled;
    check(saved()).isTrue();

    NativeSheetBridge.instance.onControlChanged(
      PlatformNativeSheetControlChangedEvent(
        id: 'computer-enabled',
        value: 'false',
      ),
    );
    await tester.pumpAndSettle();
    check(saved()).isTrue();

    NativeSheetBridge.instance.onControlChanged(
      PlatformNativeSheetControlChangedEvent(
        id: 'computer-enabled',
        value: false,
      ),
    );
    await tester.pumpAndSettle();
    check(saved()).isFalse();
    check((await SettingsService.loadSettings()).computerEnabled).isFalse();
  });

  testWidgets('the native citation background toggle saves only booleans', (
    tester,
  ) async {
    final container = await pumpApp(tester);
    bool saved() => container.read(appSettingsProvider).citationBackground;
    check(saved()).isTrue();

    NativeSheetBridge.instance.onControlChanged(
      PlatformNativeSheetControlChangedEvent(
        id: nativeCitationBackgroundId,
        value: 'false',
      ),
    );
    await tester.pumpAndSettle();
    check(saved()).isTrue();

    NativeSheetBridge.instance.onControlChanged(
      PlatformNativeSheetControlChangedEvent(
        id: nativeCitationBackgroundId,
        value: false,
      ),
    );
    await tester.pumpAndSettle();
    check(saved()).isFalse();
    check((await SettingsService.loadSettings()).citationBackground).isFalse();
  });
}
