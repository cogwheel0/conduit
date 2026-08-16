import 'dart:async';
import 'dart:ui' show SemanticsAction;

import 'package:conduit/core/providers/app_providers.dart';
import 'package:conduit/features/chat/providers/chat_providers.dart';
import 'package:conduit/features/chat/widgets/composer_overflow_menu.dart';
import 'package:conduit/features/chat/widgets/modern_chat_input.dart';
import 'package:conduit/features/hermes/models/hermes_capabilities.dart';
import 'package:conduit/features/hermes/models/hermes_config.dart';
import 'package:conduit/features/hermes/models/hermes_model.dart';
import 'package:conduit/features/hermes/providers/hermes_providers.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Hermes overflow follows local attachment availability', () {
    expect(
      shouldShowComposerOverflowButton(
        isHermesComposer: true,
        isDirectComposer: false,
        directSupportsImages: true,
      ),
      isFalse,
    );
    expect(
      shouldShowComposerOverflowButton(
        isHermesComposer: true,
        isDirectComposer: false,
        directSupportsImages: false,
        hermesHasLocalAttachmentActions: true,
      ),
      isTrue,
    );
  });

  testWidgets('Hermes image capability reveals only local attachment actions', (
    tester,
  ) async {
    var photoCalls = 0;

    await _pumpComposer(
      tester,
      capabilities: const HermesCapabilities(inputImages: true),
      onFileAttachment: () {},
      onImageAttachment: () => photoCalls++,
      onCameraCapture: () {},
      onServerFileAttachment: () {},
      onWebAttachment: () {},
    );

    final textField = tester.widget<TextField>(find.byType(TextField));
    expect(textField.contentInsertionConfiguration, isNotNull);
    expect(find.byIcon(Icons.add), findsOneWidget);

    await tester.tap(find.byIcon(Icons.add));
    await tester.pumpAndSettle();

    final sheet = tester.widget<ComposerAttachmentKeyboard>(
      find.byType(ComposerAttachmentKeyboard),
    );
    expect(sheet.localAttachmentsOnly, isTrue);
    expect(find.text('File'), findsOneWidget);
    expect(find.text('Photo'), findsOneWidget);
    expect(find.text('Camera'), findsOneWidget);
    expect(find.text('Files'), findsNothing);
    expect(find.text('Web Page'), findsNothing);
    expect(find.text('Tools'), findsNothing);

    await tester.tap(find.text('Photo'));
    await tester.pumpAndSettle();
    expect(photoCalls, 1);
  });

  testWidgets('Hermes images fail closed when capability is absent', (
    tester,
  ) async {
    await _pumpComposer(
      tester,
      capabilities: const HermesCapabilities(),
      onImageAttachment: () {},
      onCameraCapture: () {},
    );

    final textField = tester.widget<TextField>(find.byType(TextField));
    expect(textField.contentInsertionConfiguration, isNull);
    expect(find.byIcon(Icons.add), findsNothing);
  });

  testWidgets(
    'Hermes images fail closed while capabilities load but local files remain',
    (tester) async {
      final capabilities = Completer<HermesCapabilities>();

      await _pumpComposer(
        tester,
        pendingCapabilities: capabilities.future,
        onFileAttachment: () {},
        onImageAttachment: () {},
        onCameraCapture: () {},
      );

      final textField = tester.widget<TextField>(find.byType(TextField));
      expect(textField.contentInsertionConfiguration, isNull);
      expect(find.byIcon(Icons.add), findsOneWidget);

      await tester.tap(find.byIcon(Icons.add));
      await tester.pumpAndSettle();

      expect(find.text('File'), findsOneWidget);
      expect(find.text('Photo'), findsNothing);
      expect(find.text('Camera'), findsNothing);

      capabilities.complete(const HermesCapabilities(inputImages: true));
    },
  );

  testWidgets('Hermes suppresses OpenWebUI context suggestions', (
    tester,
  ) async {
    await _pumpComposer(
      tester,
      capabilities: const HermesCapabilities(inputImages: true),
    );

    await tester.enterText(find.byType(TextField), '#document');
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.byKey(const ValueKey('prompt-overlay')), findsNothing);
  });

  testWidgets('Desktop local streams keep Stop enabled without running state', (
    tester,
  ) async {
    await _pumpComposer(
      tester,
      capabilities: const HermesCapabilities(),
      desktopGateway: true,
      isStreaming: true,
    );

    final stop = find.byKey(const ValueKey('primary-btn-stop'));
    expect(stop, findsOneWidget);
    expect(
      tester
          .getSemantics(stop)
          .getSemanticsData()
          .hasAction(SemanticsAction.tap),
      isTrue,
    );
  });
}

class _DesktopHermesConfigController extends HermesConfigController {
  @override
  HermesConfig build() => const HermesConfig(
    enabled: true,
    baseUrl: 'https://hermes.example',
    mode: HermesBackendMode.desktopGateway,
  );
}

Future<void> _pumpComposer(
  WidgetTester tester, {
  HermesCapabilities? capabilities,
  Future<HermesCapabilities>? pendingCapabilities,
  VoidCallback? onFileAttachment,
  VoidCallback? onServerFileAttachment,
  VoidCallback? onImageAttachment,
  VoidCallback? onCameraCapture,
  VoidCallback? onWebAttachment,
  bool desktopGateway = false,
  bool isStreaming = false,
}) async {
  assert((capabilities == null) != (pendingCapabilities == null));

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        selectedModelProvider.overrideWithValue(hermesSyntheticModel()),
        if (desktopGateway) ...[
          hermesConfigProvider.overrideWith(_DesktopHermesConfigController.new),
          hermesDesktopTurnStateProvider.overrideWith(
            (_) => Stream.value(HermesDesktopTurnState.unsupportedGateway),
          ),
        ],
        isChatStreamingProvider.overrideWithValue(isStreaming),
        hermesCapabilitiesProvider.overrideWith(
          (ref) => pendingCapabilities ?? Future.value(capabilities!),
        ),
        apiServiceProvider.overrideWithValue(null),
        webSearchAvailableProvider.overrideWithValue(true),
        imageGenerationAvailableProvider.overrideWithValue(true),
      ],
      child: MaterialApp(
        localizationsDelegates: conduitLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: ModernChatInput(
            onSendMessage: (_) {},
            onFileAttachment: onFileAttachment,
            onServerFileAttachment: onServerFileAttachment,
            onImageAttachment: onImageAttachment,
            onCameraCapture: onCameraCapture,
            onWebAttachment: onWebAttachment,
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  if (pendingCapabilities == null) {
    await tester.pumpAndSettle();
  }
}
