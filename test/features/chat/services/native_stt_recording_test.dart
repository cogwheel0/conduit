import 'dart:async';

import 'package:conduit/features/chat/services/native_stt_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('app.cogwheel.conduit/native_stt');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test(
    'cancellation belongs to one saved recording, not another owner',
    () async {
      final pending = <String, Completer<String>>{};
      final cancelled = <String>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        final args = call.arguments as Map;
        final id = args['requestId'] as String;
        if (call.method == 'cancelRecordingTranscription') {
          cancelled.add(id);
          return null;
        }
        expect(args['pcm'], [1, 0, 2, 0]);
        expect(args['localeId'], 'en-US');
        return (pending[id] = Completer<String>()).future;
      });
      final first = NativeSttService();
      final second = NativeSttService();
      final bytes = Uint8List.fromList([1, 0, 2, 0]);
      final a = first.transcribeRecording(bytes, localeId: 'en-US');
      final b = second.transcribeRecording(bytes, localeId: 'en-US');
      await Future<void>.delayed(Duration.zero);
      final ids = pending.keys.toList();
      expect(ids, hasLength(2));
      await first.cancelRecordingTranscription();
      expect(cancelled, [ids.first]);
      pending[ids.first]!.complete('old result');
      pending[ids.last]!.complete('  amber tiles  ');
      expect(await a, 'old result');
      expect(await b, 'amber tiles');
      await second.cancelRecordingTranscription();
      expect(cancelled, [ids.first]);
    },
  );

  test('empty transcription reports a retryable failure', () async {
    var attempts = 0;
    messenger.setMockMethodCallHandler(
      channel,
      (_) async => ++attempts == 1 ? ' ' : 'four tiles',
    );
    final service = NativeSttService();
    final bytes = Uint8List.fromList([1, 0]);
    await expectLater(
      service.transcribeRecording(bytes),
      throwsA(isA<NativeSttException>()),
    );
    expect(await service.transcribeRecording(bytes), 'four tiles');
  });

  test(
    'an old completion cannot clear a newer request after cancellation',
    () async {
      final pending = <Completer<String>>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'cancelRecordingTranscription') return null;
        final result = Completer<String>();
        pending.add(result);
        return result.future;
      });
      final service = NativeSttService();
      final bytes = Uint8List.fromList([1, 0]);
      final first = service.transcribeRecording(bytes);
      await Future<void>.delayed(Duration.zero);
      await service.cancelRecordingTranscription();
      final second = service.transcribeRecording(bytes);
      await Future<void>.delayed(Duration.zero);
      pending.first.complete('old');
      await first;
      await expectLater(
        service.transcribeRecording(bytes),
        throwsA(isA<NativeSttException>()),
      );
      pending.last.complete('new');
      expect(await second, 'new');
    },
  );
}
