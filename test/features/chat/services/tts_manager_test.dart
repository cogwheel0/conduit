import 'dart:typed_data';

import 'package:conduit/core/models/backend_config.dart';
import 'package:conduit/core/models/server_config.dart';
import 'package:conduit/core/services/api_service.dart';
import 'package:conduit/core/services/worker_manager.dart';
import 'package:conduit/features/chat/services/native_tts_service.dart';
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

  group('TtsManager device audio route', () {
    late _FakeNativeTtsService native;

    setUp(() async {
      native = _FakeNativeTtsService();
      await TtsManager.instance.debugSetNativeTtsService(native);
      await TtsManager.instance.updateConfig(
        const TtsConfig(preferServer: false),
      );
    });

    tearDown(() async {
      TtsManager.instance.setVoiceCallActive(false);
      await TtsManager.instance.reset();
      await TtsManager.instance.debugSetNativeTtsService(null);
    });

    test('speaks on the call route during a voice call', () async {
      // Android routes voice-communication and media output separately, so a
      // media-stream utterance ignores the call's speakerphone choice and goes
      // silent once the app is backgrounded mid-call.
      TtsManager.instance.setVoiceCallActive(true);

      await TtsManager.instance.speak('Hello there.');

      expect(native.voiceCallFlags, [true]);
    });

    test('speaks on the media route for read aloud', () async {
      await TtsManager.instance.speak('Hello there.');

      expect(native.voiceCallFlags, [false]);
    });

    test('returns to the media route after the call ends', () async {
      TtsManager.instance.setVoiceCallActive(true);
      await TtsManager.instance.speak('During the call.');
      TtsManager.instance.setVoiceCallActive(false);

      await TtsManager.instance.speak('After the call.');

      expect(native.voiceCallFlags, [true, false]);
    });

    test('returns to the media route after a reset', () async {
      // Nothing hands the route back when the service is disposed out from
      // under a live call, so read aloud would keep speaking at call volume.
      TtsManager.instance.setVoiceCallActive(true);
      await TtsManager.instance.speak('During the call.');

      await TtsManager.instance.reset();
      await TtsManager.instance.speak('After the call.');

      expect(native.voiceCallFlags, [true, false]);
    });

    test('does not hand a session id back out after a reset', () async {
      // A feed queued on the old chain only checks the active session's id, so
      // a reused id lets it append its stale text to the next session.
      final first = await TtsManager.instance.speak('During the call.');

      await TtsManager.instance.reset();
      final second = await TtsManager.instance.speak('After the call.');

      expect(second!.id, greaterThan(first!.id));
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
      var spokenText = '';

      for (var index = 0; index < frames.length; index++) {
        final advance = advanceStreamingChunksForTesting(
          chunks: TtsManager.instance.getMessageContentParts(frames[index]),
          fedChunkCount: fedChunkCount,
          spokenText: spokenText,
          finalized: index == frames.length - 1,
        );
        spoken.addAll(advance.chunks);
        fedChunkCount = advance.fedChunkCount;
        spokenText = advance.spokenText;
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
        spokenText: 'Opening line.',
        finalized: true,
      );

      expect(advance.chunks, ['Answer one.', 'Answer two.']);
      expect(advance.fedChunkCount, 3);
    });

    test('holds the trailing chunk back until finalization', () {
      final advance = advanceStreamingChunksForTesting(
        chunks: const ['Answer one.', 'Answer two.'],
        fedChunkCount: 0,
        spokenText: '',
        finalized: false,
      );

      expect(advance.chunks, ['Answer one.']);
      expect(advance.fedChunkCount, 1);
      expect(advance.spokenText, 'Answer one.');
    });

    test('resumes where a rewritten response stops agreeing', () {
      // The server replaced the tail of the answer. Everything up to the point
      // the two versions diverge has been spoken already.
      final advance = advanceStreamingChunksForTesting(
        chunks: const ['Original one.', 'Rewritten two.', 'Rewritten three.'],
        fedChunkCount: 2,
        spokenText: 'Original one.Original two.',
        finalized: true,
      );

      expect(advance.chunks, ['Rewritten two.', 'Rewritten three.']);
      expect(advance.fedChunkCount, 3);
    });

    test('keeps its place when the answer repeats a sentence', () {
      // 'Right away.' appears twice and a `</details>` landing between them
      // shifted the split left, so the spoken copy is now at index 1. Anchoring
      // on the chunk's text alone would match the second copy and skip the two
      // sentences in between.
      final advance = advanceStreamingChunksForTesting(
        chunks: const [
          'Intro.',
          'Right away.',
          'Middle line.',
          'Right away.',
          'Tail.',
        ],
        fedChunkCount: 4,
        spokenText: 'Intro.Right away.',
        finalized: true,
      );

      expect(advance.chunks, ['Middle line.', 'Right away.', 'Tail.']);
      expect(advance.fedChunkCount, 5);
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

class _FakeNativeTtsService extends NativeTtsService {
  final List<bool> voiceCallFlags = <bool>[];

  @override
  bool get isSupportedPlatform => true;

  @override
  Future<bool> isAvailable() async => true;

  @override
  Stream<NativeTtsEvent> get events => const Stream<NativeTtsEvent>.empty();

  @override
  Future<List<Map<String, dynamic>>> getVoices() async =>
      const <Map<String, dynamic>>[];

  @override
  Future<bool> speak({
    required String text,
    String? voiceIdentifier,
    required double rate,
    required double pitch,
    required double volume,
    bool voiceCall = false,
  }) async {
    voiceCallFlags.add(voiceCall);
    return true;
  }

  @override
  Future<bool> stop() async => true;
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
