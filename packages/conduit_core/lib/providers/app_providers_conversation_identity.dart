part of 'app_providers.dart';

/// Requests a debounced pull cycle from the sync engine and invalidates the
/// folder summary caches after the pull has had a chance to write rows
/// (CDT-RFC-001 Phase 1: every refresh path converges on the engine; Drift
/// streams deliver the resulting UI updates).
void refreshConversationsCache(dynamic ref, {bool includeFolders = false}) {
  final folderConversationRefresh = ref.read(
    _folderConversationRefreshTickProvider.notifier,
  );
  final syncEngine = ref.read(syncEngineProvider.notifier);
  // Invoke the notifier synchronously while the caller's provider/widget ref
  // is still known to be alive. Scheduling the invocation itself in a detached
  // Future leaves a teardown window where the owner can be disposed before
  // [requestPull] gets a chance to read its Riverpod dependencies.
  Future<PullResult?> pull;
  try {
    pull = syncEngine.requestPull(reason: 'cache-refresh');
  } catch (error, stackTrace) {
    DebugLogger.error(
      'refresh-cache-failed',
      scope: 'conversations',
      error: error,
      stackTrace: stackTrace,
    );
    return;
  }
  unawaited(
    pull
        .then<void>((_) {
          folderConversationRefresh.bumpIfMounted();
        })
        .catchError((Object error, StackTrace stackTrace) {
          DebugLogger.error(
            'refresh-cache-failed',
            scope: 'conversations',
            error: error,
            stackTrace: stackTrace,
          );
        }),
  );
}

typedef _UpdatedItem<T> = ({List<T> items, T item});
typedef _RemovedItems<T> = ({List<T> items, bool didRemove});

DateTime? _latestDateTime(DateTime? left, DateTime? right) {
  if (left == null) return right;
  if (right == null) return left;
  return right.isAfter(left) ? right : left;
}

List<T> _upsertItemById<T>(
  List<T> current,
  T item, {
  required String Function(T item) idOf,
}) {
  final updated = <T>[...current];
  final itemId = idOf(item);
  final index = updated.indexWhere((existing) => idOf(existing) == itemId);
  if (index >= 0) {
    updated[index] = item;
  } else {
    updated.add(item);
  }
  return updated;
}

_UpdatedItem<T>? _transformItemById<T>(
  List<T> current,
  String id,
  T Function(T item) transform, {
  required String Function(T item) idOf,
}) {
  final index = current.indexWhere((existing) => idOf(existing) == id);
  if (index < 0) {
    return null;
  }
  final updated = <T>[...current];
  final transformed = transform(updated[index]);
  updated[index] = transformed;
  return (items: updated, item: transformed);
}

_RemovedItems<T> _removeItemById<T>(
  List<T> current,
  String id, {
  required String Function(T item) idOf,
}) {
  final updated = <T>[...current];
  final index = updated.indexWhere((existing) => idOf(existing) == id);
  if (index >= 0) {
    updated.removeAt(index);
  }
  return (items: updated, didRemove: index >= 0);
}

/// Server-style epoch seconds for envelope writes derived from model
/// timestamps (which round-trip epoch seconds themselves).
int _epochSecondsOf(DateTime dateTime) =>
    dateTime.millisecondsSinceEpoch ~/ 1000;

void _submitReconcilePull(
  Ref ref, {
  required String reason,
  required String scope,
  required String action,
}) {
  DebugLogger.log(
    'reconcile-after-remote-mutation',
    scope: scope,
    data: {'action': action},
  );
  Future<PullResult?> pull;
  try {
    pull = ref.read(syncEngineProvider.notifier).requestPull(reason: reason);
  } catch (error, stackTrace) {
    DebugLogger.error(
      'reconcile-pull-failed',
      scope: scope,
      error: error,
      stackTrace: stackTrace,
      data: {'action': action},
    );
    return;
  }
  unawaited(
    pull.catchError((Object error, StackTrace stackTrace) {
      DebugLogger.error(
        'reconcile-pull-failed',
        scope: scope,
        error: error,
        stackTrace: stackTrace,
        data: {'action': action},
      );
      return null;
    }),
  );
}

/// Runtime provenance attached to conversation summaries and full loads.
///
/// Chat ids are not a sufficient discriminator because independent databases
/// can legally contain the same id. This marker is app-owned and never used as
/// routing authority for model requests.
const String kDirectChatBackend = 'direct';

Conversation withChatStorageProvenance(
  Conversation conversation,
  ChatStorageKind storage,
) {
  final annotated = annotateConversationStorage(conversation, storage);
  final metadata = <String, dynamic>{
    ...annotated.metadata,
    if (storage == ChatStorageKind.directLocal) ...{
      'backend': kDirectChatBackend,
      'onDevice': true,
    },
  };
  return annotated.copyWith(metadata: metadata);
}

ChatStorageKind? chatStorageKindOf(Conversation? conversation) {
  if (conversation == null) return null;
  return chatStorageFromConversation(conversation);
}

bool isDirectLocalConversation(Conversation? conversation) =>
    chatStorageKindOf(conversation) == ChatStorageKind.directLocal;

/// Whether [conversation] is a process-local direct shell that has not yet
/// acquired durable storage provenance.
///
/// An explicit storage annotation always wins: OpenWebUI-owned conversations
/// may legitimately record that their latest turn used the direct transport.
bool _isUnstoredDirectConversation(Conversation? conversation) =>
    conversation != null &&
    chatStorageKindOf(conversation) == null &&
    conversation.metadata['backend'] == kDirectChatBackend;

/// Collision-free identity for selections and widget/provider keys.
///
/// [Conversation.id] remains the provider/server id. This value is only for
/// app-internal identity where two independent databases may contain that id.
String conversationScopedId(Conversation conversation) {
  var storage = chatStorageKindOf(conversation);
  // Unannotated persisted conversations predate multi-store history and have
  // always meant OpenWebUI. Scope that legacy default too; otherwise a newly
  // created server chat can briefly expose an ambiguous raw id to listeners.
  if (storage == null &&
      !isTemporaryChat(conversation.id) &&
      !isNativeHermesConversation(conversation) &&
      !_isUnstoredDirectConversation(conversation)) {
    storage = ChatStorageKind.openWebUi;
  }
  return ChatStorageIdentity(rawId: conversation.id, storage: storage).scopedId;
}

bool conversationMatchesScopedId(Conversation conversation, String scopedId) {
  final identity = ChatStorageIdentity.parse(scopedId);
  if (conversation.id != identity.rawId) return false;
  final storage = identity.storage;
  // Native Hermes shells are runtime-owned and intentionally unscoped. A
  // persisted row can legally reuse the same raw id, but its scoped selection
  // must never match or mutate the native shell.
  if (storage != null &&
      (isNativeHermesConversation(conversation) ||
          _isUnstoredDirectConversation(conversation))) {
    return false;
  }
  return storage == null ||
      (chatStorageKindOf(conversation) ?? ChatStorageKind.openWebUi) == storage;
}

bool isSameStoredConversation(Conversation? left, Conversation? right) {
  if (left == null || right == null || left.id != right.id) return false;
  // A native Hermes shell is process-owned and deliberately has no persisted
  // storage annotation. Do not let a server row with the same raw id collide
  // with it through the legacy "unannotated means OpenWebUI" fallback.
  final leftIsNativeHermes = isNativeHermesConversation(left);
  final rightIsNativeHermes = isNativeHermesConversation(right);
  if (leftIsNativeHermes != rightIsNativeHermes) return false;
  if (leftIsNativeHermes) return true;
  // A temporary direct shell is runtime-owned just like a native Hermes
  // shell. It must not alias a colliding legacy OpenWebUI row merely because
  // both currently lack a storage annotation.
  final leftIsUnstoredDirect = _isUnstoredDirectConversation(left);
  final rightIsUnstoredDirect = _isUnstoredDirectConversation(right);
  if (leftIsUnstoredDirect != rightIsUnstoredDirect) return false;
  if (leftIsUnstoredDirect) return true;
  // Unannotated conversations predate multi-store history and therefore
  // retain their historical Open WebUI meaning.
  final leftStorage = chatStorageKindOf(left) ?? ChatStorageKind.openWebUi;
  final rightStorage = chatStorageKindOf(right) ?? ChatStorageKind.openWebUi;
  return leftStorage == rightStorage;
}

int _conversationIndexForSelection(
  List<Conversation> conversations,
  String scopedId,
) {
  final identity = ChatStorageIdentity.parse(scopedId);
  if (identity.storage != null) {
    return conversations.indexWhere(
      (conversation) => conversationMatchesScopedId(conversation, scopedId),
    );
  }

  final matchingIndexes = <int>[];
  for (var index = 0; index < conversations.length; index++) {
    if (conversations[index].id == identity.rawId) {
      matchingIndexes.add(index);
    }
  }
  if (matchingIndexes.length <= 1) {
    return matchingIndexes.firstOrNull ?? -1;
  }

  // Legacy unscoped callers historically referred to Open WebUI ids. Keep
  // that behavior deterministic when a new local row happens to collide.
  return matchingIndexes.firstWhere(
    (index) =>
        (chatStorageKindOf(conversations[index]) ??
            ChatStorageKind.openWebUi) ==
        ChatStorageKind.openWebUi,
    orElse: () => matchingIndexes.first,
  );
}

// Conversation list provider — Drift-backed read path (CDT-RFC-001 Phase 1).
//
// The list renders from `ChatsDao.watchChatList()` (a narrow projection that
// never selects message bodies). Mutators keep their synchronous in-memory
// update for snappiness and write the same envelope change to the database in
// the same call, so the next stream emission always agrees with the
// optimistic state.
@Riverpod(keepAlive: true)
class _ConversationListPageTick extends _$ConversationListPageTick {
  @override
  int build() => 0;

  void bump() => state++;
}
