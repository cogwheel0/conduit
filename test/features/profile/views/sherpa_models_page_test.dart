import 'dart:io';

import 'package:checks/checks.dart';
import 'package:conduit/core/persistence/persistence_keys.dart';
import 'package:conduit/core/persistence/preferences_store.dart';
import 'package:conduit/core/services/settings_service.dart';
import 'package:conduit/core/services/navigation_service.dart';
import 'package:conduit/core/sherpa/sherpa_catalog.dart';
import 'package:conduit/core/sherpa/sherpa_model.dart';
import 'package:conduit/core/sherpa/sherpa_model_manager.dart';
import 'package:conduit/core/sherpa/sherpa_storage.dart';
import 'package:conduit/features/profile/views/sherpa_models_page.dart';
import 'package:conduit/features/profile/widgets/settings_page_scaffold.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/shared/widgets/conduit_components.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() async {
    PreferencesStore.debugReset();
    SharedPreferences.setMockInitialValues(<String, Object>{});
    PreferencesStore.debugOverride(await SharedPreferences.getInstance());
  });
  tearDown(PreferencesStore.debugReset);

  for (final platform in <TargetPlatform>[
    TargetPlatform.iOS,
    TargetPlatform.android,
  ]) {
    testWidgets('model manager stays usable on compact ${platform.name}', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(320, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appSettingsProvider.overrideWithValue(const AppSettings()),
            sherpaInstalledModelsProvider.overrideWith((ref) async => const []),
            sherpaBrokenModelsProvider.overrideWith((ref) async => const {}),
            sherpaInstallProgressProvider.overrideWith(
              (ref) => Stream.value(const {}),
            ),
          ],
          child: MaterialApp(
            theme: ThemeData(platform: platform),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: const SherpaModelsPage(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      check(find.text('Sherpa ONNX models').evaluate()).length.equals(1);
      check(find.byType(ConduitInput).evaluate()).length.equals(1);
      check(find.text('STT / TTS').evaluate()).length.equals(1);
      check(find.text('Mode').evaluate()).length.equals(1);
      check(tester.takeException()).isNull();

      await tester.tap(find.text('STT / TTS'));
      await tester.pumpAndSettle();

      check(find.byType(SettingsSelectorSheet).evaluate()).length.equals(1);
      check(find.text('Any').evaluate()).length.equals(1);
      check(find.text('STT').evaluate()).length.equals(1);
      check(find.text('TTS').evaluate()).length.equals(1);
      check(tester.takeException()).isNull();
    });
  }

  for (final selection in <({bool forTts, String title})>[
    (forTts: false, title: 'Choose a speech model'),
    (forTts: true, title: 'Choose a voice model'),
  ]) {
    testWidgets('${selection.title} locks the kind and pops after activation', (
      tester,
    ) async {
      final kind = selection.forTts ? SherpaModelKind.tts : SherpaModelKind.stt;
      final model = sherpaModelCatalog.firstWhere(
        (candidate) => candidate.kind == kind,
      );
      final installed = InstalledSherpaModel(
        model: model,
        directory: Directory('/unused'),
        installedBytes: model.installedBytes,
      );
      final router = GoRouter(
        routes: [
          GoRoute(
            path: '/',
            builder: (context, state) =>
                const Scaffold(body: Text('Audio settings placeholder')),
          ),
          GoRoute(
            path: Routes.sherpaModels,
            builder: (context, state) {
              final selectionKind = switch (state.uri.queryParameters['kind']) {
                'stt' => SherpaModelKind.stt,
                'tts' => SherpaModelKind.tts,
                _ => null,
              };
              return SherpaModelsPage(selectionKind: selectionKind);
            },
          ),
        ],
      );
      addTearDown(router.dispose);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            sherpaInstalledModelsProvider.overrideWith(
              (ref) async => [installed],
            ),
            sherpaBrokenModelsProvider.overrideWith((ref) async => const {}),
            sherpaInstallProgressProvider.overrideWith(
              (ref) => Stream.value(const {}),
            ),
          ],
          child: MaterialApp.router(
            theme: ThemeData(platform: TargetPlatform.iOS),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            routerConfig: router,
          ),
        ),
      );
      await tester.pumpAndSettle();

      router.push(Routes.sherpaModelsFor(forTts: selection.forTts));
      await tester.pumpAndSettle();

      check(find.text(selection.title).evaluate()).length.equals(1);
      check(find.text('STT / TTS').evaluate()).isEmpty();
      final useButton = find.widgetWithText(ConduitButton, 'Use');
      check(useButton.evaluate()).length.equals(1);

      await tester.tap(useButton);
      await tester.pumpAndSettle();

      check(
        find.text('Audio settings placeholder').evaluate(),
      ).length.equals(1);
      check(find.text(selection.title).evaluate()).isEmpty();
      if (model.supportsAutomaticLanguage && model.languages.length > 1) {
        check(
          PreferencesStore.containsKey(PreferenceKeys.sherpaSttLanguageCode),
        ).isFalse();
      }
      check(tester.takeException()).isNull();
    });
  }
}
