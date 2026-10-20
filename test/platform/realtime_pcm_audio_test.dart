import 'package:checks/checks.dart';
import 'package:conduit/platform/realtime_pcm_audio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const methods = MethodChannel('app.cogwheel.conduit/realtime_audio');
  const events = EventChannel('app.cogwheel.conduit/realtime_audio/events');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late List<MethodCall> calls;
  late MockStreamHandlerEventSink sink;

  setUp(() {
    calls = [];
    messenger.setMockMethodCallHandler(methods, (call) async {
      calls.add(call);
      if (call.method == 'clear') {
        return [
          {
            'responseId': 'resp-1',
            'itemId': 'item-1',
            'contentIndex': 0,
            'samples': 2400,
          },
        ];
      }
      return null;
    });
    messenger.setMockStreamHandler(
      events,
      MockStreamHandler.inline(onListen: (arguments, events) => sink = events),
    );
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(methods, null);
    messenger.setMockStreamHandler(events, null);
  });

  test('reports, frames and failures arrive as the port speaks them', () async {
    final audio = MethodChannelRealtimePcmAudio();
    final reports = <int>[];
    final frames = <int>[];
    final failures = <String>[];
    audio.reports.listen((report) => reports.add(report.queuedSamples));
    audio.captureFrames.listen((frame) => frames.add(frame.length));
    audio.failures.listen(failures.add);

    await audio.start();
    sink.success({
      'type': 'report',
      'clearId': 2,
      'playbackActive': true,
      'queued': 480,
      'received': 9600,
      'inputLevel': 0.1,
      'outputLevel': 0.2,
      'outputLatencyMs': 35,
    });
    sink.success({'type': 'frame', 'pcm': Uint8List(1920)});
    sink.success({'type': 'failure', 'message': 'The microphone stopped.'});
    await pumpEventQueue();

    check(calls.single.method).equals('start');
    check(reports).deepEquals([480]);
    check(audio.outputLatency).equals(const Duration(milliseconds: 35));
    check(frames).deepEquals([1920]);
    check(failures).deepEquals(['The microphone stopped.']);
    await audio.stop();
  });

  test('a clear returns what was played of each item', () async {
    final audio = MethodChannelRealtimePcmAudio();

    final rendered = await audio.clear(3);

    check(calls.single.arguments)
        .isA<Map<Object?, Object?>>()
        .deepEquals({'clearId': 3});
    check(rendered).deepEquals([
      (responseId: 'resp-1', itemId: 'item-1', contentIndex: 0, samples: 2400),
    ]);
  });
}
