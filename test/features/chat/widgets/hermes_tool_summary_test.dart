import 'package:conduit/features/chat/widgets/hermes_tool_summary.dart';
import 'package:conduit_core/models/chat_message.dart';
import 'package:flutter_test/flutter_test.dart';

ChatStatusUpdate tool(String name, String arguments, {String? error}) =>
    ChatStatusUpdate(
      action: 'hermes_tool_$name',
      description: name,
      done: true,
      items: [
        ChatStatusItem(
          title: 'Arguments',
          snippet: arguments,
          presentation: ChatStatusItemPresentation.detail,
        ),
        if (error != null)
          ChatStatusItem(
            title: 'Error',
            snippet: error,
            presentation: ChatStatusItemPresentation.detail,
          ),
      ],
    );

void main() {
  test('terminal summary reads the command and bounds multiline previews', () {
    final summary = HermesToolSummary.fromUpdate(
      tool('terminal', '{"command":"echo hello\\n pwd"}'),
    );
    expect(summary.kind, HermesToolKind.terminal);
    expect(summary.title, 'Run command');
    expect(summary.preview, 'echo hello pwd');
    expect(summary.failed, isFalse);
  });
  test('skill list and read actions have distinct labels', () {
    expect(
      HermesToolSummary.fromUpdate(tool('skills_list', '{}')).title,
      'List skills',
    );
    final summary = HermesToolSummary.fromUpdate(
      tool('skill_view', '{"name":"github-search"}'),
    );
    expect(summary.title, 'Read skill');
    expect(summary.preview, 'github-search');
  });
  test('search and file actions summarize useful argument values', () {
    expect(
      HermesToolSummary.fromUpdate(
        tool('tool_search', '{"query":"github repos"}'),
      ).preview,
      'github repos',
    );
    final read = HermesToolSummary.fromUpdate(
      tool('read_file', '{"path":"README.md"}'),
    );
    expect(read.title, 'Read file');
    expect(read.preview, 'README.md');
  });

  test(
    'browser interactions and image edits keep the correct action category',
    () {
      expect(
        HermesToolSummary.fromUpdate(
          tool('browser_click', '{"selector":"Submit"}'),
        ).title,
        'Use browser',
      );
      expect(
        HermesToolSummary.fromUpdate(
          tool('edit_image', '{"prompt":"Make it blue"}'),
        ).kind,
        HermesToolKind.image,
      );
      expect(
        HermesToolSummary.fromUpdate(tool('read_resource', '{}')).title,
        'Read content',
      );
    },
  );
  test(
    'truncated, unknown, and failed traces do not invent successful output',
    () {
      final summary = HermesToolSummary.fromUpdate(
        tool('custom_task', '{"cmd":', error: 'Timed out'),
      );
      expect(summary.title, 'custom task');
      expect(summary.preview, isNull);
      expect(summary.failed, isTrue);
      final opaque = HermesToolSummary.fromUpdate(
        const ChatStatusUpdate(
          action: 'hermes_tool_opaque',
          description: 'Hermes tool · Checking status',
        ),
      );
      expect(opaque.title, 'Hermes tool');
      expect(opaque.preview, 'Checking status');
    },
  );
}
