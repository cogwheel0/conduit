import 'package:conduit/core/models/model.dart';
import 'package:conduit/core/providers/app_providers.dart';
import 'package:conduit/core/services/settings_service.dart';
import 'package:conduit/features/profile/views/personalization_page.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('direct-only Personalization exposes only the default model', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          openWebUiAccountAvailableProvider.overrideWithValue(false),
          appSettingsProvider.overrideWithValue(const AppSettings()),
          apiServiceProvider.overrideWithValue(null),
          modelsProvider.overrideWith(_DirectModels.new),
        ],
        child: const MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: PersonalizationPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Default Model'), findsWidgets);
    expect(find.text('Your System Prompt'), findsNothing);
    expect(find.text('Memory'), findsNothing);
    expect(find.text('Advanced prompt overrides'), findsNothing);

    await tester.tap(find.text('Default Model').last);
    await tester.pumpAndSettle();

    expect(find.text('Direct Alpha'), findsOneWidget);
    expect(find.text('Direct Beta'), findsOneWidget);
  });
}

class _DirectModels extends Models {
  @override
  Future<List<Model>> build() async => const [
    Model(
      id: 'direct:alpha',
      name: 'Direct Alpha',
      metadata: {'backend': 'direct'},
    ),
    Model(
      id: 'direct:beta',
      name: 'Direct Beta',
      metadata: {'backend': 'direct'},
    ),
  ];
}
