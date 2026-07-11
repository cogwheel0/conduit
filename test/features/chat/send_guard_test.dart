import 'package:checks/checks.dart';
import 'package:conduit/core/database/chat_database_repository.dart';
import 'package:conduit/core/models/chat_message.dart';
import 'package:conduit/core/models/conversation.dart';
import 'package:conduit/core/models/model.dart';
import 'package:conduit/core/providers/app_providers.dart';
import 'package:conduit/core/services/api_service.dart';
import 'package:conduit/features/chat/providers/chat_providers.dart';
import 'package:conduit/features/direct_connections/models/direct_completion.dart';
import 'package:conduit/features/direct_connections/models/direct_connection_profile.dart';
import 'package:conduit/features/direct_connections/models/direct_remote_model.dart';
import 'package:conduit/features/direct_connections/providers/direct_connection_providers.dart';
import 'package:conduit/features/direct_connections/services/direct_model_registry.dart';
import 'package:conduit/features/direct_connections/services/direct_chat_bridge.dart';
import 'package:conduit/features/hermes/models/hermes_model.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Stand-in for a non-null [ApiService] (we only care about non-null identity).
class _FakeApiService extends Fake implements ApiService {}

const _owuiModel = Model(id: 'gpt-4', name: 'GPT-4');
final _hermesModel = hermesSyntheticModel();

/// Unit tests for the extracted send/regenerate guard. The Hermes-only
/// relaxation lets a Hermes model send with no OpenWebUI [api].
void main() {
  group('isSendBlocked', () {
    test('blocks when no model is selected', () {
      check(
        isSendBlocked(reviewerMode: false, api: null, selectedModel: null),
      ).isTrue();
      // ...even with an api present.
      check(
        isSendBlocked(
          reviewerMode: false,
          api: _FakeApiService(),
          selectedModel: null,
        ),
      ).isTrue();
    });

    test('blocks an OWUI model when the api is null and not reviewer', () {
      check(
        isSendBlocked(
          reviewerMode: false,
          api: null,
          selectedModel: _owuiModel,
        ),
      ).isTrue();
    });

    test('allows an OWUI model when the api is present', () {
      check(
        isSendBlocked(
          reviewerMode: false,
          api: _FakeApiService(),
          selectedModel: _owuiModel,
        ),
      ).isFalse();
    });

    test('allows any model in reviewer mode even with a null api', () {
      check(
        isSendBlocked(reviewerMode: true, api: null, selectedModel: _owuiModel),
      ).isFalse();
    });

    test('allows a Hermes model with a null api (the relaxation)', () {
      check(
        isSendBlocked(
          reviewerMode: false,
          api: null,
          selectedModel: _hermesModel,
        ),
      ).isFalse();
    });

    test('allows a currently trusted direct model without an api', () {
      final registry = DirectModelRegistry();
      final directModel = registry.replaceProfileModels(_directProfile, [
        DirectRemoteModel(id: 'local-model'),
      ]).single;

      check(
        isSendBlocked(
          reviewerMode: false,
          api: null,
          selectedModel: directModel,
          hasTrustedDirectBinding: registry.resolve(directModel) != null,
        ),
      ).isFalse();
    });

    test('blocks a stale direct model even when an api is present', () {
      final registry = DirectModelRegistry();
      final directModel = registry.replaceProfileModels(_directProfile, [
        DirectRemoteModel(id: 'local-model'),
      ]).single;
      registry.removeProfile(_directProfile.id);

      check(
        isSendBlocked(
          reviewerMode: false,
          api: _FakeApiService(),
          selectedModel: directModel,
          hasTrustedDirectBinding: registry.resolve(directModel) != null,
        ),
      ).isTrue();
    });

    test('blocks an untrusted model claiming the direct namespace', () {
      const forged = Model(
        id: 'direct:profile-one:bG9jYWwtbW9kZWw',
        name: 'Forged direct model',
        metadata: {'backend': 'direct'},
      );

      check(
        isSendBlocked(
          reviewerMode: false,
          api: _FakeApiService(),
          selectedModel: forged,
        ),
      ).isTrue();
    });
  });

  group('usesHermesTransportForRegeneration', () {
    test('routes a fresh Hermes chat with no active conversation', () {
      check(
        usesHermesTransportForRegeneration(
          selectedModel: _hermesModel,
          activeConversation: null,
        ),
      ).isTrue();
    });

    test('routes an opened Hermes session through the same transport', () {
      final now = DateTime.utc(2026, 7, 11);
      final openedSession = Conversation(
        id: 'local:hermes_s1',
        title: 'Hermes session',
        createdAt: now,
        updatedAt: now,
        metadata: const {'backend': 'hermes', 'hermesSessionId': 's1'},
      );
      check(
        usesHermesTransportForRegeneration(
          selectedModel: _hermesModel,
          activeConversation: openedSession,
        ),
      ).isTrue();
    });

    test('does not reroute an OpenWebUI regeneration', () {
      final now = DateTime.utc(2026, 7, 11);
      final openWebUiConversation = Conversation(
        id: 'owui-1',
        title: 'OpenWebUI chat',
        createdAt: now,
        updatedAt: now,
      );
      check(
        usesHermesTransportForRegeneration(
          selectedModel: _hermesModel,
          activeConversation: openWebUiConversation,
        ),
      ).isFalse();
    });

    test('an opened Hermes session keeps its bound transport', () {
      final now = DateTime.utc(2026, 7, 11);
      final openedSession = Conversation(
        id: 'local:hermes_s1',
        title: 'Hermes session',
        createdAt: now,
        updatedAt: now,
        metadata: const {'backend': 'hermes', 'hermesSessionId': 's1'},
      );
      check(
        usesHermesTransportForRegeneration(
          selectedModel: _owuiModel,
          activeConversation: openedSession,
        ),
      ).isTrue();
    });
  });

  group('direct chat storage guards', () {
    final now = DateTime.utc(2026, 7, 11);
    final directLocalConversation = Conversation(
      id: 'direct-local:one',
      title: 'Local',
      createdAt: now,
      updatedAt: now,
      metadata: const {kChatStorageKindMetadataKey: 'directLocal'},
    );

    test('blocks an OpenWebUI model from writing into a direct-local chat', () {
      check(
        isModelCompatibleWithConversation(
          conversation: directLocalConversation,
          hasTrustedDirectBinding: false,
        ),
      ).isFalse();
    });

    test('allows a trusted direct model to continue a direct-local chat', () {
      check(
        isModelCompatibleWithConversation(
          conversation: directLocalConversation,
          hasTrustedDirectBinding: true,
        ),
      ).isTrue();
    });

    test('text-only direct models are not advertised as vision capable', () {
      final registry = DirectModelRegistry();
      final textModel = registry.replaceProfileModels(_directProfile, [
        DirectRemoteModel(id: 'text-only', isMultimodal: false),
      ]).single;
      final container = ProviderContainer(
        overrides: [
          selectedModelProvider.overrideWithValue(textModel),
          directModelRegistryProvider.overrideWithValue(registry),
        ],
      );
      addTearDown(container.dispose);

      check(container.read(visionCapableModelsProvider)).isEmpty();
    });

    test('text-only direct models reject historical images at dispatch', () {
      expect(
        () => ensureDirectMessagesCompatibleWithModel(
          model: const Model(id: 'text-only', name: 'Text only'),
          messages: [
            DirectChatMessage(
              role: 'user',
              parts: const [
                DirectTextPart('Earlier image'),
                DirectImagePart('data:image/png;base64,AQID'),
              ],
            ),
          ],
        ),
        throwsA(isA<DirectChatInputException>()),
      );
    });

    test('persists regenerated assistant versions in the message payload', () {
      final message = ChatMessage(
        id: 'assistant-one',
        role: 'assistant',
        content: 'New answer',
        timestamp: now,
        versions: [
          ChatMessageVersion(
            id: 'assistant-one-old',
            content: 'Previous answer',
            timestamp: now.subtract(const Duration(minutes: 1)),
          ),
        ],
      );

      final payload = directPersistedMessagePayloadForTest(message);
      final versions = payload['versions'] as List<dynamic>;
      check(versions).length.equals(1);
      check(
        (versions.single as Map<String, dynamic>)['content'],
      ).equals('Previous answer');
    });
  });
}

final _directProfile = DirectConnectionProfile(
  id: 'profile-one',
  name: 'Local provider',
  adapterKey: kOllamaAdapterKey,
  baseUrl: 'http://localhost:11434',
);
