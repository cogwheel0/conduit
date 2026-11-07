import 'package:conduit/features/terminal/widgets/computer_browser_tabs.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:conduit_core/features/terminal/models/computer_models.dart';
import 'package:conduit_core/features/terminal/services/computer_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';

class _Service extends Mock implements ComputerService {}

void main() {
  testWidgets('iOS sheet opens with standalone localizations and large text', (
    tester,
  ) async {
    PlatformUiCapabilities.debugPlatformOverride = TargetPlatform.iOS;
    PlatformUiCapabilities.debugIOSMajorVersionOverride = 27;
    PlatformUiCapabilities.debugNativeIOS26Override = true;
    addTearDown(PlatformUiCapabilities.resetDebugOverrides);
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final service = _Service();
    when(service.browserTabs).thenAnswer(
      (_) async => [
        const ComputerBrowserTab(
          id: 'one',
          title: 'Workshop materials and creative plans',
        ),
      ],
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.iOS),
        localizationsDelegates: conduitLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(2)),
          child: child!,
        ),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showComputerBrowserTabs(
                context,
                service: service,
                currentId: 'one',
                controlling: false,
              ),
              child: const Text('Open tabs'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open tabs'));
    await tester.pumpAndSettle();
    expect(find.byType(ComputerBrowserTabs), findsOneWidget);
    final hintStyle = DefaultTextStyle.of(
      tester.element(find.text('Take control to switch, open, or close tabs.')),
    ).style;
    expect(hintStyle.fontSize, lessThanOrEqualTo(20));
    expect(hintStyle.decoration, isNot(TextDecoration.underline));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });

  for (final controlling in [false, true]) {
    testWidgets(
      'tabs respect Watch and return exact actions (control=$controlling)',
      (tester) async {
        final service = _Service();
        when(service.browserTabs).thenAnswer(
          (_) async => const [
            ComputerBrowserTab(
              id: 'one',
              title: 'Sketches',
              url: 'https://studio.example',
            ),
            ComputerBrowserTab(id: 'two', title: 'Materials', selected: true),
          ],
        );
        ComputerTabChoice? choice;
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(platform: TargetPlatform.android),
            localizationsDelegates: conduitLocalizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () async => choice = await showComputerBrowserTabs(
                    context,
                    service: service,
                    currentId: 'two',
                    controlling: controlling,
                  ),
                  child: const Text('Open tabs'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('Open tabs'));
        await tester.pumpAndSettle();
        expect(find.text('Materials'), findsOneWidget);
        await tester.tap(find.text('Sketches'));
        await tester.pumpAndSettle();
        if (controlling) {
          expect(choice, (action: ComputerTabAction.select, id: 'one'));
        } else {
          expect(choice, isNull);
          await tester.tap(find.text('Take control'));
          await tester.pumpAndSettle();
          expect(choice, (action: ComputerTabAction.control, id: null));
        }
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('tab errors can be refreshed without exposing server details', (
    tester,
  ) async {
    final service = _Service();
    when(service.browserTabs).thenAnswer(
      (_) async => throw StateError('synthetic-server-internal-detail'),
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.android),
        localizationsDelegates: conduitLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: ComputerBrowserTabs(
            service: service,
            currentId: null,
            controlling: true,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.textContaining('synthetic-server-internal-detail'),
      findsNothing,
    );
    when(service.browserTabs).thenAnswer((_) async => []);
    await tester.tap(find.bySemanticsLabel('Refresh tabs'));
    await tester.pumpAndSettle();
    expect(find.text('No browser tabs'), findsOneWidget);
  });
}
