import 'dart:convert';

import 'package:conduit/features/chat/views/chat_page.dart';
import 'package:conduit_core/models/chat_message.dart';
import 'package:flutter/widgets.dart';

// Profile-mode CPU comparison using newly invented content; no server access.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const SizedBox.shrink());
  await Future<void>.delayed(const Duration(milliseconds: 500));

  var run = 0;
  for (final padded in [false, true]) {
    for (final size in [8192, 131072, 1048576]) {
      final body = List.filled(
        size ~/ 20 + 1,
        'Synthetic paragraph. ',
      ).join().substring(0, size);
      final messages = List.generate(
        12,
        (index) => ChatMessage(
          id: 'synthetic-$index',
          role: 'assistant',
          content:
              '${padded ? '  ' : ''}Row $index. $body End.${padded ? '  ' : ''}',
          timestamp: DateTime(2026),
        ),
      );
      for (final cached in [false, true, true, false]) {
        final cache = MarkdownPrewarmEligibilityCache();
        final String Function(ChatMessage) contentFor = cached
            ? (message) =>
                  cache.isEligible(message) ? message.content.trim() : ''
            : _uncachedContent;
        for (final message in messages) {
          contentFor(message);
        }
        final timings = <double>[];
        var characters = 0;
        for (var sample = 0; sample < 100; sample++) {
          final watch = Stopwatch()..start();
          for (final message in messages) {
            characters += contentFor(message).length;
          }
          timings.add(watch.elapsedTicks * 1000000 / watch.frequency);
          await Future<void>.delayed(Duration.zero);
        }
        final sorted = [...timings]..sort();
        debugPrint(
          'MARKDOWN_PREWARM_RESULT ${jsonEncode({
            'run': run,
            'padded': padded,
            'cached': cached,
            'payloadCharactersPerMessage': size,
            'messages': messages.length,
            'samples': timings.length,
            'batchMicroseconds': {'p50': sorted[49], 'p95': sorted[94], 'p99': sorted[98], 'max': sorted.last},
            'processedCharacters': characters,
          })}',
        );
        // Keep each line below Android's log truncation limit.
        for (var offset = 0; offset < timings.length; offset += 20) {
          debugPrint(
            'MARKDOWN_PREWARM_SAMPLES ${jsonEncode({'run': run, 'offset': offset, 'values': timings.sublist(offset, offset + 20)})}',
          );
        }
        run++;
      }
    }
  }
  debugPrint('MARKDOWN_PREWARM_DONE');
}

String _uncachedContent(ChatMessage message) {
  if (message.role != 'assistant' || message.isStreaming) return '';
  final content = message.content.trim();
  return content.contains('data:image/') ? '' : content;
}
