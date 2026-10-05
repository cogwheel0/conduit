import 'package:checks/checks.dart';
import 'package:conduit/core/services/native_sheet_bridge.dart';
import 'package:conduit/core/services/native_sheet_hydration_service.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit/platform/conduit_platform_apis.g.dart';
import 'package:conduit/shared/services/navigation_service.dart';
import 'package:conduit/shared/theme/theme_providers.dart';
import 'package:conduit_core/models/model.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/optimized_storage_service.dart';
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
}
