import 'package:checks/checks.dart';
import 'package:conduit/core/services/sse_frame_scanner.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('SseFrameScanner', () {
    test('emits data with the event field', () {
      final scanner = SseFrameScanner();
      final frames = [
        ...scanner.addChunk('event: tool.started\ndata: {"tool":"web"}\n\n'),
        ...scanner.close(),
      ];
      check(frames).has((f) => f.length, 'length').equals(1);
      check(frames[0].event).equals('tool.started');
      check(frames[0].data).equals('{"tool":"web"}');
    });

    test('joins multiple data lines and defaults event to null', () {
      final scanner = SseFrameScanner();
      final frames = [
        ...scanner.addChunk('data: line1\ndata: line2\n\n'),
        ...scanner.close(),
      ];
      check(frames).has((f) => f.length, 'length').equals(1);
      check(frames[0].event).isNull();
      check(frames[0].data).equals('line1\nline2');
    });

    test('handles frames split across chunks and CRLF boundaries', () {
      final scanner = SseFrameScanner();
      final frames = [
        ...scanner.addChunk('event: a\r\ndata: {"x":'),
        ...scanner.addChunk('1}\r\n\r\n'),
        ...scanner.close(),
      ];
      check(frames).has((f) => f.length, 'length').equals(1);
      check(frames[0].event).equals('a');
      check(frames[0].data).equals('{"x":1}');
    });

    test('skips event-only frames with no data line', () {
      final scanner = SseFrameScanner();
      final frames = [
        ...scanner.addChunk('event: ping\n\ndata: real\n\n'),
        ...scanner.close(),
      ];
      check(frames).has((f) => f.length, 'length').equals(1);
      check(frames[0].data).equals('real');
    });

    test('emits an explicitly empty data event', () {
      final scanner = SseFrameScanner();
      final frames = scanner
          .addChunk('event: run.completed\ndata:\n\n')
          .toList();

      check(frames).has((f) => f.length, 'length').equals(1);
      check(frames.single.event).equals('run.completed');
      check(frames.single.data).isEmpty();
    });

    test('discards an unterminated frame at EOF', () {
      final scanner = SseFrameScanner();
      final frames = [
        ...scanner.addChunk('event: message\ndata: {"partial":'),
        ...scanner.close(),
      ];

      check(frames).isEmpty();
    });
  });
}
