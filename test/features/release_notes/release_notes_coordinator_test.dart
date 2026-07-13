import 'package:conduit/core/persistence/persistence_keys.dart';
import 'package:conduit/core/persistence/preferences_store.dart';
import 'package:conduit/core/providers/app_providers.dart';
import 'package:conduit/core/services/navigation_service.dart';
import 'package:conduit/features/auth/providers/unified_auth_providers.dart';
import 'dart:convert';

import 'package:conduit/features/release_notes/data/release_notes_repository.dart';
import 'package:conduit/features/release_notes/release_notes_coordinator.dart';
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

  testWidgets('authenticated update shows release notes once', (tester) async {
    SharedPreferences.setMockInitialValues({
      PreferenceKeys.lastSeenReleaseVersion: '3.3.1',
    });
    PreferencesStore.debugOverride(await SharedPreferences.getInstance());

    await tester.pumpWidget(_app(authState: AuthNavigationState.authenticated));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text("What's new"), findsOneWidget);
    expect(find.text('A more private way to share updates'), findsOneWidget);
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

  testWidgets('authenticated iOS update offers the donation link', (
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
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text("What's new"), findsOneWidget);
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
}) {
  return ProviderScope(
    overrides: [
      authNavigationStateProvider.overrideWithValue(authState),
      packageInfoProvider.overrideWith(
        (ref) async => PackageInfo(
          appName: 'Conduit',
          packageName: 'app.cogwheel.conduit',
          version: '3.3.2',
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
        child: const Scaffold(body: Text('Home')),
      ),
    ),
  );
}
