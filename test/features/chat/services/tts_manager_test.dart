import 'dart:typed_data';

import 'package:conduit/core/models/backend_config.dart';
import 'package:conduit/core/models/server_config.dart';
import 'package:conduit/core/services/api_service.dart';
import 'package:conduit/core/services/worker_manager.dart';
import 'package:conduit/features/chat/services/tts_manager.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('TtsManager splitTextForSpeech', () {
    const sampleText =
        'Curious engineers optimize audio boundaries for smoother '
        'conversations. Another sentence follows to verify chunk '
        'merging behavior.';

    test('keeps sentence-level chunks for device mode', () async {
      await TtsManager.instance.updateConfig(
        const TtsConfig(preferServer: false),
      );

      final chunks = TtsManager.instance.splitTextForSpeech(sampleText);

      expect(chunks.length, 2);
    });

    test('keeps OpenWebUI-sized chunks for server mode', () async {
      await TtsManager.instance.updateConfig(
        const TtsConfig(preferServer: true),
      );

      final chunks = TtsManager.instance.splitTextForSpeech(sampleText);

      expect(chunks.length, 2);
    });
  });

  group('TtsManager getMessageContentParts', () {
    test('supports paragraphs mode like OpenWebUI', () {
      final chunks = TtsManager.instance.getMessageContentParts(
        'First paragraph\n\nSecond paragraph',
        splitOn: TtsManager.splitOnParagraphs,
      );

      expect(chunks, ['First paragraph', 'Second paragraph']);
    });

    test('supports none mode like OpenWebUI', () {
      final chunks = TtsManager.instance.getMessageContentParts(
        'One.\nTwo.',
        splitOn: TtsManager.splitOnNone,
      );

      expect(chunks, ['One.\nTwo.']);
    });

    test('strips details blocks before splitting', () {
      final chunks = TtsManager.instance.getMessageContentParts(
        'Hello <details><summary>Hidden</summary>ignored</details> world.',
      );

      expect(chunks, ['Hello  world.']);
    });

    test('cleans markdown internally without caller preprocessing', () {
      final chunks = TtsManager.instance.getMessageContentParts(
        '## **Hello**\n- world',
        splitOn: TtsManager.splitOnNone,
      );

      expect(chunks, ['Hello\nworld']);
    });
  });

  group('TtsManager server voice resolution', () {
    late _RecordingApiService api;

    setUp(() async {
      api = _RecordingApiService();
      TtsManager.instance.setApiService(api);
      await TtsManager.instance.reset();
      await TtsManager.instance.updateConfig(
        const TtsConfig(preferServer: true),
      );
    });

    tearDown(() async {
      TtsManager.instance.setApiService(null);
      await TtsManager.instance.reset();
      api.disposeWorker();
    });

    test('does not reuse a device voice for server synthesis', () async {
      await TtsManager.instance.updateConfig(
        const TtsConfig(voice: 'en-us-x-sfg#male_1-local', preferServer: true),
      );

      await TtsManager.instance.synthesizeChunk('Hello from the server');

      expect(api.lastVoice, isNull);
    });

    test('uses backend default voice when available', () async {
      TtsManager.instance.applyBackendConfig(
        const BackendConfig(ttsVoice: 'nova'),
      );

      await TtsManager.instance.synthesizeChunk('Hello from the server');

      expect(api.lastVoice, 'nova');
    });

    test('uses the explicitly selected server voice when present', () async {
      await TtsManager.instance.updateConfig(
        const TtsConfig(
          voice: 'en-us-x-sfg#male_1-local',
          serverVoice: 'shimmer',
          preferServer: true,
        ),
      );

      await TtsManager.instance.synthesizeChunk('Hello from the server');

      expect(api.lastVoice, 'shimmer');
    });
  });
}

class _RecordingApiService extends ApiService {
  _RecordingApiService._(this._workerManager)
    : super(
        serverConfig: const ServerConfig(
          id: 'test-server',
          name: 'Test Server',
          url: 'https://example.com',
        ),
        workerManager: _workerManager,
      );

  factory _RecordingApiService() =>
      _RecordingApiService._(WorkerManager(maxConcurrentTasks: 1));

  final WorkerManager _workerManager;
  String? lastVoice;

  @override
  Future<({Uint8List bytes, String mimeType})> generateSpeech({
    required String text,
    String? voice,
    double? speed,
  }) async {
    lastVoice = voice;
    return (bytes: Uint8List.fromList(const [1, 2, 3]), mimeType: 'audio/mpeg');
  }

  void disposeWorker() {
    _workerManager.dispose();
  }
}
