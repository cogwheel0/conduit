import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:conduit/core/models/model.dart';
import 'package:conduit/core/models/socket_transport_availability.dart';
import 'package:conduit/core/models/tool.dart';
import 'package:conduit/core/providers/app_providers.dart';
import 'package:conduit/core/services/optimized_storage_service.dart';
import 'package:conduit/core/services/settings_service.dart';
import 'package:conduit/features/profile/views/app_customization_page.dart';
import 'package:conduit/features/tools/providers/tools_providers.dart';
import 'package:conduit/l10n/app_localizations.dart';

void main() {
  testWidgets('Appearance contains only display and language settings', (
    tester,
  ) async {
    await tester.pumpWidget(
      _sectionHarness(AppCustomizationSection.appearance),
    );
    await tester.pumpAndSettle();

    expect(find.text('Appearance'), findsOneWidget);
    expect(find.text('Display'), findsOneWidget);
    expect(find.text('App Language'), findsWidgets);
    expect(find.text('Quickpills in chat'), findsNothing);
    expect(find.text('Send on Enter'), findsNothing);
    expect(find.text('Transport mode'), findsNothing);
  });

  testWidgets('direct-only Chat hides server-backed prompt settings', (
    tester,
  ) async {
    await tester.pumpWidget(_sectionHarness(AppCustomizationSection.chat));
    await tester.pumpAndSettle();

    expect(find.text('Chat'), findsWidgets);
    expect(find.text('Send on Enter'), findsOneWidget);
    expect(find.text('Temporary Chat by Default'), findsOneWidget);
    expect(find.text('Advanced prompt overrides'), findsNothing);
    expect(find.text('App Language'), findsNothing);
    expect(find.text('Transport mode'), findsNothing);
  });

  testWidgets(
    'Open WebUI Appearance opens Quick Pills without ListTile error',
    (tester) async {
      await tester.pumpWidget(
        _sectionHarness(
          AppCustomizationSection.appearance,
          hasOpenWebUiAccount: true,
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Quickpills in chat'), findsOneWidget);
      await tester.tap(find.text('Quickpills in chat'));
      await tester.pumpAndSettle();

      expect(find.text('Web'), findsOneWidget);
      expect(find.text('Image Gen'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

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

  testWidgets('Data and Connection owns transport and streaming diagnostics', (
    tester,
  ) async {
    await tester.pumpWidget(
      _sectionHarness(AppCustomizationSection.dataConnection),
    );
    await tester.pumpAndSettle();

    expect(find.text('Data & Connection'), findsWidgets);
    expect(find.text('Transport mode'), findsOneWidget);
    expect(find.text('Disable haptics while streaming'), findsOneWidget);
    expect(find.text('Send on Enter'), findsNothing);
    expect(find.text('App Language'), findsNothing);
  });
}

Widget _sectionHarness(
  AppCustomizationSection section, {
  bool hasOpenWebUiAccount = false,
}) {
  return ProviderScope(
    overrides: [
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
      localizationsDelegates: AppLocalizations.localizationsDelegates,
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
