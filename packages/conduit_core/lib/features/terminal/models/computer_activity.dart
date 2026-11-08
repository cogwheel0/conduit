import 'dart:convert';

import 'package:conduit_markdown/conduit_markdown.dart';
import 'package:markdown/markdown.dart' as md;

import '../../../models/chat_message.dart';

// Open Terminal's advertised operation IDs. A shell command or a mention of
// a browser is not evidence that this chat is using a Computer surface.
const _computerTools = {
  'browser_tabs',
  'browser_snapshot',
  'browser_screenshot',
  'browser_action',
  'desktop_screenshot',
  'desktop_action',
};

bool usesComputer(ChatMessage message) {
  if (message.role != 'assistant') return false;
  final output = message.output;
  if (output != null && output.isNotEmpty) {
    return output.any((item) {
      final function = item['function'];
      return (item['type'] == 'function_call' || item['type'] == 'tool_call') &&
          _computerTools.contains(
            function is Map ? function['name'] : item['name'],
          );
    });
  }
  // Older streams serialize tool calls as semantic details. Parse the same
  // Markdown dialect as the renderer, so code examples never open Computer.
  if (!message.content.contains('type="tool_calls"')) return false;
  bool containsTool(md.Node node) =>
      node is md.Element &&
      ((node.tag == 'details' &&
              node.attributes['type'] == 'tool_calls' &&
              _computerTools.contains(node.attributes['name'])) ||
          (node.children?.any(containsTool) ?? false));
  return md.Document(
    extensionSet: conduitGitHubWebExtensionSet,
    blockSyntaxes: [const DetailsBlockSyntax()],
  ).parseLines(const LineSplitter().convert(message.content)).any(containsTool);
}
