import 'package:conduit_core/database/app_database.dart';
import 'package:conduit_core/database/database_provider.dart';
import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit_core/features/chat/composer/composer_draft_store.dart';
import 'package:conduit_core/features/chat/providers/chat_providers.dart';
import 'package:conduit_core/features/direct_connections/providers/direct_connection_providers.dart';
import 'package:conduit_core/features/hermes/models/hermes_model.dart';
import 'package:conduit_core/features/hermes/providers/hermes_providers.dart';
import 'package:conduit_core/features/hermes/services/hermes_session_provenance.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

typedef ComposerDraftOwner = ({
  String backend,
  String account,
  String principal,
  Object? session,
});

typedef ComposerDraftContext = ({
  ComposerDraftOwner owner,
  String scope,
  String chatId,
  ComposerDraftStore? store,
  bool temporary,
});

typedef ComposerDraftKey = ({
  ComposerDraftOwner owner,
  String scope,
  String chatId,
});

ComposerDraftKey composerDraftKey(ComposerDraftContext context) =>
    (owner: context.owner, scope: context.scope, chatId: context.chatId);

final _composerDraftStoreProvider =
    Provider.family<ComposerDraftStore, AppDatabase>(
      (ref, database) => ComposerDraftStore(database),
    );

/// Stored chats use the same account/provenance database as their messages.
/// Draft rows stay outside chat history, sync payloads, and the send queue.
final composerDraftContextProvider = Provider<ComposerDraftContext>((ref) {
  final active = ref.watch(activeConversationProvider);
  final selected = ref.watch(selectedModelProvider);
  final account = ref.watch(activeServerProvider).value?.id ?? 'local';
  final userId = ref.watch(currentUserProvider2)?.id ?? '';
  final hermes = active != null
      ? isNativeHermesConversation(active)
      : selected != null && isHermesModel(selected);
  final hermesId = hermes ? ref.watch(hermesActiveConnectionIdProvider) : null;
  final hermesProfile = hermes
      ? ref
            .watch(hermesConnectionsProvider)
            .where((profile) => profile.id == hermesId)
            .firstOrNull
      : null;
  final hermesIdentity = hermesProfile == null
      ? null
      : HermesConfigController.connectionIdentityFor(hermesProfile);
  final ComposerDraftOwner owner = hermes
      ? (
          backend: 'hermes',
          account: hermesId ?? '',
          principal: hermesIdentity ?? '',
          session: null,
        )
      : (
          backend: 'account',
          account: account,
          principal: userId,
          session: ref.watch(openWebUiAuthSessionEpochProvider),
        );
  final temporary =
      ref.watch(temporaryChatEnabledProvider) || isTemporaryChat(active?.id);
  final readOnly =
      active != null &&
      conversationUsesOpenWebUiStorage(active) &&
      active.userId != null &&
      active.userId != userId;
  final scope = readOnly
      ? 'readonly'
      : active != null
      ? hermes
            ? 'hermes:$hermesIdentity'
            : 'chat'
      : 'new:${ref.watch(pendingFolderIdProvider) ?? ''}';
  AppDatabase? database;
  if (!temporary && !readOnly && !(hermes && hermesIdentity == null)) {
    if (active != null) {
      if (hermes || !conversationUsesOpenWebUiStorage(active)) {
        database = ref.watch(directLocalDatabaseProvider);
      } else if (active.userId == null || active.userId == userId) {
        database = ref.watch(appDatabaseProvider);
      }
    } else {
      database = ref.watch(appDatabaseProvider);
      if (database == null &&
          !ref.watch(openWebUiAccountAvailableProvider) &&
          selected != null &&
          (hermes ||
              ref.watch(directModelRegistryProvider).resolve(selected) !=
                  null)) {
        database = ref.watch(directLocalDatabaseProvider);
      }
    }
  }
  return (
    owner: owner,
    scope: scope,
    chatId: active?.id ?? '',
    store: database == null
        ? null
        : ref.watch(_composerDraftStoreProvider(database)),
    temporary: temporary,
  );
});
