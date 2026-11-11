import 'dart:async';

import 'package:checks/checks.dart';
import 'package:conduit_core/auth/api_auth_interceptor.dart';
import 'package:conduit_core/database/app_database.dart';
import 'package:conduit_core/database/chat_database_repository.dart';
import 'package:conduit_core/database/database_provider.dart';
import 'package:conduit_core/features/chat/providers/chat_handoff_providers.dart';
import 'package:conduit_core/features/chat/providers/chat_providers.dart';
import 'package:conduit_core/features/direct_connections/direct_connections.dart';
import 'package:conduit_core/features/hermes/models/hermes_model.dart';
import 'package:conduit_core/models/chat_handoff.dart';
import 'package:conduit_core/models/conversation.dart';
import 'package:conduit_core/models/model.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/navigation/routes.dart';
import 'package:conduit_core/ports/route_navigator_port.dart';
import 'package:conduit_core/providers/host_ports.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/settings_service.dart';
import 'package:conduit_core/services/worker_manager.dart';
import 'package:drift/native.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

const _general = Model(id: 'general', name: 'General');
const _coder = Model(id: 'coder', name: 'Code Assistant');

/// Records what a coordinator asked and opened, answering its question with
/// [answer].
class _Rig {
  _Rig({this.models = const [_general, _coder]});

  final List<Model> models;
  String? activeChatId = 'chat-1';
  final asked = <String>[];
  final opened = <(Model, String)>[];
  Future<bool> Function() answer = () async => true;
  Future<void> Function() lookUp = () async {};

  ChatHandoffCoordinator coordinator({bool canAsk = true}) =>
      ChatHandoffCoordinator(
        claimActiveChat: (chatId) => chatId == activeChatId
            ? () => chatId == activeChatId
            : null,
        findModel: (modelId) async {
          await lookUp();
          return openWebUiHandoffModel(models, modelId);
        },
        confirm: canAsk
            ? (modelName) {
                asked.add(modelName);
                return answer();
              }
            : null,
        open: (model, prompt) => opened.add((model, prompt)),
      );
}

Future<Map<String, dynamic>> _handoff(
  ChatHandoffCoordinator coordinator, {
  String? chatId = 'chat-1',
  String? messageId = 'message-1',
  Object? data = const {'model_id': 'coder', 'prompt': 'Review this diff'},
}) => coordinator.handle(chatId: chatId, messageId: messageId, data: data);

final class _ActiveConversation extends ActiveConversationNotifier {
  @override
  Conversation? build() => Conversation(
    id: 'chat-1',
    title: 'Routing',
    createdAt: DateTime(2026),
    updatedAt: DateTime(2026),
  );
}

final class _Settings extends AppSettingsNotifier {
  @override
  AppSettings build() => const AppSettings();
}

final class _SelectedModel extends SelectedModel {
  @override
  Model? build() => _general;
}

final class _ActiveChat extends ActiveConversationNotifier {
  _ActiveChat(this._initial);

  final Conversation _initial;

  @override
  Conversation? build() => _initial;

  void put(Conversation? next) => state = next;
}

final class _Models extends Models {
  @override
  Future<List<Model>> build() async => const [_general, _coder];
}

const _specialist = Model(
  id: 'specialist',
  name: 'Specialist',
  metadata: {'hidden': true},
);

/// The server: [_specialist] is listed only when hidden models are asked for.
final class _Api extends ApiService {
  _Api()
    : super(
        serverConfig: const ServerConfig(
          id: 'server',
          name: 'Server',
          url: 'https://owui.example.test',
        ),
        workerManager: WorkerManager(),
      );

  final listings = <bool>[];

  @override
  Future<List<Model>> getModels({
    bool includeHidden = false,
    ApiAuthSnapshot? authSnapshot,
  }) async {
    listings.add(includeHidden);
    return [_general, _coder, if (includeHidden) _specialist];
  }
}

final class _Navigator implements RouteNavigatorPort {
  @override
  String? currentRoute = Routes.chat;

  @override
  void go(String location) => currentRoute = location;
}

void main() {
  group('a chat:handoff payload', () {
    test('needs a model id, and a prompt only when one is given', () {
      check(
        ChatHandoffRequest.tryParse({'model_id': 'coder', 'prompt': 'Hi'}),
      ).isNotNull()
        ..has((r) => r.modelId, 'modelId').equals('coder')
        ..has((r) => r.prompt, 'prompt').equals('Hi');
      check(
        ChatHandoffRequest.tryParse({'model_id': 'coder'}),
      ).isNotNull().has((r) => r.prompt, 'prompt').equals('');
      check(
        ChatHandoffRequest.tryParse({'model_id': 'coder', 'prompt': null}),
      ).isNotNull().has((r) => r.prompt, 'prompt').equals('');
    });

    test('is refused when malformed', () {
      for (final data in <Object?>[
        null,
        'coder',
        const ['coder'],
        const <String, dynamic>{},
        const {'model_id': ''},
        const {'model_id': 7},
        const {'model': 'coder'},
        const {'model_id': 'coder', 'prompt': 42},
        const {
          'model_id': 'coder',
          'prompt': ['Hi'],
        },
      ]) {
        check(
          because: '$data',
          ChatHandoffRequest.tryParse(data),
        ).isNull();
      }
    });

    test('ignores files and anything else it carries', () {
      check(
        ChatHandoffRequest.tryParse({
          'model_id': 'coder',
          'prompt': 'Hi',
          'files': [
            {'type': 'file', 'id': 'file-1'},
          ],
          'code': 'location.href = "/"',
        }),
      ).isNotNull().has((r) => r.modelId, 'modelId').equals('coder');
    });
  });

  group('the handoff model', () {
    test('is one of the account models, hidden ones included', () {
      const hidden = Model(
        id: 'specialist',
        name: 'Specialist',
        metadata: {'hidden': true},
      );
      check(
        openWebUiHandoffModel(const [_general, hidden], 'specialist'),
      ).identicalTo(hidden);
      check(openWebUiHandoffModel(const [_general], 'missing')).isNull();
    });

    test('is never a Direct or Hermes model of this device', () {
      final direct = DirectModelRegistry().replaceProfileModels(
        DirectConnectionProfile(
          id: 'profile',
          name: 'Local',
          adapterKey: 'ollama',
          baseUrl: 'http://localhost:11434',
        ),
        [DirectRemoteModel(id: 'llama')],
      ).single;
      final hermes = hermesSyntheticModel(name: 'Agent');

      check(openWebUiHandoffModel([direct, hermes], direct.id)).isNull();
      check(openWebUiHandoffModel([direct, hermes], hermes.id)).isNull();
    });
  });

  group('a chat:handoff', () {
    test('opens the new chat only once the user agrees', () async {
      final rig = _Rig();
      final reply = await _handoff(rig.coordinator());

      check(reply).deepEquals({'handled': true});
      check(rig.asked).deepEquals(['Code Assistant']);
      check(rig.opened).deepEquals([(_coder, 'Review this diff')]);
    });

    test('leaves the chat alone when the user declines', () async {
      final rig = _Rig()..answer = () async => false;
      final reply = await _handoff(rig.coordinator());

      check(reply).deepEquals({'handled': false, 'reason': 'declined'});
      check(rig.asked).deepEquals(['Code Assistant']);
      check(rig.opened).isEmpty();
    });

    test('names a model without a name by its id', () async {
      final rig = _Rig(models: const [Model(id: 'coder', name: '')]);
      await _handoff(rig.coordinator());

      check(rig.asked).deepEquals(['coder']);
    });

    test('is refused, without asking, when malformed', () async {
      final rig = _Rig();
      final reply = await _handoff(
        rig.coordinator(),
        data: const {'prompt': 'Review this diff'},
      );

      check(reply).deepEquals({'handled': false, 'reason': 'invalid'});
      check(rig.asked).isEmpty();
      check(rig.opened).isEmpty();
    });

    test('is refused, without asking, for a model the user lacks', () async {
      final rig = _Rig(models: const [_general]);
      final reply = await _handoff(rig.coordinator());

      check(
        reply,
      ).deepEquals({'handled': false, 'reason': 'model_unavailable'});
      check(rig.asked).isEmpty();
      check(rig.opened).isEmpty();
    });

    test('is refused, without asking, for a chat that is not open', () async {
      final rig = _Rig();
      final coordinator = rig.coordinator();
      for (final chatId in [null, '', 'chat-2']) {
        check(
          because: '$chatId',
          await _handoff(coordinator, chatId: chatId),
        ).deepEquals({'handled': false, 'reason': 'not_active_chat'});
      }
      rig.activeChatId = null;
      check(
        await _handoff(coordinator),
      ).deepEquals({'handled': false, 'reason': 'not_active_chat'});

      check(rig.asked).isEmpty();
      check(rig.opened).isEmpty();
    });

    test('is dropped when the user leaves the chat while deciding', () async {
      final rig = _Rig();
      final answer = Completer<bool>();
      rig.answer = () => answer.future;

      final reply = _handoff(rig.coordinator());
      await Future<void>.delayed(Duration.zero);
      rig.activeChatId = 'chat-2';
      answer.complete(true);

      check(
        await reply,
      ).deepEquals({'handled': false, 'reason': 'not_active_chat'});
      check(rig.opened).isEmpty();
    });

    test('is dropped when the user leaves while the model is found', () async {
      final rig = _Rig();
      final found = Completer<void>();
      rig.lookUp = () => found.future;
      final coordinator = rig.coordinator();

      final reply = _handoff(coordinator);
      await Future<void>.delayed(Duration.zero);
      check(
        await _handoff(coordinator, messageId: 'message-2'),
      ).deepEquals({'handled': false, 'reason': 'busy'});
      rig.activeChatId = 'chat-2';
      found.complete();

      check(
        await reply,
      ).deepEquals({'handled': false, 'reason': 'not_active_chat'});
      check(rig.asked).isEmpty();
      check(rig.opened).isEmpty();
    });

    test('is acted on once when it arrives twice', () async {
      final rig = _Rig();
      final coordinator = rig.coordinator();

      check(await _handoff(coordinator)).deepEquals({'handled': true});
      check(
        await _handoff(coordinator),
      ).deepEquals({'handled': false, 'reason': 'duplicate'});
      check(rig.asked).length.equals(1);
      check(rig.opened).length.equals(1);

      // Declining is an answer too.
      rig.answer = () async => false;
      await _handoff(coordinator, messageId: 'message-2');
      check(
        await _handoff(coordinator, messageId: 'message-2'),
      ).deepEquals({'handled': false, 'reason': 'duplicate'});
      check(rig.asked).length.equals(2);
    });

    test('is refused while the user answers another', () async {
      final rig = _Rig();
      final answer = Completer<bool>();
      rig.answer = () => answer.future;
      final coordinator = rig.coordinator();

      final first = _handoff(coordinator);
      await Future<void>.delayed(Duration.zero);
      check(
        await _handoff(coordinator, messageId: 'message-2'),
      ).deepEquals({'handled': false, 'reason': 'busy'});
      // The same one again is a repeat, not a second question.
      check(
        await _handoff(coordinator),
      ).deepEquals({'handled': false, 'reason': 'duplicate'});

      answer.complete(true);
      check(await first).deepEquals({'handled': true});
      check(rig.asked).length.equals(1);
      check(rig.opened).length.equals(1);

      // Once answered, another can ask.
      check(
        await _handoff(coordinator, messageId: 'message-2'),
      ).deepEquals({'handled': true});
    });

    test('is refused when the host cannot ask the user', () async {
      final rig = _Rig();
      final reply = await _handoff(rig.coordinator(canAsk: false));

      check(reply).deepEquals({'handled': false, 'reason': 'unsupported'});
      check(rig.opened).isEmpty();
    });

    test('remembers a bounded number of handoffs', () async {
      final rig = _Rig()..answer = () async => false;
      final coordinator = rig.coordinator();
      const limit = ChatHandoffCoordinator.maxRememberedHandoffs;
      for (var i = 0; i <= limit; i++) {
        await _handoff(coordinator, messageId: 'message-$i');
      }

      // The oldest was forgotten, so it is asked again; the newest is not.
      await _handoff(coordinator, messageId: 'message-0');
      check(
        await _handoff(coordinator, messageId: 'message-$limit'),
      ).deepEquals({'handled': false, 'reason': 'duplicate'});
      check(rig.asked).length.equals(limit + 2);
    });
  });

  test('opening a handoff starts a new chat with the prompt unsent', () {
    final container = ProviderContainer(
      overrides: [
        appSettingsProvider.overrideWith(_Settings.new),
        activeConversationProvider.overrideWith(_ActiveConversation.new),
        selectedModelProvider.overrideWith(_SelectedModel.new),
        temporaryChatEnforcedProvider.overrideWithValue(false),
      ],
    );
    addTearDown(container.dispose);

    // A container reads providers as a ref does.
    openChatHandoff(container, _coder, 'Review this diff');

    check(container.read(activeConversationProvider)).isNull();
    check(container.read(chatMessagesProvider)).isEmpty();
    check(container.read(selectedModelProvider)).equals(_coder);
    check(container.read(isManualModelSelectionProvider)).isTrue();
    check(
      container.read(prefilledInputTextProvider),
    ).equals('Review this diff');

    // An empty prompt leaves the composer as it was.
    container.read(prefilledInputTextProvider.notifier).clear();
    openChatHandoff(container, _general, '');
    check(container.read(prefilledInputTextProvider)).isNull();
    check(container.read(selectedModelProvider)).equals(_general);
  });

  group('the app coordinator', () {
    late _Api api;
    late _Navigator navigator;

    Future<(ProviderContainer, List<String>)> appWith(
      Conversation active, {
      void Function(ProviderContainer container)? whileAsking,
    }) async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      api = _Api();
      navigator = _Navigator();
      final asked = <String>[];
      late final ProviderContainer container;
      container = ProviderContainer(
        overrides: [
          appDatabaseProvider.overrideWithValue(db),
          apiServiceProvider.overrideWithValue(api),
          routeNavigatorProvider.overrideWithValue(navigator),
          socketServiceProvider.overrideWithValue(null),
          openWebUiAuthSessionEpochProvider.overrideWithValue(Object()),
          activeConversationProvider.overrideWith(() => _ActiveChat(active)),
          modelsProvider.overrideWith(_Models.new),
          appSettingsProvider.overrideWith(_Settings.new),
          selectedModelProvider.overrideWith(_SelectedModel.new),
          temporaryChatEnforcedProvider.overrideWithValue(false),
          chatHandoffPromptProvider.overrideWithValue((modelName) async {
            asked.add(modelName);
            whileAsking?.call(container);
            return true;
          }),
        ],
      );
      addTearDown(container.dispose);
      await container.read(modelsProvider.future);
      return (container, asked);
    }

    Conversation chat(String id) => Conversation(
      id: id,
      title: id,
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026),
    );

    test('acts on a handoff for the open Open WebUI chat', () async {
      final (container, asked) = await appWith(
        withChatStorageProvenance(chat('chat-1'), ChatStorageKind.openWebUi),
      );
      final reply = await container
          .read(chatHandoffCoordinatorProvider)
          .handle(
            chatId: 'chat-1',
            messageId: 'message-1',
            data: const {'model_id': 'coder', 'prompt': 'Review this diff'},
          );

      check(reply).deepEquals({'handled': true});
      check(asked).deepEquals(['Code Assistant']);
      check(container.read(selectedModelProvider)).equals(_coder);
      check(
        container.read(prefilledInputTextProvider),
      ).equals('Review this diff');
    });

    test('ignores one for another chat or a chat on this device', () async {
      for (final (active, chatId) in [
        (chat('chat-1'), 'chat-2'),
        (
          withChatStorageProvenance(
            chat('chat-1'),
            ChatStorageKind.directLocal,
          ),
          'chat-1',
        ),
      ]) {
        final (container, asked) = await appWith(active);
        final reply = await container
            .read(chatHandoffCoordinatorProvider)
            .handle(
              chatId: chatId,
              messageId: 'message-1',
              data: const {'model_id': 'coder'},
            );

        check(
          reply,
        ).deepEquals({'handled': false, 'reason': 'not_active_chat'});
        check(asked).isEmpty();
        check(container.read(selectedModelProvider)).equals(_general);
      }
    });

    test('drops one whose chat was left while the user decided', () async {
      final (container, asked) = await appWith(
        withChatStorageProvenance(chat('chat-1'), ChatStorageKind.openWebUi),
        whileAsking: (container) =>
            (container.read(activeConversationProvider.notifier)
                    as _ActiveChat)
                .put(chat('chat-2')),
      );
      final reply = await container
          .read(chatHandoffCoordinatorProvider)
          .handle(
            chatId: 'chat-1',
            messageId: 'message-1',
            data: const {'model_id': 'coder', 'prompt': 'Review this diff'},
          );

      check(
        reply,
      ).deepEquals({'handled': false, 'reason': 'not_active_chat'});
      check(asked).deepEquals(['Code Assistant']);
      check(container.read(activeConversationProvider)?.id).equals('chat-2');
      check(container.read(selectedModelProvider)).equals(_general);
      check(container.read(prefilledInputTextProvider)).isNull();
    });

    test('finds a hidden model on the server, and only asks for it', () async {
      Future<(ProviderContainer, List<String>, Map<String, dynamic>)> handoff(
        String modelId,
      ) async {
        final (container, asked) = await appWith(
          withChatStorageProvenance(chat('chat-1'), ChatStorageKind.openWebUi),
        );
        final reply = await container
            .read(chatHandoffCoordinatorProvider)
            .handle(
              chatId: 'chat-1',
              messageId: 'message-1',
              data: {'model_id': modelId},
            );
        return (container, asked, reply);
      }

      final (hidden, askedHidden, hiddenReply) = await handoff('specialist');
      check(hiddenReply).deepEquals({'handled': true});
      check(askedHidden).deepEquals(['Specialist']);
      check(hidden.read(selectedModelProvider)).equals(_specialist);
      check(api.listings).deepEquals([true]);

      final (_, askedMissing, missingReply) = await handoff('missing');
      check(
        missingReply,
      ).deepEquals({'handled': false, 'reason': 'model_unavailable'});
      check(askedMissing).isEmpty();
      check(api.listings).deepEquals([true]);

      // A model the picker lists needs no request.
      final (_, _, listedReply) = await handoff('coder');
      check(listedReply).deepEquals({'handled': true});
      check(api.listings).isEmpty();
    });

    test('ignores one while the chat is not on screen', () async {
      final (container, asked) = await appWith(
        withChatStorageProvenance(chat('chat-1'), ChatStorageKind.openWebUi),
      );
      navigator.currentRoute = Routes.notes;
      final reply = await container
          .read(chatHandoffCoordinatorProvider)
          .handle(
            chatId: 'chat-1',
            messageId: 'message-1',
            data: const {'model_id': 'coder'},
          );

      check(
        reply,
      ).deepEquals({'handled': false, 'reason': 'not_active_chat'});
      check(asked).isEmpty();
      check(container.read(selectedModelProvider)).equals(_general);
    });

    test('drops one whose chat left the screen while deciding', () async {
      final (container, asked) = await appWith(
        withChatStorageProvenance(chat('chat-1'), ChatStorageKind.openWebUi),
        whileAsking: (_) => navigator.currentRoute = Routes.notes,
      );
      final reply = await container
          .read(chatHandoffCoordinatorProvider)
          .handle(
            chatId: 'chat-1',
            messageId: 'message-1',
            data: const {'model_id': 'coder'},
          );

      check(
        reply,
      ).deepEquals({'handled': false, 'reason': 'not_active_chat'});
      check(asked).length.equals(1);
      check(container.read(selectedModelProvider)).equals(_general);
    });
  });
}
