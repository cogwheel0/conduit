import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:conduit/features/terminal/widgets/computer_launcher.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit_core/features/terminal/models/computer_models.dart';
import 'package:conduit_core/features/terminal/providers/computer_providers.dart';
import 'package:conduit_core/features/terminal/services/computer_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';

class _Service extends Mock implements ComputerService {}

void main() {
  registerFallbackValue(const ComputerCapabilities());
  final connection = ComputerConnection(
    surface: ComputerSurface.browser,
    streamUri: Uri.parse('wss://computer.example/browser/stream'),
  );
  final png = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Wl6rZkAAAAASUVORK5CYII=',
  );

  Widget harness(
    ComputerService service, {
    bool available = true,
    double scale = 1,
  }) => ProviderScope(
    overrides: [
      computerServiceProvider.overrideWith((ref) async => service),
      computerCapabilitiesProvider.overrideWith(
        (ref) async => ComputerCapabilities(browser: available),
      ),
    ],
    child: MaterialApp(
      theme: ThemeData(platform: TargetPlatform.android),
      localizationsDelegates: conduitLocalizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: MediaQuery(
          data: MediaQueryData(textScaler: TextScaler.linear(scale)),
          child: const Align(
            alignment: Alignment.bottomCenter,
            child: ComputerLauncher(),
          ),
        ),
      ),
    ),
  );

  testWidgets('collapsed entry never opens a computer or fetches pixels', (
    tester,
  ) async {
    final service = _Service();
    await tester.pumpWidget(harness(service));
    await tester.pumpAndSettle();
    expect(find.text('Computer'), findsOneWidget);
    expect(find.text('Open live'), findsNothing);
    verifyNever(() => service.openPreferred(any()));
    verifyNever(() => service.screenshot(connection));
  });

  testWidgets('unsupported terminal has no Computer entry', (tester) async {
    await tester.pumpWidget(harness(_Service(), available: false));
    await tester.pumpAndSettle();
    expect(find.text('Computer'), findsNothing);
  });

  testWidgets('preview is explicit and disappears when collapsed', (
    tester,
  ) async {
    final service = _Service();
    when(() => service.openPreferred(any()))
        .thenAnswer((_) async => connection);
    when(() => service.screenshot(connection)).thenAnswer((_) async => png);
    await tester.pumpWidget(harness(service));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Computer'));
    await tester.pumpAndSettle();
    expect(find.text('Open live'), findsOneWidget);
    verify(() => service.openPreferred(any())).called(1);
    await tester.tap(find.text('Computer'));
    await tester.pumpAndSettle();
    expect(find.byType(Image), findsNothing);
  });

  testWidgets('late preview cannot reopen a collapsed card', (tester) async {
    final service = _Service();
    final pending = Completer<Uint8List>();
    when(() => service.openPreferred(any()))
        .thenAnswer((_) async => connection);
    when(() => service.screenshot(connection))
        .thenAnswer((_) => pending.future);
    await tester.pumpWidget(harness(service));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Computer'));
    await tester.pump();
    await tester.tap(find.text('Computer'));
    pending.complete(png);
    await tester.pumpAndSettle();
    expect(find.text('Open live'), findsNothing);
    expect(find.byType(Image), findsNothing);
  });

  testWidgets('backgrounding discards the preview', (tester) async {
    final service = _Service();
    when(() => service.openPreferred(any()))
        .thenAnswer((_) async => connection);
    when(() => service.screenshot(connection)).thenAnswer((_) async => png);
    await tester.pumpWidget(harness(service));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Computer'));
    await tester.pumpAndSettle();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pumpAndSettle();
    expect(find.byType(Image), findsNothing);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  });

  testWidgets('large text preview remains usable on narrow screens', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final service = _Service();
    when(() => service.openPreferred(any()))
        .thenAnswer((_) async => connection);
    when(() => service.screenshot(connection)).thenAnswer((_) async => png);
    await tester.pumpWidget(harness(service, scale: 2));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Computer'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('Open live'), findsOneWidget);
  });
}
