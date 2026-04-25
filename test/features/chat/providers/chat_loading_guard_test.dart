import 'package:checks/checks.dart';
import 'package:conduit/core/models/conversation.dart';
import 'package:conduit/core/models/model.dart';
import 'package:conduit/core/models/server_config.dart';
import 'package:conduit/core/providers/app_providers.dart';
import 'package:conduit/core/services/api_service.dart';
import 'package:conduit/core/services/worker_manager.dart';
import 'package:conduit/features/chat/providers/chat_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _NullConversationNotifier extends ActiveConversationNotifier {
  @override
  Conversation? build() => null;
}

class _LoadingConversationNotifier extends IsLoadingConversation {
  _LoadingConversationNotifier(this._value);

  final bool _value;

  @override
  bool build() => _value;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'sendMessageWithContainer refuses to create a new chat while a selection is loading',
    () async {
      final api = ApiService(
        serverConfig: const ServerConfig(
          id: 'test',
          name: 'Test',
          url: 'https://example.com',
        ),
        workerManager: WorkerManager(),
      );
      final container = ProviderContainer(
        overrides: [
          activeConversationProvider.overrideWith(
            () => _NullConversationNotifier(),
          ),
          isLoadingConversationProvider.overrideWith(
            () => _LoadingConversationNotifier(true),
          ),
          apiServiceProvider.overrideWithValue(api),
          selectedModelProvider.overrideWithValue(
            const Model(id: 'gpt-4', name: 'GPT-4'),
          ),
          reviewerModeProvider.overrideWithValue(false),
        ],
      );
      addTearDown(container.dispose);

      await expectLater(
        sendMessageWithContainer(
          container,
          'How do I add flavour?',
          null,
        ),
        throwsA(isA<StateError>()),
      );

      check(container.read(activeConversationProvider)).isNull();
      check(container.read(chatMessagesProvider)).isEmpty();
    },
  );
}
