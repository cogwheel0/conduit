import 'package:checks/checks.dart';
import 'package:conduit/core/services/native_sheet_bridge.dart';
import 'package:conduit/core/services/native_sheet_hydration_service.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit/platform/conduit_platform_apis.g.dart';
import 'package:conduit/shared/services/navigation_service.dart';
import 'package:conduit/shared/theme/theme_providers.dart';
import 'package:conduit/platform/flutter_key_value_store.dart';
import 'package:conduit_core/models/model.dart';
import 'package:conduit_core/persistence/preferences_store.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/optimized_storage_service.dart';
import 'package:conduit_core/services/settings_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';

class _MockOptimizedStorageService extends Mock
    implements OptimizedStorageService {}

final _applyDetailPatchChannel = BasicMessageChannel<Object?>(
  'dev.flutter.pigeon.conduit.NativeSheetHostApi.applyDetailPatch',
  NativeSheetHostApi.pigeonChannelCodec,
);

class _NoModels extends Models {
  @override
  Future<List<Model>> build() async => const <Model>[];
}

class _FailingModels extends Models {
  @override
  Future<List<Model>> build() async => throw StateError('server unreachable');
}

/// A root that follows [appLocaleProvider] the way `ConduitApp` does.
class _LocalizedRoot extends ConsumerWidget {
  const _LocalizedRoot();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return MaterialApp(
      navigatorKey: NavigationService.navigatorKey,
      locale: ref.watch(appLocaleProvider),
      localizationsDelegates: conduitLocalizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: const SizedBox.shrink(),
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    NativeSheetBridge.instance.debugIsIOSOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockDecodedMessageHandler<Object?>(_applyDetailPatchChannel, null);
  });

  testWidgets('the native Appearance detail is rebuilt in the new language', (
    tester,
  ) async {
    NativeSheetBridge.instance.debugIsIOSOverride = true;
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

    final storage = _MockOptimizedStorageService();
    when(storage.getThemeMode).thenReturn(null);
    when(storage.getThemePaletteId).thenReturn(null);
    when(storage.getLocaleCode).thenReturn(null);
    when(storage.getReviewerMode).thenAnswer((_) async => false);
    when(() => storage.setLocaleCode(any())).thenAnswer((_) async {});
    final container = ProviderContainer(
      overrides: [
        optimizedStorageServiceProvider.overrideWithValue(storage),
        modelsProvider.overrideWith(_NoModels.new),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const _LocalizedRoot(),
      ),
    );
    await tester.pump();

    final service = container.read(nativeSheetHydrationServiceProvider);
    final english = AppLocalizations.of(NavigationService.context!)!;
    // The user opened Appearance in the native sheet and picked Spanish there.
    final opened = service.hydrateDetail(NativeSheetRoutes.appearance);
    await tester.pump();
    await opened;
    patches.clear();

    await container
        .read(appLocaleProvider.notifier)
        .setLocale(const Locale('es'));
    // The rebuild waits for the frame that switches the app to Spanish.
    await tester.pump();
    await tester.pump();

    final spanish = AppLocalizations.of(NavigationService.context!)!;
    check(spanish.settingsAppearance).not((it) => it.equals('Appearance'));
    final appearance = patches.where((p) => p.detailId == 'appearance');
    check(appearance).isNotEmpty();
    check(appearance.last.title).equals(spanish.settingsAppearance);
    check(appearance.last.title)
        .not((it) => it.equals(english.settingsAppearance));
  });

  testWidgets('Appearance keeps its pickers when the models request fails', (
    tester,
  ) async {
    NativeSheetBridge.instance.debugIsIOSOverride = true;
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

    final storage = _MockOptimizedStorageService();
    when(storage.getThemeMode).thenReturn(null);
    when(storage.getThemePaletteId).thenReturn(null);
    when(storage.getLocaleCode).thenReturn(null);
    when(storage.getReviewerMode).thenAnswer((_) async => false);
    final container = ProviderContainer(
      overrides: [
        optimizedStorageServiceProvider.overrideWithValue(storage),
        modelsProvider.overrideWith(_FailingModels.new),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const _LocalizedRoot(),
      ),
    );
    await tester.pump();

    final service = container.read(nativeSheetHydrationServiceProvider);
    final opened = service.hydrateDetail(NativeSheetRoutes.appearance);
    await tester.pump();
    await opened;

    final appearance = patches.where((p) => p.detailId == 'appearance');
    check(appearance).length.equals(1);
    final ids = [
      for (final section in appearance.single.sections)
        for (final item in section.items) item.id,
    ];
    check(ids).containsEqualInOrder(['theme-light', 'theme-palette']);
    check(ids).contains('language');
    // The pages that do need the server show the error instead.
    check(patches.where((p) => p.detailId == 'chats')).isNotEmpty();
  });

  group('Chats advanced toggle', () {
    setUp(() async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      PreferencesStore.debugOverride(await FlutterKeyValueStore.load());
    });

    tearDown(PreferencesStore.debugReset);

    Future<
      ({
        ProviderContainer container,
        NativeSheetHydrationService service,
        List<PlatformNativeSheetApplyDetailPatchRequest> patches,
      })
    >
    openNativeSettings(
      WidgetTester tester, {
      required Models Function() models,
    }) async {
      NativeSheetBridge.instance.debugIsIOSOverride = true;
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
      final storage = _MockOptimizedStorageService();
      when(storage.getThemeMode).thenReturn(null);
      when(storage.getThemePaletteId).thenReturn(null);
      when(storage.getLocaleCode).thenReturn(null);
      when(storage.getReviewerMode).thenAnswer((_) async => false);
      final container = ProviderContainer(
        overrides: [
          optimizedStorageServiceProvider.overrideWithValue(storage),
          modelsProvider.overrideWith(models),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const _LocalizedRoot(),
        ),
      );
      await tester.pump();
      return (
        container: container,
        service: container.read(nativeSheetHydrationServiceProvider),
        patches: patches,
      );
    }

    Future<PlatformNativeSheetApplyDetailPatchRequest> reopenChats(
      WidgetTester tester,
      NativeSheetHydrationService service,
      List<PlatformNativeSheetApplyDetailPatchRequest> patches,
    ) async {
      patches.clear();
      final opened = service.hydrateDetail(NativeSheetRoutes.chats);
      await tester.pump();
      await opened;
      return patches.lastWhere((p) => p.detailId == 'chats');
    }

    List<PlatformNativeSheetItem> rows(
      PlatformNativeSheetApplyDetailPatchRequest patch,
    ) => [for (final section in patch.sections) ...section.items];

    testWidgets('is off on first open and follows the saved preference', (
      tester,
    ) async {
      final native = await openNativeSettings(tester, models: _NoModels.new);
      final l10n = AppLocalizations.of(NavigationService.context!)!;

      final first = await reopenChats(tester, native.service, native.patches);
      final row = rows(first).singleWhere((r) => r.id == 'advanced-features');
      check(row.title).equals(l10n.advancedFeatures);
      check(row.subtitle).equals(l10n.advancedFeaturesDescription);
      check(row.kind).equals(PlatformNativeSheetItemKind.toggle);
      check(row.value).equals(false);
      // Existing rows keep their place and the account-only prompt row stays
      // hidden for an accountless session.
      check(rows(first).map((r) => r.id)).containsEqualInOrder([
        'default-model',
        'send-on-enter',
        'temporary-chat-default',
        'advanced-features',
      ]);

      await native.container
          .read(appSettingsProvider.notifier)
          .setAdvancedFeaturesEnabled(true);
      final reopened = await reopenChats(
        tester,
        native.service,
        native.patches,
      );
      check(
        rows(reopened).singleWhere((r) => r.id == 'advanced-features').value,
      ).equals(true);
    });

    testWidgets('stays available when the models request fails', (
      tester,
    ) async {
      final native = await openNativeSettings(
        tester,
        models: _FailingModels.new,
      );
      await native.container
          .read(appSettingsProvider.notifier)
          .setAdvancedFeaturesEnabled(true);
      final l10n = AppLocalizations.of(NavigationService.context!)!;

      final chats = await reopenChats(tester, native.service, native.patches);

      final byId = {for (final row in rows(chats)) row.id: row};
      check(byId['advanced-features']!.value).equals(true);
      check(byId['send-on-enter']).isNotNull();
      check(byId['temporary-chat-default']).isNotNull();
      check(byId['chats-error']!.title)
          .equals(l10n.unableToLoadOpenWebuiSettings);
    });
  });
}
