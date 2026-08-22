import 'dart:typed_data';

import 'package:conduit/core/models/backend_config.dart';
import 'package:conduit/core/models/server_config.dart';
import 'package:conduit/core/services/api_service.dart';
import 'package:conduit/core/services/worker_manager.dart';
import 'package:conduit/features/chat/services/tts_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';

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

    test('strips a completed reasoning block', () {
      final chunks = TtsManager.instance.getMessageContentParts(
        'Checking that now. '
        '<details type="reasoning" done="true" duration="4">'
        '<summary>Thought for 4 seconds</summary>'
        '> The user wants the entity list, so call the tool.'
        '</details>'
        'The living room light is on.',
      );

      expect(chunks.join(' '), isNot(contains('entity list')));
      expect(chunks.join(' '), contains('The living room light is on.'));
    });

    test('withholds the body of a reasoning block that is still open', () {
      final chunks = TtsManager.instance.getMessageContentParts(
        'Checking that now. '
        '<details type="reasoning" done="false">'
        '<summary>Thinking…</summary>'
        '> The user wants the entity list, so call the tool.',
      );

      expect(chunks, ['Checking that now.']);
    });

    test('withholds the body of a tool call block that is still open', () {
      final chunks = TtsManager.instance.getMessageContentParts(
        'One moment. '
        '<details type="tool_calls" done="false" name="get_entities">'
        '<summary>Tool</summary>'
        '{"entities": ["light.living_room", "light.kitchen"]}',
      );

      expect(chunks, ['One moment.']);
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

  group('TtsManager streaming chunk advance', () {
    List<String> speakStream(List<String> frames) {
      final spoken = <String>[];
      var fedChunkCount = 0;
      String? lastFedChunk;

      for (var index = 0; index < frames.length; index++) {
        final advance = advanceStreamingChunksForTesting(
          chunks: TtsManager.instance.getMessageContentParts(frames[index]),
          fedChunkCount: fedChunkCount,
          lastFedChunk: lastFedChunk,
          finalized: index == frames.length - 1,
        );
        spoken.addAll(advance.chunks);
        fedChunkCount = advance.fedChunkCount;
        lastFedChunk = advance.lastFedChunk;
      }

      return spoken;
    }

    test('never speaks a reasoning block and still speaks the answer', () {
      const opening = 'Let me look that up for you right now. ';
      const reasoning =
          '<details type="reasoning" done="false">'
          '<summary>Thinking…</summary>'
          '> The user asked which lights are on. '
          '> I should call the entity listing tool first.';
      const closedReasoning =
          '<details type="reasoning" done="true" duration="4">'
          '<summary>Thought for 4 seconds</summary>'
          '> The user asked which lights are on. '
          '> I should call the entity listing tool first.'
          '</details>';
      const answer =
          'The living room light is on and every other light is off. '
          'Nothing else in the house is currently switched on.';

      final spoken = speakStream([
        opening,
        '$opening<details type="reasoning" done="false"><summary>Thinking…</summary>',
        '$opening$reasoning',
        '$opening$closedReasoning',
        '$opening${closedReasoning}The living room light is on and every '
            'other light is off. ',
        '$opening$closedReasoning$answer',
      ]);

      final transcript = spoken.join(' ');
      expect(transcript, isNot(contains('entity listing tool')));
      expect(transcript, isNot(contains('Thinking')));
      expect(transcript, isNot(contains('Thought for 4 seconds')));
      expect(
        transcript,
        contains('The living room light is on and every other light is off.'),
      );
      expect(
        transcript,
        contains('Nothing else in the house is currently switched on.'),
      );
    });

    test('speaks every answer sentence exactly once', () {
      final spoken = speakStream([
        'The first sentence carries enough words to stand alone. ',
        'The first sentence carries enough words to stand alone. '
            'The second sentence also carries enough words to stand alone. ',
        'The first sentence carries enough words to stand alone. '
            'The second sentence also carries enough words to stand alone. '
            'The third sentence closes out the response body.',
      ]);

      final transcript = spoken.join(' ');
      for (final sentence in const [
        'The first sentence carries enough words to stand alone.',
        'The second sentence also carries enough words to stand alone.',
        'The third sentence closes out the response body.',
      ]) {
        expect(sentence.allMatches(transcript).length, 1, reason: sentence);
      }
    });

    test('re-anchors the cursor when a late re-split shifts chunks left', () {
      // Chunks 1 and 2 dropped out of the split (a `</details>` landed and the
      // block was stripped), so the answer moved from index 3 down to index 1.
      final advance = advanceStreamingChunksForTesting(
        chunks: const ['Opening line.', 'Answer one.', 'Answer two.'],
        fedChunkCount: 3,
        lastFedChunk: 'Opening line.',
        finalized: true,
      );

      expect(advance.chunks, ['Answer one.', 'Answer two.']);
      expect(advance.fedChunkCount, 3);
      expect(advance.lastFedChunk, 'Answer two.');
    });

    test('holds the trailing chunk back until finalization', () {
      final advance = advanceStreamingChunksForTesting(
        chunks: const ['Answer one.', 'Answer two.'],
        fedChunkCount: 0,
        lastFedChunk: null,
        finalized: false,
      );

      expect(advance.chunks, ['Answer one.']);
      expect(advance.fedChunkCount, 1);
      expect(advance.lastFedChunk, 'Answer one.');
    });

    test('stays put when the anchor is gone entirely', () {
      final advance = advanceStreamingChunksForTesting(
        chunks: const ['Rewritten one.', 'Rewritten two.', 'Rewritten three.'],
        fedChunkCount: 2,
        lastFedChunk: 'Original two.',
        finalized: true,
      );

      expect(advance.chunks, ['Rewritten three.']);
      expect(advance.fedChunkCount, 3);
    });
  });

  group('TtsManager server streaming completion', () {
    test('does not complete while final chunk is still playing', () {
      final completed = isServerTtsPlaybackCompleteForTesting(
        processingState: ProcessingState.ready,
        currentIndex: 2,
        lastChunkIndex: 2,
        lastEnqueuedIndex: 2,
      );

      expect(completed, isFalse);
    });

    test('completes only after final chunk playback completes', () {
      final completed = isServerTtsPlaybackCompleteForTesting(
        processingState: ProcessingState.completed,
        currentIndex: 2,
        lastChunkIndex: 2,
        lastEnqueuedIndex: 2,
      );

      expect(completed, isTrue);
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
