// Compiled by CI with `dart compile js` to prove the package survives
// dart2js — the desktop renderer imports it from a browser context, so a
// stray `dart:io` anywhere in its transitive graph must fail the build
// rather than show up as a runtime load error.
import 'package:conduit_markdown/conduit_markdown.dart';

void main() {
  // Touch a symbol from each library so the tree shaker cannot drop the
  // graph and make this a vacuous check.
  final normalized = ConduitMarkdownPreprocessor.normalize(
    '**hi** <think>reasoning</think> [1]',
  );
  final citations = CitationParser.extractSourceIds(normalized);
  final reasoning = ReasoningParser.segments(normalized);
  final segment = MessageSegment.text(normalized);

  if (!segment.isText) throw StateError('unreachable');
  print(
    'conduit_markdown: dart2js ok '
    '(${normalized.length} chars, ${citations.length} citations, '
    '${reasoning?.length ?? 0} reasoning)',
  );
}
