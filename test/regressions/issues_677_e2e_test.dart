import 'dart:convert';
import 'dart:io';
import 'package:conduit/core/services/structured_output.dart';
import 'package:conduit/core/services/structured_output_renderer.dart';
import 'package:conduit/shared/widgets/markdown/markdown_preprocessor.dart';
import 'package:conduit/shared/widgets/markdown/renderer/details_block_syntax.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:html_unescape/html_unescape.dart';

/// End-to-end regression for issue #677: replays a real message's
/// structured output items through the render pipeline and asserts no raw
/// <details> wall appears in the parsed output (renderer-faithful check).
void main() {
  test('FINAL E2E both real fixtures', () {
    final unescape = HtmlUnescape();
    for (final fixture in [
      'test/fixtures/wall_message_677.json',
    ]) {
      final raw = File(fixture).readAsStringSync();
      final msg = jsonDecode(raw) as Map<String, dynamic>;
      final items = (msg['output'] as List)
          .map((e) => e is Map ? Map<String, dynamic>.from(e) : e)
          .toList();
      final messageItem = items.whereType<Map>().firstWhere(
            (m) => m['type'] == 'message',
          );
      final realAnswer =
          (messageItem['content'] as List).first['text'] as String;
      final blocks = parseOpenWebUIStructuredOutput(items);
      final content =
          renderStructuredOutputBlocksWithContent(blocks, realAnswer);
      final normalized = ConduitMarkdownPreprocessor.normalize(content);
      final doc = md.Document(blockSyntaxes: const [DetailsBlockSyntax()]);
      final nodes = doc.parse(normalized);
      String? wallNode;
      void walk(md.Node node) {
        if (wallNode != null) return;
        if (node is md.Text) {
          final decoded = unescape.convert(node.text);
          final t = decoded.trimLeft();
          if (t.startsWith('<details') || t.startsWith('<summary')) {
            wallNode = t.substring(0, t.length > 80 ? 80 : t.length);
          }
          return;
        }
        if (node is md.Element) {
          for (final c in node.children ?? const <md.Node>[]) {
            walk(c);
          }
        }
      }

      for (final node in nodes) {
        walk(node);
      }
      // ignore: avoid_print
      print(fixture + ' -> wall: ' + (wallNode ?? 'NONE'));
      expect(wallNode, isNull);
    }
  });
}
