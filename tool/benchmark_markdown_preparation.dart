// Compile with `dart compile exe tool/benchmark_markdown_preparation.dart`.
// Uses production preparation with metrics/parity checks disabled, as in release.
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:conduit_core/utils/streaming_markdown_preparation.dart';

void main() {
  final results = <Map<String, Object>>[];
  for (final size in [4096, 32768, 131072]) {
    for (final kind in ['prose', 'markdown', 'reference']) {
      final block = switch (kind) {
        'markdown' =>
          '## Synthetic section\n\nA **bold** result and `value]:` '
              'with [a link](https://example.com).\n\n'
              '```dart\nfinal answer = 42;\n```\n\n',
        'reference' => 'A synthetic paragraph with [a reference][sample].\n\n',
        _ =>
          'A synthetic paragraph describes a blue triangle and an orange '
              'circle. Each shape has a numbered label.\n\n',
      };
      var content = List.filled((size / block.length).ceil(), block).join();
      content = content.substring(0, size);
      if (kind == 'reference') {
        content += '\n\n[sample]: https://example.com\n';
      }
      final snapshots = [
        for (var end = 128; end < content.length; end += 128)
          content.substring(0, end),
        content,
      ];
      final runs = <List<double>>[];
      for (var run = 0; run < 9; run++) {
        final engine = StreamingMarkdownPreparationEngine();
        var prepared = const PreparedMarkdownText.empty();
        final samples = <double>[];
        final clock = Stopwatch();
        for (var i = 0; i < snapshots.length; i++) {
          final request = MarkdownPreparationRequest(
            sessionId: 'synthetic-stream',
            revision: i + 1,
            expectedBaseRevision: i,
            content: snapshots[i],
            streaming: true,
            collectMetrics: false,
          );
          clock.reset();
          clock.start();
          final patch = engine.prepare(request);
          clock.stop();
          samples.add(clock.elapsedTicks * 1000000 / clock.frequency);
          // Consumer application and parity checks are outside the measured stage.
          prepared = prepared.applyPatch(patch);
        }
        if (prepared.materialize() !=
            prepareMarkdownContentCanonical(content, streaming: true)) {
          throw StateError('Preparation diverged for $kind/$size');
        }
        if (run >= 2) runs.add(samples);
      }
      final samples = runs.expand((run) => run).toList()..sort();
      final totals = runs.map((r) => r.reduce((a, b) => a + b)).toList()
        ..sort();
      double percentile(List<double> values, double fraction) =>
          values[math.max(0, (values.length * fraction).ceil() - 1)];
      results.add({
        'kind': kind,
        'characters': content.length,
        'chunkCharacters': 128,
        'warmupRuns': 2,
        'measuredRuns': runs.length,
        'samples': samples.length,
        'microseconds': {
          'p50': percentile(samples, .50),
          'p95': percentile(samples, .95),
          'p99': percentile(samples, .99),
          'max': samples.last,
          'totalPerStreamP50': percentile(totals, .50),
        },
        'runsMicroseconds': runs,
      });
    }
  }
  stdout.writeln(
    jsonEncode({
      'dart': Platform.version,
      'operatingSystem': Platform.operatingSystem,
      'benchmark': 'streaming-markdown-preparation',
      'results': results,
    }),
  );
}
