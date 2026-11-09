// Run with `dart run tool/benchmarks/markdown_sanitize.dart <revision>`.
// For timing, compile to an executable with `dart compile exe` first.
import 'dart:convert';

import 'package:conduit_markdown/conduit_markdown.dart';

void main(List<String> args) {
  const prose = 'A blue square sits beside an orange triangle. ';
  const code =
      'Use `shape.color` to select blue.\n\n'
      '```text\nshape = square\ncolor = blue\n```\n\n';
  const reasoning = '<think>Compare the shapes.</think>\n\n';
  const tool = '<details type="tool_calls">Count shapes.</details>\n\n';
  final fixtures = <String, String>{
    'prose': prose,
    'code': code,
    'reasoning-and-code': '$reasoning$code',
    'tools-and-code': '$tool$code',
    'literal-markup-in-code': '```html\n$reasoning$tool```\n\n',
    'literal-openers-in-code': '```html\n${'<think>\n' * 32}```\n\n',
  };
  for (final size in [8192, 131072, 1048576]) {
    for (final fixture in fixtures.entries) {
      // Repeat whole units so the payload ends on a complete fence/tag.
      final text = List.filled(
        (size / fixture.value.length).ceil(),
        fixture.value,
      ).join().trim();
      final expected = ConduitMarkdownPreprocessor.sanitizeForClipboard(text);
      for (var warmup = 0; warmup < 5; warmup++) {
        ConduitMarkdownPreprocessor.sanitizeForClipboard(text);
      }
      final samples = <double>[];
      for (var sample = 0; sample < 50; sample++) {
        final watch = Stopwatch()..start();
        final result = ConduitMarkdownPreprocessor.sanitizeForClipboard(text);
        watch.stop();
        samples.add(watch.elapsedTicks * 1000000 / watch.frequency);
        if (result != expected) throw StateError('Sanitizer output changed');
      }
      final sorted = samples.toList()..sort();
      double percentile(double p) => sorted[(sorted.length * p).ceil() - 1];
      // Structured benchmark output; no application logger or backend involved.
      // ignore: avoid_print
      print(
        jsonEncode({
          'revision': args.firstOrNull ?? 'working-tree',
          'fixture': fixture.key,
          'characters': text.length,
          'targetSize': size,
          'outputLength': expected.length,
          'unit': 'microseconds',
          'p50': percentile(.50),
          'p95': percentile(.95),
          'p99': percentile(.99),
          'samples': samples,
        }),
      );
    }
  }
}
