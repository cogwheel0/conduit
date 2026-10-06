import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:conduit_core/models/model.dart';
import 'package:conduit_core/models/socket_transport_availability.dart';
import 'package:conduit_core/models/tool.dart';
import 'package:conduit_core/persistence/persistence_keys.dart';
import 'package:conduit_core/persistence/preferences_store.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/optimized_storage_service.dart';
import 'package:conduit_core/services/settings_service.dart';
import 'package:conduit/features/profile/views/app_customization_page.dart';
import 'package:conduit/platform/flutter_key_value_store.dart';
import 'package:conduit_core/features/tools/providers/tools_providers.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';

void main() {
  testWidgets('Appearance contains only display and language settings', (
    tester,
  ) async {
    await tester.pumpWidget(
      _sectionHarness(AppCustomizationSection.appearance),
    );
    await tester.pumpAndSettle();

    expect(find.text('Appearance'), findsOneWidget);
    expect(find.text('Display'), findsNothing);
    expect(find.text('App Language'), findsWidgets);
    expect(find.text('Quick actions in chat'), findsNothing);
    expect(find.text('Send with Enter'), findsNothing);
    expect(find.text('Transport mode'), findsNothing);
  });

  testWidgets('direct-only Chat hides server-backed prompt settings', (
    tester,
  ) async {
    await tester.pumpWidget(_sectionHarness(AppCustomizationSection.chat));
    await tester.pumpAndSettle();

    expect(find.text('Chat'), findsWidgets);
    expect(find.text('Send with Enter'), findsOneWidget);
    expect(find.text('Start temporary chats'), findsOneWidget);
    expect(find.text('Advanced prompt overrides'), findsNothing);
    expect(find.text('App Language'), findsNothing);
    expect(find.text('Transport mode'), findsNothing);
  });

  testWidgets('Open WebUI Chat opens quick actions without ListTile error', (
    tester,
  ) async {
    await tester.pumpWidget(
      _sectionHarness(AppCustomizationSection.chat, hasOpenWebUiAccount: true),
    );
    await tester.pumpAndSettle();

    expect(find.text('Quick actions in chat'), findsOneWidget);
    await tester.tap(find.text('Quick actions in chat'));
    await tester.pumpAndSettle();

    expect(find.text('Web'), findsOneWidget);
    expect(find.text('Image Gen'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Open WebUI Chat exposes advanced prompt settings', (
    tester,
  ) async {
    await tester.pumpWidget(
      _sectionHarness(AppCustomizationSection.chat, hasOpenWebUiAccount: true),
    );
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(
      find.text('Advanced prompt overrides'),
      300,
    );
    expect(find.text('Advanced prompt overrides'), findsOneWidget);
  });

  testWidgets('Chat toggles the persisted Advanced preference', (tester) async {
    addTearDown(PreferencesStore.debugReset);
    await tester.runAsync(() async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      PreferencesStore.debugOverride(await FlutterKeyValueStore.load());
    });
    await tester.pumpWidget(
      _sectionHarness(AppCustomizationSection.chat, persistSettings: true),
    );
    await tester.pumpAndSettle();

    expect(find.text('Send with Enter'), findsOneWidget);
    expect(find.text('Show additional chat tools and settings.'), findsOne);
    expect(
      PreferencesStore.get<bool>(PreferenceKeys.advancedFeaturesEnabled),
      isNot(true),
    );

    await tester.scrollUntilVisible(find.text('Advanced'), 300);
    await tester.tap(find.text('Advanced'));
    await tester.pumpAndSettle();

    expect(
      PreferencesStore.get<bool>(PreferenceKeys.advancedFeaturesEnabled),
      isTrue,
    );
  });

  testWidgets('Data and Connection owns transport and streaming diagnostics', (
    tester,
  ) async {
    await tester.pumpWidget(
      _sectionHarness(AppCustomizationSection.dataConnection),
    );
    await tester.pumpAndSettle();

    expect(find.text('Connection'), findsWidgets);
    expect(find.text('Transport mode'), findsOneWidget);
    expect(find.text('Disable haptics while streaming'), findsOneWidget);
    expect(find.text('Send with Enter'), findsNothing);
    expect(find.text('App Language'), findsNothing);
  });
}

Widget _sectionHarness(
  AppCustomizationSection section, {
  bool hasOpenWebUiAccount = false,
  bool persistSettings = false,
}) {
  return ProviderScope(
    overrides: [
      if (!persistSettings)
        appSettingsProvider.overrideWithValue(const AppSettings()),
      openWebUiAccountAvailableProvider.overrideWithValue(hasOpenWebUiAccount),
      apiServiceProvider.overrideWithValue(null),
      modelsProvider.overrideWith(_TestModels.new),
      toolsListProvider.overrideWith(_EmptyTools.new),
      optimizedStorageServiceProvider.overrideWithValue(
        _FakeOptimizedStorageService(),
      ),
      socketServiceProvider.overrideWithValue(null),
    ],
    child: MaterialApp(
      theme: ThemeData(platform: TargetPlatform.android),
      localizationsDelegates: conduitLocalizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: AppCustomizationPage(section: section),
    ),
  );
}

class _TestModels extends Models {
  @override
  Future<List<Model>> build() async => const [];
}

class _EmptyTools extends ToolsList {
  @override
  Future<List<Tool>> build() async => const [];
}

class _FakeOptimizedStorageService extends Fake
    implements OptimizedStorageService {
  @override
  String? getThemeMode() => null;

  @override
  String? getThemePaletteId() => null;

  @override
  String? getLocaleCode() => null;

  @override
  SocketTransportAvailability? getLocalTransportOptionsSync() => null;
}
