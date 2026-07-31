import 'package:conduit/core/persistence/persistence_keys.dart';
import 'package:conduit/core/persistence/preferences_store.dart';
import 'package:conduit/core/providers/app_providers.dart';
import 'package:conduit/core/providers/backend_mode_providers.dart';
import 'package:conduit/core/services/navigation_service.dart';
import 'package:conduit/features/auth/providers/unified_auth_providers.dart';
import 'dart:convert';

import 'package:conduit/features/release_notes/data/release_notes_repository.dart';
import 'package:conduit/features/release_notes/release_notes_bootstrap.dart';
import 'package:conduit/features/release_notes/release_notes_coordinator.dart';
import 'package:conduit/features/release_notes/widgets/release_notes_banner.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    PreferencesStore.debugReset();
    PreferencesStore.debugOverride(await SharedPreferences.getInstance());
  });

  tearDown(() {
    PreferencesStore.debugReset();
  });

  testWidgets('fresh install stores current version and does not show sheet', (
    tester,
  ) async {
    await tester.pumpWidget(_app(authState: AuthNavigationState.authenticated));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text("What's new"), findsNothing);
    expect(
      PreferencesStore.getString(PreferenceKeys.lastSeenReleaseVersion),
      '3.3.2',
    );
  });

  testWidgets('fresh 4.0 install does not show the 4.0 update sheet', (
    tester,
  ) async {
    await captureReleaseNotesInstallProvenance();
    expect(
      PreferencesStore.getBool(
        PreferenceKeys.releaseNotesExistingInstallAtBootstrap,
      ),
      isFalse,
    );
    // Onboarding configures the install after startup; provenance must remain
    // fresh so that first-time users do not receive an update popup.
    await PreferencesStore.put(
      PreferenceKeys.activeServerId,
      'newly-configured-server',
    );

    await tester.pumpWidget(
      _app(
        authState: AuthNavigationState.authenticated,
        packageVersion: '4.0.0',
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text("What's new"), findsNothing);
    expect(
      PreferencesStore.getString(PreferenceKeys.lastSeenReleaseVersion),
      '4.0.0',
    );
  });

  testWidgets('existing install with no marker shows the first 4.0 banner', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      PreferenceKeys.activeServerId: 'existing-server',
    });
    PreferencesStore.debugOverride(await SharedPreferences.getInstance());
    await captureReleaseNotesInstallProvenance();
    expect(
      PreferencesStore.getBool(
        PreferenceKeys.releaseNotesExistingInstallAtBootstrap,
      ),
      isTrue,
    );

    await tester.pumpWidget(
      _app(
        authState: AuthNavigationState.authenticated,
        packageVersion: '4.0.0',
        showBanner: true,
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('Conduit 4.0 is here'), findsOneWidget);
    expect(find.text("What's new"), findsNothing);
    expect(find.text('Welcome to Conduit 4.0.'), findsNothing);
  });

  for (final backend in [PreferredBackend.direct, PreferredBackend.hermes]) {
    testWidgets('${backend.name} update shows without Open WebUI auth', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({
        PreferenceKeys.lastSeenReleaseVersion: '3.3.1',
        PreferenceKeys.preferredBackend: backend.name,
        if (backend == PreferredBackend.direct)
          PreferenceKeys.directConnectionsConfigured: true,
        if (backend == PreferredBackend.hermes)
          PreferenceKeys.hermesEnabled: true,
      });
      PreferencesStore.debugOverride(await SharedPreferences.getInstance());

      await tester.pumpWidget(
        _app(authState: AuthNavigationState.needsLogin, showBanner: true),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('Conduit 3.3 is here'), findsOneWidget);
      expect(find.text("What's new"), findsNothing);
    });
  }

  testWidgets('does not show before the user is authenticated', (tester) async {
    SharedPreferences.setMockInitialValues({
      PreferenceKeys.lastSeenReleaseVersion: '3.3.1',
    });
    PreferencesStore.debugOverride(await SharedPreferences.getInstance());

    await tester.pumpWidget(_app(authState: AuthNavigationState.needsLogin));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text("What's new"), findsNothing);
    expect(
      PreferencesStore.getString(PreferenceKeys.lastSeenReleaseVersion),
      '3.3.1',
    );
  });

  testWidgets('authenticated update shows banner without opening sheet', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      PreferenceKeys.lastSeenReleaseVersion: '3.3.1',
    });
    PreferencesStore.debugOverride(await SharedPreferences.getInstance());

    await tester.pumpWidget(
      _app(authState: AuthNavigationState.authenticated, showBanner: true),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('Conduit 3.3 is here'), findsOneWidget);
    expect(find.text("What's new"), findsNothing);
    expect(find.text('Hi, this update is bundled with the app.'), findsNothing);
    expect(find.text('Done'), findsNothing);

    expect(
      PreferencesStore.getString(PreferenceKeys.lastSeenReleaseVersion),
      '3.3.2',
    );
  });

  testWidgets('banner opens the sheet and remains until explicitly closed', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      PreferenceKeys.lastSeenReleaseVersion: '3.3.1',
    });
    PreferencesStore.debugOverride(await SharedPreferences.getInstance());

    await tester.pumpWidget(
      _app(authState: AuthNavigationState.authenticated, showBanner: true),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpAndSettle();

    expect(find.byKey(releaseNotesBannerKey), findsOneWidget);
    expect(find.text('Conduit 3.3 is here'), findsOneWidget);
    expect(find.text("What's new"), findsNothing);
    expect(find.text('Done'), findsNothing);
    expect(
      PreferencesStore.getString(
        PreferenceKeys.releaseNotesBannerPreviousVersion,
      ),
      '3.3.1',
    );

    await tester.tap(find.byKey(releaseNotesBannerKey));
    await tester.pumpAndSettle();
    expect(
      find.text('Hi, this update is bundled with the app.'),
      findsOneWidget,
    );
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(releaseNotesBannerCloseKey));
    await tester.pumpAndSettle();
    expect(find.byKey(releaseNotesBannerKey), findsNothing);
    expect(
      PreferencesStore.getString(
        PreferenceKeys.releaseNotesBannerPreviousVersion,
      ),
      isNull,
    );
  });

  testWidgets('undismissed chat banner is restored on the next launch', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      PreferenceKeys.lastSeenReleaseVersion: '3.3.2',
      PreferenceKeys.releaseNotesBannerPreviousVersion: '3.3.1',
    });
    PreferencesStore.debugOverride(await SharedPreferences.getInstance());

    await tester.pumpWidget(
      _app(authState: AuthNavigationState.authenticated, showBanner: true),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpAndSettle();

    expect(find.byKey(releaseNotesBannerKey), findsOneWidget);
    expect(find.text('Conduit 3.3 is here'), findsOneWidget);
    expect(find.text('Hi, this update is bundled with the app.'), findsNothing);
  });

  testWidgets('authenticated iOS banner opens the donation link sheet', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      PreferenceKeys.lastSeenReleaseVersion: '3.3.1',
    });
    PreferencesStore.debugOverride(await SharedPreferences.getInstance());

    await tester.pumpWidget(
      _app(
        authState: AuthNavigationState.authenticated,
        platform: TargetPlatform.iOS,
        showBanner: true,
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('Conduit 3.3 is here'), findsOneWidget);
    expect(find.text("What's new"), findsNothing);
    expect(find.text('Buy Me a Coffee'), findsNothing);

    await tester.tap(find.byKey(releaseNotesBannerKey));
    await tester.pumpAndSettle();

    expect(find.text('Conduit 3.3 is here'), findsNWidgets(2));
    expect(find.text('Buy Me a Coffee'), findsOneWidget);
    expect(find.text('GitHub Sponsors'), findsNothing);

    await tester.pumpAndSettle();
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();

    expect(
      PreferencesStore.getString(PreferenceKeys.lastSeenReleaseVersion),
      '3.3.2',
    );
  });
}

class _FakeNotesBundle extends CachingAssetBundle {
  static const _document = {
    'notes': [
      {
        'version': '3.3.2',
        'title': 'A more private way to share updates',
        'intro': 'Hi, this update is bundled with the app.',
        'bullets': [
          {'text': 'Baked changelog'},
          {'text': 'Localized copy'},
        ],
      },
      {
        'version': '4.0.0',
        'title': 'Conduit 4.0',
        'intro': 'Welcome to Conduit 4.0.',
        'bullets': [
          {'text': 'Local-first chats'},
          {'text': 'Direct and Hermes backends'},
        ],
      },
    ],
  };

  @override
  Future<ByteData> load(String key) async {
    if (key == 'assets/release_notes/en.json') {
      return ByteData.sublistView(
        Uint8List.fromList(utf8.encode(jsonEncode(_document))),
      );
    }
    throw FlutterError('missing asset: $key');
  }
}

Widget _app({
  required AuthNavigationState authState,
  TargetPlatform platform = TargetPlatform.android,
  bool showBanner = false,
  String packageVersion = '3.3.2',
}) {
  return ProviderScope(
    overrides: [
      authNavigationStateProvider.overrideWithValue(authState),
      packageInfoProvider.overrideWith(
        (ref) async => PackageInfo(
          appName: 'Conduit',
          packageName: 'app.cogwheel.conduit',
          version: packageVersion,
          buildNumber: '132',
        ),
      ),
    ],
    child: MaterialApp(
      theme: ThemeData(platform: platform),
      navigatorKey: NavigationService.navigatorKey,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: ReleaseNotesCoordinator(
        repository: ReleaseNotesRepository(bundle: _FakeNotesBundle()),
        child: Scaffold(
          body: showBanner
              ? const Column(children: [Text('Home'), ReleaseNotesBanner()])
              : const Text('Home'),
        ),
      ),
    ),
  );
}
