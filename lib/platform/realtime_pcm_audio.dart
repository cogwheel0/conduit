import 'dart:async';

import 'package:conduit_core/features/chat/realtime_call/realtime_call_ports.dart';
import 'package:flutter/services.dart';

/// The native realtime audio engine: `RealtimeAudioBridge` on iOS and
/// Android, which captures and plays on one echo-cancelled stream.
final class MethodChannelRealtimePcmAudio implements RealtimePcmAudioPort {
  static const _methods = MethodChannel('app.cogwheel.conduit/realtime_audio');
  static const _events = EventChannel(
    'app.cogwheel.conduit/realtime_audio/events',
  );

  final _frames = StreamController<Uint8List>.broadcast();
  final _reports = StreamController<RealtimePlaybackReport>.broadcast();
  final _failures = StreamController<String>.broadcast();
  StreamSubscription<Object?>? _subscription;
  var _outputLatency = Duration.zero;

  @override
  Stream<Uint8List> get captureFrames => _frames.stream;

  @override
  Stream<RealtimePlaybackReport> get reports => _reports.stream;

  @override
  Stream<String> get failures => _failures.stream;

  @override
  Duration get outputLatency => _outputLatency;

  @override
  Future<void> start() async {
    _subscription ??= _events.receiveBroadcastStream().listen(
      _onEvent,
      onError: (Object _) => _failures.add('The call audio stopped.'),
    );
    await _methods.invokeMethod<void>('start');
  }

  void _onEvent(Object? event) {
    if (event is! Map) return;
    switch (event['type']) {
      case 'frame':
        final pcm = event['pcm'];
        if (pcm is Uint8List) _frames.add(pcm);
      case 'report':
        final latency = event['outputLatencyMs'];
        if (latency is int) _outputLatency = Duration(milliseconds: latency);
        _reports.add(
          RealtimePlaybackReport(
            clearId: event['clearId'] as int? ?? 0,
            playbackActive: event['playbackActive'] == true,
            queuedSamples: event['queued'] as int? ?? 0,
            receivedSamples: event['received'] as int? ?? 0,
            inputLevel: (event['inputLevel'] as num?)?.toDouble() ?? 0,
            outputLevel: (event['outputLevel'] as num?)?.toDouble() ?? 0,
          ),
        );
      case 'failure':
        final message = event['message'];
        _failures.add(message is String ? message : 'The call audio stopped.');
    }
  }

  @override
  void setCaptureEnabled(bool enabled) => unawaited(
    _methods.invokeMethod<void>('setCaptureEnabled', {'enabled': enabled}),
  );

  @override
  void enqueue({
    required String responseId,
    required String itemId,
    required int contentIndex,
    required Uint8List pcm,
  }) => unawaited(
    _methods.invokeMethod<void>('enqueue', {
      'responseId': responseId,
      'itemId': itemId,
      'contentIndex': contentIndex,
      'pcm': pcm,
    }),
  );

  @override
  void endResponse(String responseId) => unawaited(
    _methods.invokeMethod<void>('endResponse', {'responseId': responseId}),
  );

  @override
  Future<List<RealtimeRenderedItem>> clear(int clearId) async {
    final rendered =
        await _methods.invokeListMethod<Map<Object?, Object?>>('clear', {
          'clearId': clearId,
        }) ??
        const [];
    return [
      for (final item in rendered)
        (
          responseId: item['responseId'] as String,
          itemId: item['itemId'] as String,
          contentIndex: item['contentIndex'] as int,
          samples: item['samples'] as int,
        ),
    ];
  }

  @override
  Future<void> stop() async {
    try {
      await _methods.invokeMethod<void>('stop');
    } finally {
      await _subscription?.cancel();
      _subscription = null;
      await _frames.close();
      await _reports.close();
      await _failures.close();
    }
  }
}
