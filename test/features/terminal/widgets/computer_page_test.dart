import 'package:conduit/features/terminal/widgets/computer_page.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit_core/features/chat/providers/chat_providers.dart';
import 'package:conduit_core/features/terminal/models/computer_models.dart';
import 'package:conduit_core/features/terminal/providers/computer_providers.dart';
import 'package:conduit_core/features/terminal/services/computer_service.dart';
import 'package:conduit_core/models/chat_message.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';

class _Service extends Mock implements ComputerService {}

class _Messages extends ChatMessagesNotifier {
  @override
  List<ChatMessage> build() => [];
}

void main() {
  registerFallbackValue(ComputerSurface.desktop);

  testWidgets('Desktop and Browser have distinct descriptions and navigation', (
    tester,
  ) async {
    final service = _Service();
    when(() => service.open(any()))
        .thenThrow(const ComputerBrowserUnavailable());
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          computerServiceProvider.overrideWith((ref) async => service),
          chatMessagesProvider.overrideWith(_Messages.new),
        ],
        child: MaterialApp(
          theme: ThemeData(platform: TargetPlatform.android),
          localizationsDelegates: conduitLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: ComputerPage(
            service: service,
            capabilities: const ComputerCapabilities(
              desktop: true,
              browser: true,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Full desktop · apps and windows'), findsOneWidget);
    expect(find.byIcon(Icons.refresh_rounded), findsNothing);
    verify(() => service.open(ComputerSurface.desktop)).called(1);
    await tester.tap(find.text('Browser'));
    await tester.pumpAndSettle();
    expect(find.text('Browser tab · web pages'), findsOneWidget);
    expect(find.byIcon(Icons.refresh_rounded), findsOneWidget);
    verify(() => service.open(ComputerSurface.browser)).called(1);
    await tester.tap(find.text('Desktop'));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.refresh_rounded), findsNothing);
    expect(tester.takeException(), isNull);
    tester.view.physicalSize = const Size(844, 390);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpAndSettle();
    expect(find.text('Full desktop · apps and windows'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('Browser'));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.refresh_rounded), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
