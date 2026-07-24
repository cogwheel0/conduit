import 'dart:io';

import 'package:conduit/features/direct_connections/models/direct_completion.dart';
import 'package:conduit/features/direct_connections/models/direct_connection_profile.dart';
import 'package:conduit/features/direct_connections/services/direct_http_client.dart';
import 'package:conduit/features/direct_connections/services/ollama_adapter.dart';
import 'package:conduit/features/direct_connections/services/ollama_cloud_tools.dart';
import 'package:conduit/features/direct_connections/services/openai_compatible_adapter.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final enabled = Platform.environment['DIRECT_LIVE_TESTS'] == '1';
  final baseUrl = Platform.environment['OPENAI_URL']?.trim() ?? '';
  final apiKey = Platform.environment['OPENAI_API']?.trim() ?? '';
  final openAiModelOverride =
      Platform.environment['OPENAI_MODEL']?.trim() ?? '';
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
      final model = switch (openAiModelOverride) {
        final configured when configured.isNotEmpty => chatModels.firstWhere(
          (candidate) => candidate.id == configured,
          orElse: () => throw StateError(
            'OPENAI_MODEL is not present in the endpoint model catalog.',
          ),
        ),
        _ => chatModels.firstWhere(
          (candidate) => _looksReasoningModel(candidate.id),
          orElse: () => chatModels.first,
        ),
      };

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
  final ollamaModelOverride =
      Platform.environment['OLLAMA_MODEL']?.trim() ?? '';
  final ollamaSkipReason = enabled && ollamaBaseUrl.isNotEmpty
      ? false
      : 'Set DIRECT_LIVE_TESTS=1 and OLLAMA_URL to run live Ollama tests.';
  final ollamaLifecycleSkipReason =
      enabled &&
          ollamaBaseUrl.isNotEmpty &&
          !isOllamaCloudApiBaseUrl(ollamaBaseUrl)
      ? false
      : 'A self-hosted OLLAMA_URL is required for live residency tests.';
  final ollamaCloudSkipReason =
      enabled &&
          ollamaBaseUrl.isNotEmpty &&
          isOllamaCloudApiBaseUrl(ollamaBaseUrl)
      ? false
      : 'The official Ollama Cloud URL is required for live Cloud tool tests.';

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
      final chatModels = models
          .where((candidate) => !_looksNonChatModel(candidate.id))
          .toList();
      expect(
        chatModels,
        isNotEmpty,
        reason: 'The endpoint did not advertise a chat-capable Ollama model.',
      );
      final model = switch (ollamaModelOverride) {
        final configured when configured.isNotEmpty => chatModels.firstWhere(
          (candidate) => candidate.id == configured,
          orElse: () => throw StateError(
            'OLLAMA_MODEL is not present in the endpoint model catalog.',
          ),
        ),
        _ =>
          (chatModels..sort((left, right) {
                final sizeOrder = _ollamaSmokeModelScore(
                  left.id,
                ).compareTo(_ollamaSmokeModelScore(right.id));
                return sizeOrder != 0 ? sizeOrder : left.id.compareTo(right.id);
              }))
              .first,
      };

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

  test(
    'Ollama live endpoint reports and manages model residency',
    () async {
      final adapter = OllamaAdapter();
      addTearDown(adapter.dispose);
      final profile = DirectConnectionProfile(
        id: 'live-ollama-lifecycle',
        name: 'Live Ollama lifecycle endpoint',
        adapterKey: kOllamaAdapterKey,
        baseUrl: ollamaBaseUrl,
        apiKey: ollamaApiKey.isEmpty ? null : ollamaApiKey,
      );
      final models = await adapter.listModels(profile);
      final chatModels =
          models
              .where((candidate) => !_looksNonChatModel(candidate.id))
              .toList()
            ..sort((left, right) {
              final sizeOrder = _ollamaSmokeModelScore(
                left.id,
              ).compareTo(_ollamaSmokeModelScore(right.id));
              return sizeOrder != 0 ? sizeOrder : left.id.compareTo(right.id);
            });
      expect(chatModels, isNotEmpty);

      final initiallyLoaded = await adapter.listRunningModelIds(profile);
      final model = switch (ollamaModelOverride) {
        final configured when configured.isNotEmpty => chatModels.firstWhere(
          (candidate) => candidate.id == configured,
          orElse: () => throw StateError(
            'OLLAMA_MODEL is not present in the endpoint model catalog.',
          ),
        ),
        _ => chatModels.firstWhere(
          (candidate) => !initiallyLoaded.contains(candidate.id),
          orElse: () => chatModels.first,
        ),
      };
      final ownsResidency = !initiallyLoaded.contains(model.id);
      if (ownsResidency) {
        addTearDown(() async {
          await adapter.unloadModel(profile, model.id);
        });
      }

      await adapter.loadModel(profile, model.id, keepAlive: '30s');
      expect(await adapter.listRunningModelIds(profile), contains(model.id));

      if (ownsResidency) {
        await adapter.unloadModel(profile, model.id);
        expect(
          await adapter.listRunningModelIds(profile),
          isNot(contains(model.id)),
        );
      }
    },
    skip: ollamaLifecycleSkipReason,
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'Ollama Cloud live endpoint performs an authenticated web search',
    () async {
      final profile = DirectConnectionProfile(
        id: 'live-ollama-cloud-tools',
        name: 'Live Ollama Cloud tools',
        adapterKey: kOllamaAdapterKey,
        baseUrl: ollamaBaseUrl,
        apiKey: ollamaApiKey.isEmpty ? null : ollamaApiKey,
      );
      final dio = const DirectHttpClientFactory().create(profile);
      addTearDown(() => dio.close(force: true));

      final result = await OllamaCloudToolSession().execute(
        dio: dio,
        name: 'web_search',
        arguments: const {
          'query': 'Ollama Cloud documentation',
          'max_results': 1,
        },
        cancelToken: CancelToken(),
      );

      expect(result.isError, isFalse);
      final value = result.value as Map<String, dynamic>;
      expect(value['results'], isNotEmpty);
    },
    skip: ollamaCloudSkipReason,
    timeout: const Timeout(Duration(minutes: 1)),
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

int _ollamaSmokeModelScore(String id) {
  final matches = RegExp(
    r'(?::|[-_])(\d+(?:\.\d+)?)b(?:$|[-_:])',
    caseSensitive: false,
  ).allMatches(id).toList(growable: false);
  if (matches.isEmpty) return 1 << 30;
  final billions = double.tryParse(matches.last.group(1)!) ?? double.infinity;
  return billions.isFinite ? (billions * 1000).round() : 1 << 30;
}
