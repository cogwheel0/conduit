import 'package:conduit/features/chat/widgets/composer_overflow_items.dart'
    show composerOverflowToolDescription;
import 'package:conduit/features/chat/widgets/composer_overflow_menu.dart';
import 'package:conduit/features/chat/widgets/modern_chat_input.dart';
import 'package:conduit/features/librechat/widgets/librechat_composer_support.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit_core/features/chat/providers/chat_providers.dart';
import 'package:conduit_core/features/librechat/models/librechat_capabilities.dart';
import 'package:conduit_core/features/librechat/models/librechat_model.dart';
import 'package:conduit_core/features/librechat/providers/librechat_composer_providers.dart';
import 'package:conduit_core/features/librechat/providers/librechat_providers.dart';
import 'package:conduit_core/features/tools/providers/tools_providers.dart';
import 'package:conduit_core/models/model.dart';
import 'package:conduit_core/models/prompt.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

final List<Model> _catalog = libreChatCatalog(
  startupConfig: const <String, dynamic>{},
  endpoints: const <String, dynamic>{
    'agents': {'order': 0, 'capabilities': <String>[]},
    'Ollama': {'order': 1, 'type': 'custom'},
  },
  models: const {
    'Ollama': ['llama3.2'],
  },
  agents: const [
    {'id': 'agent_1', 'name': 'Researcher', 'model': 'llama3.2'},
  ],
);

Model get _endpointModel => _catalog.firstWhere((model) => !_isAgent(model));
Model get _agentModel => _catalog.firstWhere(_isAgent);
bool _isAgent(Model model) =>
    libreChatTargetOf(model)!.kind == LibreChatTargetKind.agent;

void main() {
  testWidgets('an endpoint model offers uploads and LibreChat tools', (
    tester,
  ) async {
    final container = await _pumpComposer(
      tester,
      model: _endpointModel,
      options: const LibreChatComposerOptions(
        webSearch: true,
        fileSearch: true,
        mcpServers: [
          LibreChatMcpServerOption(name: 'github', toolCount: 3),
          LibreChatMcpServerOption(name: 'jira', needsConnection: true),
        ],
      ),
    );

    await tester.tap(find.byIcon(Icons.add));
    await tester.pumpAndSettle();

    final sheet = tester.widget<ComposerAttachmentKeyboard>(
      find.byType(ComposerAttachmentKeyboard),
    );
    expect(sheet.onFileAttachment, isNotNull);
    expect(sheet.onImageAttachment, isNotNull);
    expect(sheet.onServerFileAttachment, isNull);
    expect(sheet.onWebAttachment, isNull);
    expect(find.text('Files'), findsOneWidget);
    expect(find.text('Photos'), findsOneWidget);
    expect(find.text('Web Page'), findsNothing);
    expect(find.text('Web Search'), findsOneWidget);
    expect(find.text('File Search'), findsOneWidget);
    expect(find.text('Code Interpreter'), findsNothing);
    expect(find.text('github'), findsOneWidget);
    expect(find.text('jira'), findsOneWidget);
    expect(find.text('Connect in LibreChat'), findsOneWidget);

    await tester.tap(find.text('Web Search'));
    await tester.pumpAndSettle();
    // The attachment tiles leave the tool rows partly below the panel's
    // edge in this viewport: scroll each into view before tapping it.
    await tester.ensureVisible(find.text('github'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('github'));
    await tester.pumpAndSettle();
    expect(container.read(selectedToolIdsProvider), [
      kLibreChatWebSearchToolId,
      '${kLibreChatMcpToolIdPrefix}github',
    ]);

    // A server that needs signing in opens LibreChat instead of switching on.
    await tester.ensureVisible(find.text('jira'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('jira'));
    await tester.pumpAndSettle();
    expect(
      container.read(selectedToolIdsProvider),
      isNot(contains('${kLibreChatMcpToolIdPrefix}jira')),
    );
  });

  testWidgets('an agent brings its own tools; uploads stay', (tester) async {
    await _pumpComposer(
      tester,
      model: _agentModel,
      capabilities: const LibreChatCapabilities(
        webSearch: true,
        codeInterpreter: true,
        fileSearch: true,
      ),
    );

    await tester.tap(find.byIcon(Icons.add));
    await tester.pumpAndSettle();

    expect(find.text('Files'), findsOneWidget);
    expect(find.text('Web Search'), findsNothing);
    expect(find.text('Code Interpreter'), findsNothing);
    expect(find.text('File Search'), findsNothing);
  });

  testWidgets('no uploads and no tools leave no overflow button', (
    tester,
  ) async {
    await _pumpComposer(
      tester,
      model: _endpointModel,
      options: LibreChatComposerOptions.none,
      withAttachments: false,
    );

    expect(find.byIcon(Icons.add), findsNothing);
  });

  testWidgets('a LibreChat prompt is filled with its own grammar', (
    tester,
  ) async {
    String? filled;
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: conduitLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                filled = await fillLibreChatPromptInteractively(
                  context,
                  const Prompt(
                    command: '/trip',
                    title: 'Trip',
                    content:
                        'Plan {{days}} days in {{city:Paris|Rome}} '
                        'near {{area:Old Town, north|Harbour}} for '
                        '{{current_user}}. {{days}} days.',
                  ),
                  userName: 'Ada',
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('Trip'), findsOneWidget);
    // A choice with a comma in it is asked for as text, prefilled.
    expect(find.text('Old Town, north'), findsOneWidget);

    await tester.enterText(find.byType(TextFormField).first, '3');
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();

    expect(filled, 'Plan 3 days in Paris near Old Town, north for Ada. 3 days.');
  });

  testWidgets('a LibreChat choice takes a typed answer or a suggestion, and '
      'empty choices still ask', (tester) async {
    String? filled;
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: conduitLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                filled = await fillLibreChatPromptInteractively(
                  context,
                  const Prompt(
                    command: '/trip',
                    title: 'Trip',
                    content: 'To {{city:Paris|Rome}}, {{answer: | }}.',
                  ),
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    // The choices are offered as suggestions; any answer may be typed.
    await tester.tap(find.text('Rome'));
    await tester.pump();
    await tester.enterText(find.byType(TextFormField).first, 'Madrid');
    await tester.enterText(find.byType(TextFormField).last, 'yes');
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();

    expect(filled, 'To Madrid, yes.');
  });

  testWidgets('a LibreChat blank left unanswered stays in the prompt', (
    tester,
  ) async {
    String? filled;
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: conduitLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                filled = await fillLibreChatPromptInteractively(
                  context,
                  const Prompt(
                    command: '/note',
                    title: 'Note',
                    content: 'Dear {{name}}, about {{topic}}.',
                  ),
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField).first, 'Ada');
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();

    expect(filled, 'Dear Ada, about {{topic}}.');
  });

  test('tool rows follow the options', () async {
    final l10n = await AppLocalizations.delegate.load(const Locale('en'));
    final tools = libreChatComposerTools(
      l10n,
      const LibreChatComposerOptions(
        codeInterpreter: true,
        mcpServers: [LibreChatMcpServerOption(name: 'github')],
      ),
    );
    expect(tools.map((tool) => tool.id), [
      kLibreChatCodeToolId,
      '${kLibreChatMcpToolIdPrefix}github',
    ]);
    expect(tools.last.meta?['description'], 'MCP Server');
  });

  test('file search says it searches files, not the web', () async {
    final l10n = await AppLocalizations.delegate.load(const Locale('en'));
    final tools = libreChatComposerTools(
      l10n,
      const LibreChatComposerOptions(fileSearch: true),
    );
    expect(
      composerOverflowToolDescription(tools.single),
      l10n.libreChatFileSearchDescription,
    );
  });
}

Future<ProviderContainer> _pumpComposer(
  WidgetTester tester, {
  required Model model,
  LibreChatComposerOptions? options,
  LibreChatCapabilities? capabilities,
  bool withAttachments = true,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        selectedModelProvider.overrideWithValue(model),
        isChatStreamingProvider.overrideWithValue(false),
        apiServiceProvider.overrideWithValue(null),
        libreChatFileBaseUrlProvider.overrideWithValue(
          'https://chat.example.com',
        ),
        if (options != null)
          libreChatComposerOptionsProvider.overrideWith((ref) async => options),
        if (capabilities != null)
          libreChatCapabilitiesProvider.overrideWith(
            (ref) async => capabilities,
          ),
      ],
      child: MaterialApp(
        localizationsDelegates: conduitLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: ModernChatInput(
            onSendMessage: (_) {},
            onFileAttachment: withAttachments ? () {} : null,
            onImageAttachment: withAttachments ? () {} : null,
            onCameraCapture: withAttachments ? () {} : null,
            onServerFileAttachment: () {},
            onWebAttachment: () {},
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return ProviderScope.containerOf(
    tester.element(find.byType(ModernChatInput)),
  );
}
