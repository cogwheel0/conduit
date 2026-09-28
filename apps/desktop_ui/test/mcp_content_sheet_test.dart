@TestOn('vm')
library;

import 'package:conduit_desktop_ui/src/l10n/strings.g.dart';
import 'package:conduit_desktop_ui/src/rpc/mcp_providers.dart';
import 'package:conduit_desktop_ui/src/widgets/mcp_content_sheet.dart';
import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:jaspr/jaspr.dart';
import 'package:jaspr_riverpod/jaspr_riverpod.dart';
import 'package:jaspr_test/jaspr_test.dart';

/// Answers from a fixed server instead of the daemon.
class _FakeMcp extends McpActions {
  _FakeMcp(super.ref);

  final List<McpGetPrompt> asked = <McpGetPrompt>[];

  @override
  Future<McpContent> content(String serverId) async => const McpContent(
    serverId: 'm1',
    serverName: 'Docs',
    prompts: <McpPromptSummary>[
      McpPromptSummary(
        name: 'summarize',
        displayName: 'Summarize',
        arguments: <McpPromptArgument>[
          McpPromptArgument(name: 'topic', label: 'Topic', required: true),
        ],
      ),
    ],
    resources: <McpResourceSummary>[
      McpResourceSummary(uri: 'file:///today.md', displayName: 'today.md'),
    ],
  );

  @override
  Future<McpContentPreview> readResource(McpReadResource request) async =>
      const McpContentPreview(
        messages: <McpPromptMessage>[
          McpPromptMessage(role: '', text: 'Water the plants.'),
        ],
      );

  @override
  Future<McpContentPreview> getPrompt(McpGetPrompt request) async {
    asked.add(request);
    return McpContentPreview(
      messages: <McpPromptMessage>[
        McpPromptMessage(
          role: 'user',
          text: 'Summarize ${request.arguments['topic']}.',
        ),
      ],
    );
  }
}

void main() {
  late _FakeMcp fake;
  String? inserted;

  Component sheet() => ProviderScope(
    overrides: [mcpActionsProvider.overrideWith((ref) => fake = _FakeMcp(ref))],
    child: McpContentSheet(
      servers: const <ToolSummary>[
        ToolSummary(id: 'local_mcp:m1', name: 'Docs'),
      ],
      draft: 'Before',
      onInsert: (text) => inserted = text,
      onClose: () {},
    ),
  );

  Finder buttonWith(String text) =>
      find.ancestor(of: find.text(text), matching: find.tag('button'));

  testComponents('a prompt waits for its arguments, then is inserted', (
    tester,
  ) async {
    tester.pumpComponent(sheet());
    await pumpEventQueue();
    expect(find.text('Summarize'), findsOneComponent);
    expect(find.text('today.md'), findsOneComponent);

    await tester.click(buttonWith('Summarize'));
    await pumpEventQueue();
    // A required argument, so Insert is not offered yet.
    expect(find.text('Topic *'), findsOneComponent);

    await tester.click(buttonWith(t.app.directMcpContentInsert));
    await pumpEventQueue();
    expect(inserted, isNull);
  });

  testComponents('the insertion names where it came from', (tester) async {
    tester.pumpComponent(sheet());
    await pumpEventQueue();
    await tester.click(buttonWith('today.md'));
    await pumpEventQueue();
    await tester.click(buttonWith(t.app.directMcpContentInsert));
    await pumpEventQueue();
    // After what was typed, under a heading naming the server and item.
    expect(
      inserted,
      'Before\n\n'
      '${t.app.directMcpContentResourceHeading(serverName: 'Docs', resourceUri: 'file:///today.md')}'
      '\n\nWater the plants.',
    );
    expect(fake.asked, isEmpty);
  });
}
