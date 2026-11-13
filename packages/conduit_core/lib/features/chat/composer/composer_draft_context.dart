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
import 'package:riverpod/misc.dart' show ProviderListenable;
import 'package:riverpod/riverpod.dart';

import 'package:conduit_core/models/conversation.dart';
import 'package:conduit_core/models/model.dart';

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

/// Non-chat composers keep input local to the mounted editor and authenticated owner.
ComposerDraftContext ephemeralComposerDraftContext({
  required String scope,
  required String chatId,
  required Object session,
}) => (
  owner: (backend: 'ephemeral', account: '', principal: '', session: session),
  scope: scope,
  chatId: chatId,
  store: null,
  temporary: true,
);

ComposerDraftKey composerDraftKey(ComposerDraftContext context) =>
    (owner: context.owner, scope: context.scope, chatId: context.chatId);

final _composerDraftStoreProvider =
    Provider.family<ComposerDraftStore, AppDatabase>(
      (ref, database) => ComposerDraftStore(database),
    );

/// Reads a provider: `ref.watch` in [composerDraftContextProvider], or a
/// container's `read` for a host that names the chat itself.
typedef ComposerDraftRead = T Function<T>(ProviderListenable<T> provider);

/// Stored chats use the same account/provenance database as their messages.
/// Draft rows stay outside chat history, sync payloads, and the send queue.
final composerDraftContextProvider = Provider<ComposerDraftContext>(
  (ref) => resolveComposerDraftContext(
    ref.watch,
    active: ref.watch(activeConversationProvider),
    selected: ref.watch(selectedModelProvider),
    pendingFolderId: ref.watch(pendingFolderIdProvider),
    temporaryEnabled: ref.watch(temporaryChatEnabledProvider),
  ),
);

/// Where [active]'s composer draft lives (or a new chat's, in
/// [pendingFolderId], when [active] is null): its owner, scope, chat id and
/// store. [read] reads everything else.
///
/// [composerDraftContextProvider] is this for the chat on screen. The desktop
/// daemon, which keeps no chat on screen, asks it for the chat a window
/// names.
ComposerDraftContext resolveComposerDraftContext(
  ComposerDraftRead read, {
  required Conversation? active,
  required Model? selected,
  required String? pendingFolderId,
  required bool temporaryEnabled,
}) {
  final account = read(activeServerProvider).value?.id ?? 'local';
  final userId = read(currentUserProvider2)?.id ?? '';
  final hermes = active != null
      ? isNativeHermesConversation(active)
      : selected != null && isHermesModel(selected);
  final hermesId = hermes ? read(hermesActiveConnectionIdProvider) : null;
  final hermesProfile = hermes
      ? read(hermesConnectionsProvider)
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
          session: read(openWebUiAuthSessionEpochProvider),
        );
  final temporary = temporaryEnabled || isTemporaryChat(active?.id);
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
      : '${hermes ? 'new:hermes:$hermesIdentity' : 'new'}:${pendingFolderId ?? ''}';
  AppDatabase? database;
  if (!temporary && !readOnly && !(hermes && hermesIdentity == null)) {
    if (active != null) {
      if (hermes || !conversationUsesOpenWebUiStorage(active)) {
        database = read(directLocalDatabaseProvider);
      } else if (active.userId == null || active.userId == userId) {
        database = read(appDatabaseProvider);
      }
    } else {
      database = read(appDatabaseProvider);
      if (database == null &&
          !read(openWebUiAccountAvailableProvider) &&
          selected != null &&
          (hermes ||
              read(directModelRegistryProvider).resolve(selected) != null)) {
        database = read(directLocalDatabaseProvider);
      }
    }
  }
  return (
    owner: owner,
    scope: scope,
    chatId: active?.id ?? '',
    store: database == null
        ? null
        : read(_composerDraftStoreProvider(database)),
    temporary: temporary,
  );
}
