part of 'chat_providers.dart';

AppDatabase? _readAppDatabaseOrNull(dynamic ref) {
  try {
    return ref.read(appDatabaseProvider);
  } catch (_) {
    return null;
  }
}

Object? _readApiServiceOrNull(dynamic ref) {
  try {
    return ref.read(apiServiceProvider);
  } catch (_) {
    return null;
  }
}

Object? _readOpenWebUiAuthSessionEpoch(dynamic ref) {
  try {
    return ref.read(openWebUiAuthSessionEpochProvider);
  } catch (_) {
    return null;
  }
}

SocketService? _readSocketServiceOrNull(dynamic ref) {
  try {
    return ref.read(socketServiceProvider) as SocketService?;
  } catch (_) {
    return null;
  }
}

SocketService? _readOpenWebUiSocketForApi(dynamic ref, Object? api) {
  final socket = _readSocketServiceOrNull(ref);
  if (socket == null || api is! ApiService) return null;
  return socket.serverConfig.id == api.serverConfig.id ? socket : null;
}

bool _openWebUiContextTupleIsCoherent(
  dynamic ref, {
  required AppDatabase? database,
  required Object? api,
  SocketService? socket,
}) {
  // Reviewer mode and narrow provider tests deliberately omit the API/socket.
  // Object identity still scopes those contexts; only reject a tuple when two
  // available production identities positively disagree.
  if (api == null) return socket == null;
  if (api is! ApiService) return false;
  final serverId = api.serverConfig.id;
  if (socket != null && socket.serverConfig.id != serverId) return false;

  if (database != null) {
    try {
      final manager = ref.read(databaseManagerProvider) as DatabaseManager;
      final databaseServerId = manager.serverIdForDatabase(database);
      if (databaseServerId != null && databaseServerId != serverId) {
        return false;
      }
    } catch (_) {}
  }

  try {
    final activeServer = ref.read(activeServerProvider);
    if (activeServer is AsyncData<ServerConfig?>) {
      final activeServerId = activeServer.value?.id;
      if (activeServerId != null && activeServerId != serverId) return false;
    }
  } catch (_) {}
  return true;
}

bool _conversationUsesOpenWebUiContext(Conversation? conversation) {
  if (conversation == null) return false;
  final storage = chatStorageKindOf(conversation);
  // Explicit storage provenance is authoritative. The conversation-level
  // backend marker describes the transport used by a turn and may legitimately
  // be direct/Hermes inside an OpenWebUI-owned chat.
  if (storage == ChatStorageKind.openWebUi) return true;
  if (storage == ChatStorageKind.directLocal) return false;
  final backend = conversation.metadata['backend'];
  return backend != kDirectTransport &&
      !isNativeHermesConversation(conversation);
}

/// Whether chat content is owned by the account-scoped OpenWebUI database.
///
/// Transport and storage are independent: a direct/Hermes response can live in
/// OpenWebUI storage and must disappear at account isolation, while an app-owned
/// direct-local/runtime chat remains visible during OpenWebUI sign-out.
/// True while the active conversation belongs to another user (reached
/// through a shared folder). Every mutating affordance hides behind this.
final activeConversationReadOnlyProvider = Provider<bool>((ref) {
  return isReadOnlySharedConversation(
    ref.watch(activeConversationProvider),
    ref.watch(currentUserProvider2.select((user) => user?.id)),
  );
});
