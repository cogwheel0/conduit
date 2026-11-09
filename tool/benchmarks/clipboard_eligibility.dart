// Compile to native AOT. Compare the full sanitizer with the footer predicate
// in A/B/B/A order. Every input is generated here; no server is involved.
import 'dart:convert';

import 'package:conduit_markdown/conduit_markdown.dart';

void main() {
  const unit = 'A blue square uses `shape.color`.\n\n```text\nblue\n```\n\n';
  final text = List.filled((1048576 / unit.length).ceil(), unit).join();
  final fixtures = {
    'ordinary-code': text,
    'leading-whitespace': '   $text',
    'reasoning-prefix': '<think>Compare shapes.</think>$text',
    'reasoning-only': '<think>$text</think>',
  };
  for (final variant in ['full', 'predicate', 'predicate', 'full']) {
    for (final fixture in fixtures.entries) {
      bool run() => variant == 'full'
          ? ConduitMarkdownPreprocessor.sanitizeForClipboard(fixture.value)
                .isNotEmpty
          : ConduitMarkdownPreprocessor.hasClipboardText(fixture.value);
      final expected = ConduitMarkdownPreprocessor.sanitizeForClipboard(
        fixture.value,
      ).isNotEmpty;
      for (var i = 0; i < 5; i++) {
        run();
      }
      final samples = <double>[];
      for (var i = 0; i < 100; i++) {
        final watch = Stopwatch()..start();
        final result = run();
        watch.stop();
        if (result != expected) throw StateError('Eligibility changed');
        samples.add(watch.elapsedTicks * 1000000 / watch.frequency);
      }
      final sorted = samples.toList()..sort();
      // ignore: avoid_print
      print(
        jsonEncode({
          'variant': variant,
          'fixture': fixture.key,
          'characters': fixture.value.length,
          'unit': 'microseconds',
          'p50': sorted[49],
          'p95': sorted[94],
          'p99': sorted[98],
          'samples': samples,
        }),
      );
    }
  }
}
