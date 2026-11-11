import 'dart:convert';
import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/worker_manager.dart';
import 'package:dio/dio.dart';
import 'package:test/test.dart';

const _server = ServerConfig(
  id: 'test-server',
  name: 'Test Server',
  url: 'https://server.example',
  isActive: true,
);

/// Records each request and answers it with a transcript.
final class _Adapter implements HttpClientAdapter {
  final requests = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return ResponseBody.fromString(
      jsonEncode({'text': 'hello'}),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  late _Adapter adapter;
  late ApiService api;

  setUp(() {
    adapter = _Adapter();
    api = ApiService(
      serverConfig: _server,
      workerManager: WorkerManager(),
      authToken: 'session',
    );
    api.dio.httpClientAdapter = adapter;
  });

  tearDown(() => api.dispose());

  // A stop waiting for this transcript, and any start queued behind it,
  // would otherwise wait on an upload that has stalled.
  test('gives up on a transcription upload in time for its size', () async {
    // 24 MiB takes 192 s at 128 KiB/s, past the five-minute floor.
    final audio = Uint8List(24 * 1024 * 1024);

    await api.transcribeSpeech(
      audioBytes: audio,
      fileName: 'speech.wav',
      mimeType: 'audio/wav',
    );

    final upload = adapter.requests.single;
    check(upload.path).equals('/api/v1/audio/transcriptions');
    check(upload.sendTimeout).equals(const Duration(seconds: 312));
  });
}
