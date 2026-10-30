import 'package:conduit/features/chat/providers/composer_draft_provider.dart';
import 'package:conduit_core/database/app_database.dart';
import 'package:conduit_core/database/chat_database_repository.dart';
import 'package:conduit_core/database/database_provider.dart';
import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit_core/features/hermes/models/hermes_connection_profile.dart';
import 'package:conduit_core/features/hermes/providers/hermes_providers.dart';
import 'package:conduit_core/features/hermes/services/hermes_session_provenance.dart';
import 'package:conduit_core/models/conversation.dart';
import 'package:conduit_core/models/model.dart';
import 'package:conduit_core/features/hermes/models/hermes_model.dart';
import 'package:conduit_core/models/user.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _Active extends ActiveConversationNotifier {
  _Active(this.initial);
  final Conversation? initial;
  @override
  Conversation? build() => initial;
}

class _Selected extends SelectedModel {
  _Selected([this.model]);
  final Model? model;
  @override
  Model? build() => model;
}

class _Temporary extends TemporaryChatEnabled {
  _Temporary(this.initial);
  final bool initial;
  @override
  bool build() => initial;
}

void main() {
  late AppDatabase server;
  late AppDatabase local;
  setUp(() {
    server = AppDatabase(NativeDatabase.memory());
    local = AppDatabase(NativeDatabase.memory());
  });
  tearDown(() async {
    await server.close();
    await local.close();
  });

  Conversation chat({String? userId}) => withChatStorageProvenance(
    Conversation(
      id: 'birch',
      title: 'Example',
      userId: userId,
      createdAt: DateTime.utc(2026),
      updatedAt: DateTime.utc(2026),
    ),
    ChatStorageKind.openWebUi,
  );

  ProviderContainer container(
    Conversation? conversation, {
    Model? selectedModel,
    bool temporary = false,
    String principal = 'principal-one',
  }) {
    final value = ProviderContainer(
      overrides: [
        activeConversationProvider.overrideWith(() => _Active(conversation)),
        selectedModelProvider.overrideWith(() => _Selected(selectedModel)),
        temporaryChatEnabledProvider.overrideWith(() => _Temporary(temporary)),
        currentUserProvider2.overrideWithValue(
          const User(
            id: 'reader',
            username: 'reader',
            email: 'reader@example.test',
            role: 'user',
          ),
        ),
        activeServerProvider.overrideWith((ref) async => null),
        appDatabaseProvider.overrideWith((ref) => server),
        directLocalDatabaseProvider.overrideWithValue(local),
        hermesActiveConnectionIdProvider.overrideWithValue('connection-one'),
        hermesConnectionsProvider.overrideWithValue([
          HermesConnectionProfile(
            id: 'connection-one',
            name: 'Example agent',
            baseUrl: 'https://agent.example.test',
            documentTrustPrincipalId: principal,
          ),
        ]),
      ],
    );
    addTearDown(value.dispose);
    return value;
  }

  test(
    'new Hermes drafts persist separate scopes for each connection identity',
    () async {
      final model = hermesSyntheticModel();
      final firstContainer = container(null, selectedModel: model);
      final otherContainer = container(
        null,
        selectedModel: model,
        principal: 'principal-two',
      );
      final first = firstContainer.read(composerDraftContextProvider);
      final other = otherContainer.read(composerDraftContextProvider);
      expect(first.scope, isNot(other.scope));
      await first.store!.save(
        first.scope,
        first.chatId,
        'Fold a paper lantern.',
      );
      expect(await other.store!.read(other.scope, other.chatId), isNull);
    },
  );

  test('stored account chats use their account database and own chat id', () {
    final context = container(chat(userId: 'reader'))
        .read(composerDraftContextProvider);
    expect(context.scope, 'chat');
    expect(context.chatId, 'birch');
    expect(context.store, isNotNull);
    expect(context.owner.principal, 'reader');
  });

  test('another user’s read-only chat cannot persist input', () {
    final context = container(chat(userId: 'another-reader'))
        .read(composerDraftContextProvider);
    expect(context.scope, 'readonly');
    expect(context.store, isNull);
  });

  test('temporary chats have no durable input store', () {
    final context = container(
      chat(),
      temporary: true,
    ).read(composerDraftContextProvider);
    expect(context.temporary, isTrue);
    expect(context.store, isNull);
  });

  test('native Hermes drafts follow the saved endpoint/principal identity', () {
    final native = markNativeHermesConversation(chat());
    final first = container(native).read(composerDraftContextProvider);
    final other = container(
      native,
      principal: 'principal-two',
    ).read(composerDraftContextProvider);
    expect(first.store, isNotNull);
    expect(first.owner.backend, 'hermes');
    expect(first.scope, startsWith('hermes:'));
    expect(first.scope, isNot(other.scope));
    expect(composerDraftKey(first), isNot(composerDraftKey(other)));
    expect(first.scope, isNot(contains('https://')));
  });
}
