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
    'reference-prefix': '[shape]: https://example.com\n\n$text',
  };
  const order = ['full', 'predicate', 'predicate', 'full'];
  for (final (runIndex, variant) in order.indexed) {
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
      final callsPerSample =
          variant == 'predicate' && fixture.key == 'ordinary-code' ? 1024 : 1;
      for (var i = 0; i < 100; i++) {
        var matches = 0;
        final watch = Stopwatch()..start();
        for (var call = 0; call < callsPerSample; call++) {
          if (run()) matches++;
        }
        watch.stop();
        if (matches != (expected ? callsPerSample : 0)) {
          throw StateError('Eligibility changed');
        }
        samples.add(
          watch.elapsedTicks * 1000000 / watch.frequency / callsPerSample,
        );
      }
      final sorted = samples.toList()..sort();
      double percentile(double p) => sorted[(sorted.length * p).ceil() - 1];
      // ignore: avoid_print
      print(
        jsonEncode({
          'variant': variant,
          'runIndex': runIndex + 1,
          'fixture': fixture.key,
          'characters': fixture.value.length,
          'unit': 'microseconds',
          'callsPerSample': callsPerSample,
          'sampleKind': callsPerSample == 1
              ? 'single_call'
              : 'batch_mean_per_call',
          'p50': percentile(.50),
          'p95': percentile(.95),
          'p99': percentile(.99),
          'samples': samples,
        }),
      );
    }
  }
}
