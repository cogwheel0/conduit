import 'dart:io';

import 'package:conduit/features/direct_connections/models/direct_completion.dart';
import 'package:conduit/features/direct_connections/models/direct_connection_profile.dart';
import 'package:conduit/features/direct_connections/services/ollama_adapter.dart';
import 'package:conduit/features/direct_connections/services/openai_compatible_adapter.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final enabled = Platform.environment['DIRECT_LIVE_TESTS'] == '1';
  final baseUrl = Platform.environment['OPENAI_URL']?.trim() ?? '';
  final apiKey = Platform.environment['OPENAI_API']?.trim() ?? '';
  final skipReason = enabled && baseUrl.isNotEmpty
      ? false
      : 'Set DIRECT_LIVE_TESTS=1 and OPENAI_URL to run live provider tests.';

  test(
    'OpenAI-compatible live endpoint streams a typed completion',
    () async {
      final adapter = OpenAiCompatibleAdapter();
      final profile = DirectConnectionProfile(
        id: 'live-openai-compatible',
        name: 'Live OpenAI-compatible endpoint',
        adapterKey: kOpenAiCompatibleAdapterKey,
        baseUrl: baseUrl,
        apiKey: apiKey.isEmpty ? null : apiKey,
      );
      final models = await adapter.listModels(profile);
      expect(models, isNotEmpty);
      final chatModels = models
          .where((candidate) => !_looksNonChatModel(candidate.id))
          .toList(growable: false);
      expect(
        chatModels,
        isNotEmpty,
        reason: 'The endpoint did not advertise a chat-capable model.',
      );
      final model = chatModels.firstWhere(
        (candidate) => _looksReasoningModel(candidate.id),
        orElse: () => chatModels.first,
      );

      final run = adapter.startCompletion(
        profile,
        DirectCompletionRequest(
          remoteModelId: model.id,
          messages: [
            DirectChatMessage.text(
              role: 'user',
              text:
                  'Think briefly before answering, then reply with exactly: OK',
            ),
          ],
          parameters: const {'max_tokens': 128, 'temperature': 0},
        ),
      );
      final events = await run.events
          .timeout(const Duration(seconds: 90))
          .toList();
      await run.done;

      expect(events.whereType<DirectStreamError>(), isEmpty);
      expect(events.whereType<DirectStreamDone>(), hasLength(1));
      expect(
        events.whereType<DirectContentDelta>().isNotEmpty ||
            events.whereType<DirectReasoningDelta>().isNotEmpty,
        isTrue,
      );
      if (Platform.environment['DIRECT_EXPECT_REASONING'] == '1') {
        expect(
          events.whereType<DirectReasoningDelta>(),
          isNotEmpty,
          reason:
              'The configured live endpoint is expected to stream thinking.',
        );
      }
    },
    skip: skipReason,
    timeout: const Timeout(Duration(minutes: 2)),
  );

  final ollamaBaseUrl = Platform.environment['OLLAMA_URL']?.trim() ?? '';
  final ollamaApiKey = Platform.environment['OLLAMA_API']?.trim() ?? '';
  final ollamaSkipReason = enabled && ollamaBaseUrl.isNotEmpty
      ? false
      : 'Set DIRECT_LIVE_TESTS=1 and OLLAMA_URL to run live Ollama tests.';

  test(
    'Ollama live endpoint streams a typed native completion',
    () async {
      final adapter = OllamaAdapter();
      final profile = DirectConnectionProfile(
        id: 'live-ollama',
        name: 'Live Ollama endpoint',
        adapterKey: kOllamaAdapterKey,
        baseUrl: ollamaBaseUrl,
        apiKey: ollamaApiKey.isEmpty ? null : ollamaApiKey,
      );
      final models = await adapter.listModels(profile);
      expect(models, isNotEmpty);
      final model = models.firstWhere(
        (candidate) => !_looksNonChatModel(candidate.id),
        orElse: () => models.first,
      );

      final run = adapter.startCompletion(
        profile,
        DirectCompletionRequest(
          remoteModelId: model.id,
          messages: [
            DirectChatMessage.text(
              role: 'user',
              text: 'Reply with exactly: OK',
            ),
          ],
          parameters: const {
            'options': {'num_predict': 32},
          },
        ),
      );
      final events = await run.events
          .timeout(const Duration(seconds: 90))
          .toList();
      await run.done;

      expect(events.whereType<DirectStreamError>(), isEmpty);
      expect(events.whereType<DirectStreamDone>(), hasLength(1));
      expect(
        events.whereType<DirectContentDelta>().isNotEmpty ||
            events.whereType<DirectReasoningDelta>().isNotEmpty,
        isTrue,
      );
    },
    skip: ollamaSkipReason,
    timeout: const Timeout(Duration(minutes: 2)),
  );
}

bool _looksNonChatModel(String id) {
  final normalized = id.toLowerCase();
  return const [
    'embed',
    'moderation',
    'rerank',
    'tts',
    'whisper',
    'image',
  ].any(normalized.contains);
}

bool _looksReasoningModel(String id) {
  final normalized = id.toLowerCase();
  return const [
    'thinking',
    'reasoning',
    'deepseek-r1',
    'gpt-oss',
    '/o1',
    '/o3',
    '/o4',
  ].any(normalized.contains);
}
