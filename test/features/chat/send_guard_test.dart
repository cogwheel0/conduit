import 'package:checks/checks.dart';
import 'package:conduit/core/models/conversation.dart';
import 'package:conduit/core/models/model.dart';
import 'package:conduit/core/services/api_service.dart';
import 'package:conduit/features/chat/providers/chat_providers.dart';
import 'package:conduit/features/hermes/models/hermes_model.dart';
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
      check(
        usesHermesTransportForRegeneration(
          selectedModel: _owuiModel,
          activeConversation: null,
        ),
      ).isFalse();
    });
  });
}
