import 'dart:async';

import 'package:checks/checks.dart';
import 'package:conduit/core/services/native_sheet_bridge.dart';
import 'package:conduit/core/services/native_sheet_hydration_service.dart';
import 'package:conduit/features/chat/providers/text_to_speech_provider.dart';
import 'package:conduit/features/chat/services/text_to_speech_service.dart';
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

/// Speech settings whose voices never finish loading.
class _QuietTextToSpeechService extends Fake implements TextToSpeechService {
  @override
  Future<void> updateSettings({
    Object? voice,
    Object? serverVoice,
    double? speed,
    double? pitch,
    double? volume,
    TtsEngine? engine,
  }) async {}

  @override
  Future<List<Map<String, dynamic>>> getAvailableVoices() =>
      Completer<List<Map<String, dynamic>>>().future;
}

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
    final themeGroup = appearance.last.sections.singleWhere(
      (section) => section.items.any((row) => row.id == 'citation-background'),
    );
    final citationBackground = themeGroup.items.singleWhere(
      (row) => row.id == 'citation-background',
    );
    check(citationBackground.title).equals(spanish.citationBackground);
    // Explained in its group's footer, as Settings does, not under its title.
    check(citationBackground.subtitle).isNull();
    check(themeGroup.footer).equals(spanish.citationBackgroundDescription);
    check(citationBackground.kind).equals(PlatformNativeSheetItemKind.toggle);
    check(citationBackground.value).equals(true);
  });

  testWidgets('a language picked on the Settings root rebuilds the root in '
      'that language', (tester) async {
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

    // The root is up, and Appearance was never opened.
    final service = container.read(nativeSheetHydrationServiceProvider);
    service.rememberProfileRoot(null);

    await container
        .read(appLocaleProvider.notifier)
        .setLocale(const Locale('es'));
    await tester.pump();
    await tester.pump();

    final spanish = AppLocalizations.of(NavigationService.context!)!;
    check(patches.where((p) => p.detailId == 'appearance')).isEmpty();
    final root = patches.lastWhere(
      (p) => p.detailId == NativeSheetRoutes.profileMenu,
    );
    final language = root.sections
        .expand((section) => section.items)
        .singleWhere((row) => row.id == 'language');
    check(language.title).equals(spanish.appLanguage);
    check(language.value).equals('es');
  });

  testWidgets('the Voice provider page is patched alone, without the voices', (
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
        modelsProvider.overrideWith(_NoModels.new),
        textToSpeechServiceProvider.overrideWithValue(
          _QuietTextToSpeechService(),
        ),
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
    final refreshed = service.hydrateDetail(NativeSheetRoutes.voiceProvider);
    await tester.pump();
    await refreshed;

    // iOS redraws only the page a patch is for, and the speech voices this
    // page does not show are not waited for while the user types.
    check(patches.last.detailId).equals(NativeSheetRoutes.voiceProvider);
    check(patches.last.detailSheets ?? const []).isEmpty();
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
        appSettingsProvider.overrideWithValue(
          const AppSettings(showComposerNotesButton: false),
        ),
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
    // The color scheme as tiles on its own, palette and citation shading in
    // the next group, the sidebar in the last. The Notes button lives in
    // Chats, and the language is a row of the Settings root.
    check(ids).deepEquals([
      'theme-light',
      'theme-palette',
      'citation-background',
      'sliding-sidebar',
    ]);
    check([
      for (final section in appearance.single.sections) section.items.length,
    ]).deepEquals([1, 2, 1]);
    // Each scheme previews itself in the palette in use -- background, ink,
    // fill and border -- and System shows the light and the dark screen.
    final scheme = appearance.single.sections.first.items.single;
    check(scheme.kind).equals(PlatformNativeSheetItemKind.appearanceTiles);
    check([for (final o in scheme.options) o.id])
        .deepEquals(['system', 'light', 'dark']);
    for (final option in scheme.options) {
      check(option.swatchesArgb).isNotNull().length.equals(4);
    }
    final [system, light, dark] = scheme.options;
    check(system.darkSwatchesArgb).isNotNull().length.equals(4);
    check(light.darkSwatchesArgb).isNull();
    check(dark.darkSwatchesArgb).isNull();
    check(light.swatchesArgb).isNotNull().deepEquals(system.swatchesArgb!);
    check(dark.swatchesArgb).isNotNull().deepEquals(system.darkSwatchesArgb!);
    // Conduit's light screen is white with black ink; its dark one the
    // reverse.
    check(Color(light.swatchesArgb!.first)).equals(const Color(0xFFFFFFFF));
    check(Color(dark.swatchesArgb!.first)).equals(const Color(0xFF000000));
    final sidebarGroup = appearance.single.sections.singleWhere(
      (section) => section.items.any((item) => item.id == 'sliding-sidebar'),
    );
    check(sidebarGroup.items.single.value).equals(false);
    check(sidebarGroup.items.single.subtitle).isNull();
    check(sidebarGroup.footer).isNotNull();
    // Every palette previews itself as one swatch, its primary, in both
    // appearances, and Conduit's reads as the monochrome palette it is.
    final palette = appearance.single.sections
        .expand((section) => section.items)
        .singleWhere((item) => item.id == 'theme-palette');
    check(palette.options).isNotEmpty();
    for (final option in palette.options) {
      check(option.swatchesArgb).isNotNull().length.equals(1);
      check(option.darkSwatchesArgb).isNotNull().length.equals(1);
    }
    final conduit = palette.options.singleWhere(
      (option) => option.id == 'conduit',
    );
    for (final argb in [
      ...conduit.swatchesArgb!,
      ...conduit.darkSwatchesArgb!,
    ]) {
      final color = Color(argb);
      check(color.r).equals(color.g);
      check(color.g).equals(color.b);
    }
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

    testWidgets('Chat reflects the saved Computer preference', (tester) async {
      final native = await openNativeSettings(tester, models: _NoModels.new);
      await native.container
          .read(appSettingsProvider.notifier)
          .setComputerEnabled(false);
      final chats = await reopenChats(tester, native.service, native.patches);
      final row = rows(chats)
          .singleWhere((row) => row.id == 'computer-enabled');
      check(row.value).equals(false);
      check(row.title).equals('Computer');
      // The outline display, as the rows around it are outline glyphs.
      check(row.sfSymbol).equals('display');
      await native.container
          .read(appSettingsProvider.notifier)
          .setComputerEnabled(true);
      final reopened = await reopenChats(
        tester,
        native.service,
        native.patches,
      );
      check(
        rows(reopened).singleWhere((row) => row.id == 'computer-enabled').value,
      ).equals(true);
    });

    testWidgets('Appearance reflects the saved citation background', (
      tester,
    ) async {
      final native = await openNativeSettings(tester, models: _NoModels.new);
      await native.container
          .read(appSettingsProvider.notifier)
          .setCitationBackground(false);
      final opened = native.service.hydrateDetail(NativeSheetRoutes.appearance);
      await tester.pump();
      await opened;
      final appearance = native.patches.lastWhere(
        (patch) => patch.detailId == NativeSheetRoutes.appearance,
      );
      check(
        rows(appearance)
            .singleWhere((row) => row.id == 'citation-background')
            .value,
      ).equals(false);
    });

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

    testWidgets('sits alone in the last group, explained by its footer', (
      tester,
    ) async {
      final native = await openNativeSettings(tester, models: _NoModels.new);
      final l10n = AppLocalizations.of(NavigationService.context!)!;

      final chats = await reopenChats(tester, native.service, native.patches);

      expect(
        chats.detailSheets?.any((detail) => detail.id == 'message-actions'),
        isTrue,
      );
      final advanced = chats.sections.last;
      check(advanced.footer).equals(l10n.advancedFeaturesFooter);
      check(advanced.items.map((r) => r.id)).deepEquals(['advanced-features']);
      check(advanced.items.single.sfSymbol).equals('gearshape.2');
      // The citation titles toggle joins the chat behavior group, as on the
      // Flutter Chat page.
      final citation = rows(chats)
          .singleWhere((r) => r.id == 'citation-show-titles');
      check(citation.title).equals(l10n.citationShowTitles);
      check(citation.kind).equals(PlatformNativeSheetItemKind.toggle);
      check(citation.value).equals(false);
      // Message actions is a page, so it sits with the other pages; the
      // toggles follow, the message field's first.
      check(
        chats.sections
            .firstWhere((s) => s.items.any((r) => r.id == 'message-actions'))
            .items
            .last
            .id,
      ).equals('message-actions');
      check(
        chats.sections
            .firstWhere((s) => s.items.any((r) => r.id == 'send-on-enter'))
            .items
            .map((r) => r.id),
      ).deepEquals([
        'send-on-enter',
        'composer-notes-button',
        'composer-model-name',
      ]);
      check(
        chats.sections
            .firstWhere(
              (s) => s.items.any((r) => r.id == 'temporary-chat-default'),
            )
            .items
            .map((r) => r.id),
      ).deepEquals([
        'computer-enabled',
        'temporary-chat-default',
        'citation-show-titles',
        'disable-haptics-streaming',
      ]);
      final notes = rows(chats)
          .singleWhere((r) => r.id == 'composer-notes-button');
      check(notes.title).equals(l10n.showComposerNotesButton);
      check(notes.kind).equals(PlatformNativeSheetItemKind.toggle);
      final modelName = rows(
        chats,
      ).singleWhere((r) => r.id == 'composer-model-name');
      check(modelName.title).equals(l10n.showModelNameInComposer);
      check(modelName.kind).equals(PlatformNativeSheetItemKind.toggle);
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
      expect(
        chats.detailSheets?.any((detail) => detail.id == 'message-actions'),
        isTrue,
      );
      check(byId['advanced-features']!.value).equals(true);
      check(byId['send-on-enter']).isNotNull();
      check(byId['temporary-chat-default']).isNotNull();
      check(byId['chats-error']!.title)
          .equals(l10n.unableToLoadOpenWebuiSettings);
      // Advanced keeps its own last group beside the error.
      check(chats.sections.last.footer).equals(l10n.advancedFeaturesFooter);
      check(chats.sections.last.items.single.id).equals('advanced-features');
    });
  });
}
