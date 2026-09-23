part of 'chat_providers.dart';

final _directRunStopIndexProvider = Provider<_DirectRunStopIndex>(
  (ref) => _DirectRunStopIndex(),
);

final class _DirectRunStopIndex {
  final Map<String, Set<DirectRunKey>> _keysByMessageId = {};

  void track(DirectRunKey key) {
    (_keysByMessageId[key.assistantMessageId] ??= <DirectRunKey>{}).add(key);
  }

  void rebind(DirectRunKey previous, DirectRunKey next) {
    untrack(previous);
    track(next);
  }

  void untrack(DirectRunKey key) {
    final keys = _keysByMessageId[key.assistantMessageId];
    if (keys == null) return;
    keys.remove(key);
    if (keys.isEmpty) _keysByMessageId.remove(key.assistantMessageId);
  }

  List<DirectRunKey> keysForMessage(String assistantMessageId) =>
      List<DirectRunKey>.unmodifiable(
        _keysByMessageId[assistantMessageId] ?? const <DirectRunKey>{},
      );
}

typedef _ResolvedDirectRoute = ({
  Model model,
  DirectModelBinding binding,
  DirectConnectionProfile profile,
});

final class _DirectRunStoppedDuringPreflight implements Exception {
  const _DirectRunStoppedDuringPreflight();
}

/// Runs provider-owned direct preflight without letting a stalled attachment
/// lookup hold the optimistic turn or its database lease after Stop.
///
/// [Future.any] keeps an error handler attached to the losing provider future,
/// so a late failure after cancellation cannot escape as an uncaught zone error.
Future<T> _awaitDirectPreflightOrCancellation<T>({
  required DirectRunRegistry registry,
  required DirectRunReservation reservation,
  required CancelToken cancelToken,
  required Future<T> Function() operation,
}) async {
  if (registry.isCancelled(reservation)) {
    if (!cancelToken.isCancelled) {
      cancelToken.cancel('Direct attachment preflight stopped');
    }
    throw const _DirectRunStoppedDuringPreflight();
  }
  final operationFuture = operation();
  final result = await Future.any<T>(<Future<T>>[
    operationFuture,
    registry.cancellationSignal(reservation).then<T>((_) {
      if (!cancelToken.isCancelled) {
        cancelToken.cancel('Direct attachment preflight stopped');
      }
      throw const _DirectRunStoppedDuringPreflight();
    }),
  ]);
  // A cancelled Dio request and the registry signal settle in the same
  // microtask turn. Preserve Stop semantics even if the operation's contained
  // cancellation result happens to win the race.
  if (registry.isCancelled(reservation)) {
    throw const _DirectRunStoppedDuringPreflight();
  }
  return result;
}

final class _DirectConversationOwnerUnavailable extends StateError {
  _DirectConversationOwnerUnavailable({
    required this.placeholderWasDurablyDeleted,
  }) : super('Direct conversation owner is no longer available.');

  final bool placeholderWasDurablyDeleted;
}

final class _DirectTurnStartDatabaseUnavailable extends StateError {
  _DirectTurnStartDatabaseUnavailable()
    : super('The direct chat database is closing.');
}

final class _DirectOpenWebUiAuthSessionChanged implements Exception {
  const _DirectOpenWebUiAuthSessionChanged();
}

typedef _DirectStreamMove = ({
  bool cancelled,
  bool done,
  DirectStreamEvent? event,
  Object? error,
  StackTrace? stackTrace,
});

DirectProviderException _normalizeDirectDispatcherFailure(
  Object error, {
  required Iterable<String> sensitiveValues,
}) {
  final normalized = normalizeDirectProviderError(error);
  return DirectProviderException(
    sanitizeDirectProviderErrorMessage(
      normalized.message,
      sensitiveValues: sensitiveValues,
    ),
    statusCode: normalized.statusCode,
  );
}

Map<String, dynamic> _directContextSummaryParameters(
  DirectConnectionProfile profile,
  int maxTokens,
) => switch (profile.adapterKey) {
  kApplePccAdapterKey => <String, dynamic>{'max_tokens': maxTokens},
  kOpenAiCompatibleAdapterKey => <String, dynamic>{
    profile.openAiApiMode == DirectOpenAiApiMode.responses
            ? 'max_output_tokens'
            : 'max_tokens':
        maxTokens,
  },
  kOllamaAdapterKey => <String, dynamic>{
    'options': <String, dynamic>{'num_predict': maxTokens},
  },
  _ => const <String, dynamic>{},
};

const Duration _directContextCompactionIdleTimeout = Duration(seconds: 15);
const Duration _directContextCompactionMaxDuration = Duration(minutes: 1);

Future<List<int>?> _tryReadDirectContextVerificationKey(dynamic ref) async {
  try {
    return await ref.read(directDeviceTrustKeyProvider.future);
  } catch (error) {
    DebugLogger.warning(
      'context-key-unavailable',
      scope: 'direct-connections/compaction',
      data: {'errorType': error.runtimeType.toString()},
    );
    return null;
  }
}

Future<String> _generateDirectContextSummary({
  required DirectProviderAdapter adapter,
  required DirectConnectionProfile profile,
  required String remoteModelId,
  required List<DirectChatMessage> compactedMessages,
  required String? previousSummary,
  required int contextLength,
  required CancelToken preflightCancelToken,
}) async {
  final maxTokens = math.min(1000, math.max(64, contextLength * 15 ~/ 100));
  final maxCharacters = maxTokens * 4;
  final run = adapter.startCompletion(
    profile,
    DirectCompletionRequest(
      remoteModelId: remoteModelId,
      messages: directContextSummaryMessages(
        activeMessages: compactedMessages,
        previousSummary: previousSummary,
        maxInputCharacters: math.max(1024, contextLength * 2),
      ),
      parameters: _directContextSummaryParameters(profile, maxTokens),
    ),
  );
  try {
    unawaited(
      run.done.then<void>((_) {}, onError: (Object _, StackTrace _) {}),
    );
  } catch (_) {}
  unawaited(
    preflightCancelToken.whenCancel.then((_) {
      try {
        unawaited(run.cancel('context compaction stopped').catchError((_) {}));
      } catch (_) {}
    }),
  );

  Future<String> collect() async {
    final content = StringBuffer();
    var sawDone = false;
    await for (final event in run.events.timeout(
      _directContextCompactionIdleTimeout,
    )) {
      switch (event) {
        case DirectContentDelta():
          if (content.length + event.content.length > maxCharacters) {
            throw const DirectProviderException(
              'The context summary exceeded its response limit.',
            );
          }
          content.write(event.content);
        case DirectStreamError():
          throw DirectProviderException(
            event.message,
            statusCode: event.statusCode,
          );
        case DirectStreamDone():
          sawDone = true;
        default:
          break;
      }
      if (sawDone) break;
    }
    final summary = content.toString().trim();
    if (!sawDone || summary.isEmpty) {
      throw const DirectProviderException(
        'The provider did not return a context summary.',
      );
    }
    return summary;
  }

  try {
    return await collect().timeout(
      _directContextCompactionMaxDuration,
      onTimeout: () =>
          throw const DirectProviderException('Context compaction timed out.'),
    );
  } finally {
    try {
      unawaited(run.cancel('context compaction finished').catchError((_) {}));
    } catch (_) {}
  }
}

ProviderSubscription<Object> _listenForDirectOwnerAuthSessionChanges(
  dynamic ref,
  void Function(Object? previous, Object next) listener,
) {
  if (ref is WidgetRef) {
    return ref.listenManual<Object>(
      openWebUiAuthSessionEpochProvider,
      listener,
      fireImmediately: true,
    );
  }
  if (ref is Ref) {
    return ref.listen<Object>(
      openWebUiAuthSessionEpochProvider,
      listener,
      fireImmediately: true,
    );
  }
  if (ref is ProviderContainer) {
    return ref.listen<Object>(
      openWebUiAuthSessionEpochProvider,
      listener,
      fireImmediately: true,
    );
  }
  throw StateError('Unsupported provider reader for direct streaming.');
}

final class _DirectConversationOwner {
  _DirectConversationOwner({
    required this.conversationId,
    required this.location,
    this.persistenceOwnerId,
    this.databaseLease,
    this.sourceApi,
    this.sourceAuthSnapshot,
    this.sourceAuthSessionEpoch,
    this.remapEvents,
    this.openWebUiAuthSessionEpoch,
    this.openWebUiSyncEngine,
    String? unstoredOwnerScope,
  }) : _unstoredOwnerScope = unstoredOwnerScope;

  String conversationId;
  final ChatDatabaseLocation? location;
  final String? persistenceOwnerId;
  DatabaseLifetimeLease? databaseLease;
  final dynamic sourceApi;
  final ApiAuthSnapshot? sourceAuthSnapshot;
  final Object? sourceAuthSessionEpoch;
  final Stream<RemapEvent>? remapEvents;
  final Object? openWebUiAuthSessionEpoch;
  final SyncEngine? openWebUiSyncEngine;
  final String? _unstoredOwnerScope;

  String scopedConversationIdFor(String candidateConversationId) {
    final storage = location?.storage;
    if (storage != null) {
      return _storedDirectRunOwnerScope(
        storage: storage,
        persistenceOwnerId: persistenceOwnerId!,
        conversationId: candidateConversationId,
        authSessionEpoch: openWebUiAuthSessionEpoch,
      );
    }
    return _unstoredOwnerScope ??
        'conduit-direct-runtime://${Uri.encodeComponent(candidateConversationId)}';
  }

  String get scopedConversationId => scopedConversationIdFor(conversationId);

  Future<void> releaseDatabaseLease() async {
    final lease = databaseLease;
    databaseLease = null;
    await lease?.release();
  }
}

bool _directOwnerAuthSessionIsCurrent(
  dynamic ref,
  _DirectConversationOwner owner,
) {
  if (owner.location?.storage != ChatStorageKind.openWebUi) return true;
  final captured = owner.openWebUiAuthSessionEpoch;
  return captured != null &&
      identical(captured, _readOpenWebUiAuthSessionEpoch(ref));
}

void _requireDirectOwnerAuthSession(
  dynamic ref,
  _DirectConversationOwner owner,
) {
  if (!_directOwnerAuthSessionIsCurrent(ref, owner)) {
    throw const _DirectOpenWebUiAuthSessionChanged();
  }
}

void _requireDirectOwnerSourceAuthSession(
  dynamic ref,
  _DirectConversationOwner owner,
) {
  if (owner.sourceApi == null) return;
  final capturedEpoch = owner.sourceAuthSessionEpoch;
  // The API instance is intentionally captured: switching the visible server
  // must not retarget an in-flight attachment fetch from server A to server B.
  // Session revocation is represented by the epoch, while ApiAuthSnapshot
  // prevents a reused instance from adopting a later bearer token.
  if (capturedEpoch == null ||
      !identical(capturedEpoch, _readOpenWebUiAuthSessionEpoch(ref))) {
    throw const _DirectOpenWebUiAuthSessionChanged();
  }
}

void _requireDirectLocationAuthSession(
  dynamic ref, {
  required ChatDatabaseLocation location,
  required Object? capturedEpoch,
}) {
  if (location.storage == ChatStorageKind.openWebUi &&
      (capturedEpoch == null ||
          !identical(capturedEpoch, _readOpenWebUiAuthSessionEpoch(ref)))) {
    throw const _DirectOpenWebUiAuthSessionChanged();
  }
}

const String _directStoredRunOwnerPrefix = 'conduit-direct-store://';
final Expando<bool> _knownManagedDirectDatabases = Expando<bool>(
  'known-managed-direct-databases',
);
final Expando<int> _directAuthSessionScopeIds = Expando<int>(
  'direct-auth-session-scope',
);
int _nextDirectAuthSessionScopeId = 0;

String? _directAuthSessionScope(Object? epoch) {
  if (epoch == null) return null;
  return (_directAuthSessionScopeIds[epoch] ??= ++_nextDirectAuthSessionScopeId)
      .toString();
}

ChatStorageKind? _directStoredStorageOf(Conversation conversation) {
  final explicit = chatStorageKindOf(conversation);
  if (explicit != null) return explicit;
  final backend = conversation.metadata['backend'];
  if (backend == kDirectTransport || isNativeHermesConversation(conversation)) {
    return null;
  }
  // Unannotated conversations retain their historical OpenWebUI ownership.
  return ChatStorageKind.openWebUi;
}

String _directPersistenceOwnerIdForLocation(
  dynamic ref,
  ChatDatabaseLocation location,
) {
  if (location.storage == ChatStorageKind.directLocal) {
    return kDirectLocalDatabaseId;
  }
  final managedServerId = ref
      .read(databaseManagerProvider)
      .serverIdForDatabase(location.database);
  if (managedServerId != null && managedServerId.isNotEmpty) {
    return managedServerId;
  }
  final AsyncValue<ServerConfig?> activeServer = ref.read(activeServerProvider);
  final serverId = activeServer.asData?.value?.id;
  if (serverId != null && serverId.isNotEmpty) return serverId;
  // Override-heavy tests may supply a database without an active server. The
  // fallback remains collision-free for that database's lifetime; production
  // always uses the stable ServerConfig.id branch above.
  return 'unmanaged-${identityHashCode(location.database)}';
}

String _storedDirectRunOwnerScope({
  required ChatStorageKind storage,
  required String persistenceOwnerId,
  required String conversationId,
  Object? authSessionEpoch,
}) {
  final authScope = storage == ChatStorageKind.openWebUi
      ? _directAuthSessionScope(authSessionEpoch)
      : null;
  return '$_directStoredRunOwnerPrefix${storage.name}/'
      '${Uri.encodeComponent(persistenceOwnerId)}/'
      '${authScope == null ? '' : '${Uri.encodeComponent(authScope)}/'}'
      '${Uri.encodeComponent(conversationId)}';
}

String _directRunOwnerScopeForConversation(
  dynamic ref,
  Conversation conversation,
) {
  final storage = _directStoredStorageOf(conversation);
  if (storage != null) {
    String? persistenceOwnerId;
    try {
      final location = ref
          .read(chatDatabaseRepositoryProvider)
          .locationFor(storage);
      persistenceOwnerId = _directPersistenceOwnerIdForLocation(ref, location);
    } catch (_) {
      if (storage == ChatStorageKind.directLocal) {
        persistenceOwnerId = kDirectLocalDatabaseId;
      } else {
        final AsyncValue<ServerConfig?> activeServer = ref.read(
          activeServerProvider,
        );
        persistenceOwnerId = activeServer.asData?.value?.id;
      }
      if (persistenceOwnerId == null || persistenceOwnerId.isEmpty) {
        // Tests and temporary pre-backend conversations retain the legacy
        // storage scope until a stable server/store owner exists.
        return chatMutationOwnerScopeForConversation(conversation);
      }
    }
    return _storedDirectRunOwnerScope(
      storage: storage,
      persistenceOwnerId: persistenceOwnerId,
      conversationId: conversation.id,
      authSessionEpoch: storage == ChatStorageKind.openWebUi
          ? _readOpenWebUiAuthSessionEpoch(ref)
          : null,
    );
  }
  return chatMutationOwnerScopeForConversation(conversation);
}

@visibleForTesting
String directRunOwnerScopeForTest(dynamic ref, Conversation conversation) =>
    _directRunOwnerScopeForConversation(ref, conversation);

bool _conversationMatchesDirectRunOwner(
  dynamic ref,
  Conversation conversation,
  String ownerConversationId,
) {
  const runtimePrefix = 'conduit-direct-runtime://';
  if (ownerConversationId.startsWith(runtimePrefix)) {
    final encoded = ownerConversationId.substring(runtimePrefix.length);
    String rawId;
    try {
      rawId = Uri.decodeComponent(encoded);
    } on FormatException {
      return false;
    }
    return conversation.id == rawId &&
        conversation.metadata['backend'] == kDirectTransport &&
        chatStorageKindOf(conversation) == null;
  }
  try {
    return _directRunOwnerScopeForConversation(ref, conversation) ==
        ownerConversationId;
  } catch (_) {
    return false;
  }
}

DirectRunKey _directRunKeyForConversation(
  dynamic ref,
  Conversation conversation,
  String assistantMessageId,
) => (
  ownerConversationId: _directRunOwnerScopeForConversation(ref, conversation),
  assistantMessageId: assistantMessageId,
);

DirectRunKey _directRunKeyForOwner(
  String ownerConversationId,
  String assistantMessageId,
) => (
  ownerConversationId: ownerConversationId,
  assistantMessageId: assistantMessageId,
);

String _pendingDirectRunOwner(String assistantMessageId) =>
    'conduit-direct-pending://${Uri.encodeComponent(assistantMessageId)}';

bool _isDirectConversationOwnerActive(
  dynamic ref,
  _DirectConversationOwner owner,
) {
  if (!_directOwnerAuthSessionIsCurrent(ref, owner)) return false;
  final active = ref.read(activeConversationProvider) as Conversation?;
  return active != null &&
      _conversationMatchesDirectRunOwner(
        ref,
        active,
        owner.scopedConversationId,
      );
}

bool _isDirectSendConversationOwnerActive(
  dynamic ref,
  String? ownerConversationId,
) {
  final active = ref.read(activeConversationProvider) as Conversation?;
  if (ownerConversationId == null) return active == null;
  return active != null &&
      _conversationMatchesDirectRunOwner(ref, active, ownerConversationId);
}

/// Keeps a direct completion's durable owner aligned with a synchronous
/// local-to-server chat id remap. The callback shape makes the race invariant
/// directly testable without exposing the private owner object.
@visibleForTesting
StreamSubscription<RemapEvent> trackDirectConversationRemaps({
  required Stream<RemapEvent> events,
  required String Function() currentId,
  required void Function(String id) setId,
}) {
  return events.listen((event) {
    if (event.entityKind == 'chat' && event.fromId == currentId()) {
      setId(event.toId);
    }
  });
}

/// Resolves and writes a completion under the lock for its current durable chat
/// id. A stale local id is released and retried under the remapped server id,
/// closing the lookup-before-lock and lookup-under-wrong-lock races.
@visibleForTesting
Future<String> persistWithResolvedDirectConversationOwner({
  required ChatLocks locks,
  required String recordedChatId,
  required Future<String?> Function(String recordedId) resolveCurrentId,
  required Future<void> Function(String currentId) persist,
}) async {
  var lockChatId = recordedChatId;
  for (var attempt = 0; attempt < 2; attempt++) {
    String? rerouteChatId;
    var didPersist = false;
    await locks.runExclusive(lockChatId, () async {
      final resolvedChatId = await resolveCurrentId(lockChatId);
      if (resolvedChatId == null) {
        throw StateError('Direct conversation owner is no longer available.');
      }
      if (resolvedChatId != lockChatId) {
        rerouteChatId = resolvedChatId;
        return;
      }
      await persist(resolvedChatId);
      didPersist = true;
    });
    if (didPersist) return lockChatId;
    if (rerouteChatId == null) break;
    lockChatId = rerouteChatId!;
  }
  throw StateError('Direct conversation owner changed repeatedly.');
}

Future<_ResolvedDirectRoute?> _resolveDirectRoute(
  dynamic ref,
  Model? selectedModel,
) async {
  if (selectedModel == null) return null;
  final DirectModelRegistry registry = ref.read(directModelRegistryProvider);
  final DirectModelBinding? binding = registry.resolve(selectedModel);
  if (binding == null) return null;
  final List<DirectConnectionProfile> profiles = await ref.read(
    effectiveDirectConnectionProfilesFutureProvider.future,
  );
  // Profile loading may yield while logout, server switching, or a connection
  // edit revokes this exact model object. The registry's identity check is the
  // authority boundary, so do not let a binding captured before the await
  // authorize a stale route afterward.
  if (!identical(registry.resolve(selectedModel), binding)) return null;
  final DirectConnectionProfile? profile = profiles
      .where(
        (candidate) => candidate.id == binding.profileId && candidate.isUsable,
      )
      .firstOrNull;
  if (profile == null || profile.adapterKey != binding.adapterKey) return null;
  return (model: selectedModel, binding: binding, profile: profile);
}

bool _directRouteIsStillSelected(dynamic ref, _ResolvedDirectRoute route) {
  final selectedModel = ref.read(selectedModelProvider) as Model?;
  if (selectedModel == null || selectedModel.id != route.model.id) return false;
  return identical(
    ref.read(directModelRegistryProvider).resolve(selectedModel),
    route.binding,
  );
}

String _openWebUiDirectWireModelId(_ResolvedDirectRoute route) {
  final wireModelId = route.binding.openWebUiModelId;
  if (wireModelId == null || wireModelId.isEmpty) {
    throw StateError('Open WebUI direct model binding is incomplete.');
  }
  return wireModelId;
}

DirectChatSyncPreference _directSyncPreference(dynamic ref) {
  if (ref.read(isAuthenticatedProvider2) != true) {
    return DirectChatSyncPreference.localOnly;
  }
  final DirectHistoryPolicy policy = ref.read(directHistoryPolicyProvider);
  return switch (policy) {
    DirectHistoryPolicy.syncWithOpenWebUI =>
      DirectChatSyncPreference.syncWithOpenWebUiWhenAvailable,
    DirectHistoryPolicy.localOnly => DirectChatSyncPreference.localOnly,
  };
}

DatabaseManager _directDatabaseManager(
  dynamic ref,
  ChatDatabaseLocation location,
) => switch (location.storage) {
  ChatStorageKind.openWebUi => ref.read(databaseManagerProvider),
  ChatStorageKind.directLocal => ref.read(directLocalDatabaseManagerProvider),
};

DatabaseLifetimeLease? _tryAcquireDirectDatabaseLease(
  dynamic ref,
  ChatDatabaseLocation location,
) {
  final manager = _directDatabaseManager(ref, location);
  if (manager.serverIdForDatabase(location.database) != null) {
    // DatabaseManager removes a connection from its active identity map as soon
    // as physical close starts. Retained output still needs to distinguish that
    // closing managed executor from an intentionally unmanaged test override.
    _knownManagedDirectDatabases[location.database] = true;
  }
  return manager.tryAcquireLease(location.database);
}

DatabaseLifetimeLease? _acquireDirectTurnStartDatabaseLease(
  dynamic ref,
  ChatDatabaseLocation location,
) {
  final lease = _tryAcquireDirectDatabaseLease(ref, location);
  final manager = _directDatabaseManager(ref, location);
  final managedDatabase =
      manager.serverIdForDatabase(location.database) != null ||
      _knownManagedDirectDatabases[location.database] == true;
  if (managedDatabase && lease == null) {
    throw _DirectTurnStartDatabaseUnavailable();
  }
  return lease;
}

Map<String, dynamic> _directPersistedMessagePayload(
  ChatMessage message, {
  required String? parentId,
  required List<String> childrenIds,
  String? assistantTransport = kDirectTransport,
}) => directPersistedMessagePayload(
  message,
  parentId: parentId,
  childrenIds: childrenIds,
  assistantTransport: assistantTransport,
);

@visibleForTesting
Map<String, dynamic> directPersistedMessagePayloadForTest(
  ChatMessage message,
) => _directPersistedMessagePayload(
  message,
  parentId: message.metadata?['parentId']?.toString(),
  childrenIds: const <String>[],
);

@visibleForTesting
Map<String, dynamic> hermesPersistedMessagePayloadForTest(
  ChatMessage message,
) => _directPersistedMessagePayload(
  message,
  parentId: message.metadata?['parentId']?.toString(),
  childrenIds: const <String>[],
  assistantTransport: kHermesTransport,
);

MessageRowData _directMessageRow({
  required String chatId,
  required ChatMessage message,
  required String? parentId,
  required List<String> childrenIds,
  required int orderIndex,
  String? assistantTransport = kDirectTransport,
}) => directMessageRow(
  chatId: chatId,
  message: message,
  parentId: parentId,
  childrenIds: childrenIds,
  orderIndex: orderIndex,
  assistantTransport: assistantTransport,
);

Map<String, dynamic> _directNewChatBlob({
  required String title,
  required String modelId,
  required List<ChatMessage> messages,
}) => directNewChatBlob(title: title, modelId: modelId, messages: messages);
