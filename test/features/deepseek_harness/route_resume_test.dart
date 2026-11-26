import 'package:conduit/core/router/app_router.dart';
import 'package:conduit/features/deepseek_harness/deepseek_harness_page.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit/shared/services/navigation_service.dart'
    show NavigationService;
import 'package:conduit_core/navigation/routes.dart';
import 'package:conduit_core/persistence/persistence_keys.dart';
import 'package:conduit_core/persistence/preferences_store.dart';
import 'package:conduit_core/ports/key_value_store.dart';
import 'package:conduit_core/ports/secure_key_value_store.dart';
import 'package:conduit_core/providers/storage_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

// Route redirects have their own policy tests. Keep account boot and server
// IO out of this check of the real router's entry/exit callbacks.
class _AccountlessRouter extends ChangeNotifier implements RouterNotifier {
  @override
  String? redirect(BuildContext context, GoRouterState state) =>
      state.uri.path == Routes.splash ? Routes.backendChooser : null;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  testWidgets('selecting Harness resumes it on restart until the user leaves', (
    tester,
  ) async {
    addTearDown(NavigationService.preserveStateForTest());
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(405, 915);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    PreferencesStore.debugOverride(InMemoryKeyValueStore());
    addTearDown(PreferencesStore.debugReset);

    Future<GoRouter> launch() async {
      final container = ProviderContainer(
        overrides: [
          secureStorageProvider.overrideWithValue(
            InMemorySecureKeyValueStore(),
          ),
          routerNotifierProvider.overrideWithValue(_AccountlessRouter()),
        ],
      );
      addTearDown(container.dispose);
      final router = container.read(goRouterProvider);
      addTearDown(router.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp.router(
            routerConfig: router,
            localizationsDelegates: conduitLocalizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
          ),
        ),
      );
      await tester.pumpAndSettle();
      return router;
    }

    final chooserRouter = await launch();
    final entry = find.byKey(const Key('backend-chooser-deepseek-harness'));
    await tester.ensureVisible(entry);
    await tester.pumpAndSettle();
    await tester.tap(entry);
    await tester.pumpAndSettle();
    final page = tester.widget<DeepSeekHarnessPage>(
      find.byType(DeepSeekHarnessPage),
    );
    expect(chooserRouter.state.matchedLocation, Routes.deepSeekHarness);
    expect(
      PreferencesStore.getBool(PreferenceKeys.resumeDeepSeekHarness),
      isNot(true),
    );
    await page.onConnected();
    expect(
      PreferencesStore.getBool(PreferenceKeys.resumeDeepSeekHarness),
      isTrue,
    );

    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    final resumedRouter = await launch();
    expect(resumedRouter.state.matchedLocation, Routes.deepSeekHarness);
    tester
        .widget<DeepSeekHarnessPage>(find.byType(DeepSeekHarnessPage))
        .onExit();
    await tester.pumpAndSettle();
    expect(resumedRouter.state.matchedLocation, Routes.backendChooser);
    expect(
      PreferencesStore.getBool(PreferenceKeys.resumeDeepSeekHarness),
      isNot(true),
    );
  });
}
