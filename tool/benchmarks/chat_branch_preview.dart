// Compile with `dart compile exe` and run with a revision label as argument.
// Synthetic stored-graph parsing only; no database or server connection.
import 'dart:convert';

import 'package:conduit_core/features/chat/services/chat_branch_service.dart';

void main(List<String> args) {
  const prose = 'A blue square.  ';
  const unicode = '🟦 漢字\tgreen\n';
  for (final size in [8192, 131072, 1048576]) {
    final fixtures = <String, String>{
      'prose': List.filled((size / prose.length).ceil(), prose).join(),
      'unbroken-token': 'x' * size,
      'leading-whitespace': '${' ' * size}A blue square.',
      'trailing-whitespace': 'A blue square.${' ' * size}',
      'unicode': List.filled((size / unicode.length).ceil(), unicode).join(),
    };
    for (final fixture in fixtures.entries) {
      final envelope = <String, dynamic>{
        'chat': {
          'history': {
            'messages': {
              for (var i = 0; i < 8; i++)
                'synthetic-$i': {
                  'role': 'assistant',
                  'content': fixture.value,
                  'childrenIds': <String>[],
                },
            },
          },
        },
      };
      final expected = ChatBranchGraph.fromEnvelope(envelope)
          .siblingsOf('synthetic-0')!
          .previews;
      for (var warmup = 0; warmup < 5; warmup++) {
        ChatBranchGraph.fromEnvelope(envelope);
      }
      final samples = <double>[];
      for (var sample = 0; sample < 100; sample++) {
        final watch = Stopwatch()..start();
        final graph = ChatBranchGraph.fromEnvelope(envelope);
        watch.stop();
        samples.add(watch.elapsedTicks * 1000000 / watch.frequency);
        final result = graph.siblingsOf('synthetic-0')!;
        if (result.ids.length != 8 ||
            result.previews.entries.any((e) => expected[e.key] != e.value)) {
          throw StateError('Graph or previews changed');
        }
      }
      final sorted = samples.toList()..sort();
      double percentile(double p) => sorted[(sorted.length * p).ceil() - 1];
      // ignore: avoid_print
      print(
        jsonEncode({
          'revision': args.firstOrNull ?? 'working-tree',
          'fixture': fixture.key,
          'targetSize': size,
          'charactersPerMessage': fixture.value.length,
          'messages': 8,
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
