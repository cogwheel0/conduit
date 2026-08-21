import 'dart:async';

import 'package:conduit/core/providers/storage_providers.dart';
import 'package:conduit/features/direct_connections/models/direct_mcp_content.dart';
import 'package:conduit/features/direct_connections/models/direct_mcp_server.dart';
import 'package:conduit/features/direct_connections/providers/direct_mcp_providers.dart';
import 'package:conduit/features/direct_connections/views/direct_mcp_content_sheet.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mcp_dart/mcp_dart.dart' as mcp;

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  test('formats transparent prompt and resource insertions', () {
    final prompt = formatDirectMcpPromptInsertion(
      heading: 'MCP prompt from Local: Explain',
      preview: DirectMcpPromptPreview(
        messages: const [
          DirectMcpPromptMessage(role: 'system', text: 'Be concise.'),
          DirectMcpPromptMessage(role: 'user', text: 'Explain MCP.'),
          DirectMcpPromptMessage(role: 'assistant', text: 'A protocol.'),
        ],
      ),
      roleLabel: (role) => switch (role) {
        'system' => 'System',
        'assistant' => 'Assistant',
        _ => 'User',
      },
    );
    final resource = formatDirectMcpResourceInsertion(
      heading: 'MCP resource from Local: file:///notes.txt',
      preview: const DirectMcpResourcePreview(text: 'Exact text.'),
    );

    expect(prompt, contains('System:\nBe concise.'));
    expect(prompt, contains('User:\nExplain MCP.'));
    expect(prompt, contains('Assistant:\nA protocol.'));
    expect(resource, endsWith('file:///notes.txt\n\nExact text.'));
  });

  testWidgets(
    'browses, validates, previews, refreshes, and explicitly inserts',
    (tester) async {
      var inventoryLoads = 0;
      final container = await _container(
        inventoryLoader: (server) async {
          inventoryLoads++;
          if (server.id == 'second') throw StateError('fixture failure');
          return _inventory(server);
        },
        promptLoader: (server, prompt, arguments, signal) async {
          return DirectMcpPromptPreview(
            messages: [
              DirectMcpPromptMessage(
                role: 'user',
                text: 'Explain ${arguments['topic']}',
              ),
            ],
          );
        },
        resourceLoader: (server, resource, signal) async =>
            const DirectMcpResourcePreview(text: 'Exact local text.'),
      );
      addTearDown(container.dispose);
      await _pumpHost(tester, container);

      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      expect(
        find.bySemanticsLabel('Search prompts and resources'),
        findsWidgets,
      );
      expect(
        find.byKey(const Key('direct-mcp-prompt-explain')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('direct-mcp-resource-file:///notes.txt')),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const Key('direct-mcp-content-refresh')));
      await tester.pumpAndSettle();
      expect(inventoryLoads, 2);

      await tester.enterText(
        find.byKey(const Key('direct-mcp-content-search')),
        'notes',
      );
      await tester.pump();
      expect(find.byKey(const Key('direct-mcp-prompt-explain')), findsNothing);
      expect(
        find.byKey(const Key('direct-mcp-resource-file:///notes.txt')),
        findsOneWidget,
      );
      await tester.enterText(
        find.byKey(const Key('direct-mcp-content-search')),
        '',
      );
      await tester.pump();

      await tester.tap(find.text('First'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Second').last);
      await tester.pumpAndSettle();
      expect(
        find.text('Could not load content from this MCP server.'),
        findsOneWidget,
      );
      await tester.tap(find.text('Second'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('First').last);
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('direct-mcp-prompt-explain')));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      await tester.tap(find.text('Continue'));
      await tester.pump();
      expect(find.text('Required field'), findsOneWidget);
      await tester.enterText(
        find.byKey(const Key('direct-mcp-argument-topic')),
        '💥' * 4097,
      );
      await tester.tap(find.text('Continue'));
      await tester.pump();
      expect(find.text('This content is too large to insert.'), findsOneWidget);
      await tester.enterText(
        find.byKey(const Key('direct-mcp-argument-topic')),
        'local MCP',
      );
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();

      expect(find.textContaining('MCP prompt from First'), findsOneWidget);
      expect(find.textContaining('User:\nExplain local MCP'), findsOneWidget);
      expect(find.text('No insertion'), findsOneWidget);
      await tester.tap(find.byKey(const Key('direct-mcp-content-insert')));
      await tester.pumpAndSettle();
      expect(find.byType(DirectMcpContentSheet), findsNothing);
      expect(find.text('No insertion'), findsNothing);
      expect(find.textContaining('User:\nExplain local MCP'), findsOneWidget);

      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const Key('direct-mcp-resource-file:///notes.txt')),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('file:///notes.txt'), findsWidgets);
      expect(find.textContaining('Exact local text.'), findsOneWidget);
      await tester.tap(find.byKey(const Key('direct-mcp-content-insert')));
      await tester.pumpAndSettle();
      expect(find.byType(DirectMcpContentSheet), findsNothing);
      expect(find.textContaining('Exact local text.'), findsOneWidget);
    },
  );

  testWidgets('cancels a pending preview without inserting', (tester) async {
    final aborted = Completer<void>();
    final container = await _container(
      inventoryLoader: (server) async =>
          _inventory(server, arguments: const []),
      promptLoader: (server, prompt, arguments, signal) {
        final pending = Completer<DirectMcpPromptPreview>();
        signal.onAbort.first.then((_) {
          if (!aborted.isCompleted) aborted.complete();
          pending.completeError(mcp.AbortError());
        });
        return pending.future;
      },
      resourceLoader: (server, resource, signal) async =>
          const DirectMcpResourcePreview(text: ''),
    );
    addTearDown(container.dispose);
    await _pumpHost(tester, container);
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('direct-mcp-prompt-explain')));
    await tester.pump();
    expect(find.text('Loading MCP content…'), findsWidgets);
    await tester.tap(find.byKey(const Key('direct-mcp-content-cancel')));
    await tester.pumpAndSettle();

    await aborted.future.timeout(const Duration(seconds: 2));
    expect(find.byKey(const Key('direct-mcp-prompt-explain')), findsOneWidget);
    expect(find.text('No insertion'), findsOneWidget);
  });
}

Future<ProviderContainer> _container({
  required DirectMcpContentInventoryLoader inventoryLoader,
  required DirectMcpPromptPreviewLoader promptLoader,
  required DirectMcpResourcePreviewLoader resourceLoader,
}) async {
  const storage = FlutterSecureStorage();
  final container = ProviderContainer(
    overrides: [
      secureStorageProvider.overrideWithValue(storage),
      directMcpContentInventoryLoaderProvider.overrideWithValue(
        inventoryLoader,
      ),
      directMcpPromptPreviewLoaderProvider.overrideWithValue(promptLoader),
      directMcpResourcePreviewLoaderProvider.overrideWithValue(resourceLoader),
    ],
  );
  final notifier = container.read(directMcpServersProvider.notifier);
  await notifier.upsert(
    DirectMcpServer(
      id: 'first',
      name: 'First',
      endpoint: 'https://first.example/mcp',
    ),
  );
  await notifier.upsert(
    DirectMcpServer(
      id: 'second',
      name: 'Second',
      endpoint: 'https://second.example/mcp',
    ),
  );
  return container;
}

DirectMcpContentInventory _inventory(
  DirectMcpServer server, {
  List<DirectMcpPromptArgument> arguments = const [
    DirectMcpPromptArgument(
      name: 'topic',
      label: 'Topic',
      description: 'What to explain',
      required: true,
    ),
  ],
}) => DirectMcpContentInventory(
  serverId: server.id,
  serverName: server.name,
  prompts: [
    DirectMcpPromptSummary(
      name: 'explain',
      displayName: 'Explain',
      description: 'Build an explanation.',
      arguments: arguments,
      inventoryIdentity: 'prompt-v1',
    ),
  ],
  resources: const [
    DirectMcpResourceSummary(
      uri: 'file:///notes.txt',
      displayName: 'Notes',
      description: 'Local notes',
      mimeType: 'text/plain',
      inventoryIdentity: 'resource-v1',
    ),
  ],
);

Future<void> _pumpHost(WidgetTester tester, ProviderContainer container) =>
    tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          localizationsDelegates: conduitLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const _ContentHost(),
        ),
      ),
    );

class _ContentHost extends StatefulWidget {
  const _ContentHost();

  @override
  State<_ContentHost> createState() => _ContentHostState();
}

class _ContentHostState extends State<_ContentHost> {
  String? _result;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Column(
      children: [
        TextButton(
          onPressed: () async {
            final result = await DirectMcpContentSheet.show(context);
            if (mounted && result != null) setState(() => _result = result);
          },
          child: const Text('Open'),
        ),
        Text(_result ?? 'No insertion'),
      ],
    ),
  );
}
