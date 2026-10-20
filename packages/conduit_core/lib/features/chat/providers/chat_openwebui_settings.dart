part of 'chat_providers.dart';

/// Chat-level generation settings picked before the chat exists.
///
/// They ride into the first durable chat blob (or the first server create), so
/// the turn that creates the chat is already sent with them. In memory only: a
/// different account or an opened chat never inherits them.
///
/// The draft belongs to one server, API and sign-in session. The API object
/// stays the same when another account signs in on the same server, so the
/// auth-session epoch is part of the owner too: it changes on every sign-in,
/// sign-out and account switch, and the draft is dropped with it.
class PendingOpenWebUiChatSettings extends Notifier<Map<String, dynamic>> {
  @override
  Map<String, dynamic> build() {
    ref.watch(apiServiceProvider);
    ref.watch(openWebUiAuthSessionEpochProvider);
    ref.listen<Conversation?>(activeConversationProvider, (_, next) {
      if (next != null && state.isNotEmpty) state = const <String, dynamic>{};
    });
    return const <String, dynamic>{};
  }

  void replace(Map<String, dynamic> params) {
    state = Map<String, dynamic>.unmodifiable(openWebUiChatParamsFrom(params));
  }
}

final pendingOpenWebUiChatSettingsProvider =
    NotifierProvider<PendingOpenWebUiChatSettings, Map<String, dynamic>>(
      PendingOpenWebUiChatSettings.new,
    );

/// What the signed-in user may edit on a chat. Fails closed: an unreadable
/// permission set grants nothing, while a permission the server simply does not
/// report follows the web client's default (allowed).
///
/// The permissions come from the shared [userPermissionsProvider], which owns
/// the transport: it sends with the auth snapshot of the session it was built
/// for and refuses an answer that arrives after the account changed. This
/// provider adds no request of its own. The API object and even the user id can
/// survive a sign-out and back in, so the auth-session epoch is also compared
/// after the await: a late answer for an earlier session is denied rather than
/// handed to the new one.
final openWebUiChatSettingsAccessProvider =
    FutureProvider<OpenWebUiChatSettingsAccess>((ref) async {
      if (ref.watch(reviewerModeProvider)) {
        return OpenWebUiChatSettingsAccess.denied;
      }
      final api = ref.watch(apiServiceProvider);
      final user = ref.watch(currentUserProvider2);
      final epoch = ref.watch(openWebUiAuthSessionEpochProvider);
      if (api == null || user == null) {
        return OpenWebUiChatSettingsAccess.denied;
      }
      if (user.role == 'admin') return OpenWebUiChatSettingsAccess.all;
      try {
        final permissions = await ref.watch(userPermissionsProvider.future);
        if (!ref.mounted ||
            !identical(api, ref.read(apiServiceProvider)) ||
            !identical(epoch, ref.read(openWebUiAuthSessionEpochProvider)) ||
            user.id != ref.read(currentUserProvider2)?.id) {
          return OpenWebUiChatSettingsAccess.denied;
        }
        return OpenWebUiChatSettingsAccess.fromPermissions(
          role: user.role,
          permissions: permissions,
        );
      } catch (_) {
        return OpenWebUiChatSettingsAccess.denied;
      }
    });

/// What the chat overflow offers for per-chat settings.
enum OpenWebUiChatSettingsMenuEntry {
  /// Nothing: not an Open WebUI model/chat, or nothing to show.
  none,

  /// The editor: Advanced is on and the account may edit.
  editor,

  /// A read-only "applied" summary: saved settings are in effect but the
  /// editor is not available (Advanced is off, or the account may not edit).
  applied,
}

/// Decides the overflow entry for the active chat or draft.
///
/// Saved settings apply to a chat whether or not this is offered; this only
/// decides what the user can see and change. Hidden for Hermes and on-device
/// models (their requests never carry these params), for another user's chat,
/// and for any chat that is not an Open WebUI chat.
final openWebUiChatSettingsMenuEntryProvider =
    Provider<OpenWebUiChatSettingsMenuEntry>((ref) {
      if (ref.watch(reviewerModeProvider)) {
        return OpenWebUiChatSettingsMenuEntry.none;
      }
      final model = ref.watch(selectedModelProvider);
      if (model == null || isHermesModel(model)) {
        return OpenWebUiChatSettingsMenuEntry.none;
      }
      final binding = ref.watch(directModelRegistryProvider).resolve(model);
      if (binding != null && binding.source != DirectModelSource.openWebUi) {
        return OpenWebUiChatSettingsMenuEntry.none;
      }
      if (ref.watch(apiServiceProvider) == null) {
        return OpenWebUiChatSettingsMenuEntry.none;
      }

      final conversation = ref.watch(activeConversationProvider);
      if (conversation != null) {
        final isOpenWebUiChat =
            chatMutationOwnerScopeForConversation(conversation) ==
            openWebUiChatMutationOwnerScope(conversation.id);
        if (!isOpenWebUiChat ||
            isReadOnlySharedConversation(
              conversation,
              ref.watch(currentUserProvider2.select((user) => user?.id)),
            )) {
          return OpenWebUiChatSettingsMenuEntry.none;
        }
      }
      final hasSettings = conversation == null
          ? ref.watch(pendingOpenWebUiChatSettingsProvider).isNotEmpty
          : conversation.chatParams.isNotEmpty;

      final canEdit =
          ref
              .watch(openWebUiChatSettingsAccessProvider)
              .asData
              ?.value
              .canEditAnything ??
          false;
      if (ref.watch(
            appSettingsProvider.select((s) => s.advancedFeaturesEnabled),
          ) &&
          canEdit) {
        return OpenWebUiChatSettingsMenuEntry.editor;
      }
      return hasSettings
          ? OpenWebUiChatSettingsMenuEntry.applied
          : OpenWebUiChatSettingsMenuEntry.none;
    });

/// What was last seen of one account's user-level generation settings.
typedef OpenWebUiGlobalSettings = ({
  Map<String, dynamic> params,
  String? systemPrompt,
});

/// Each account's last-seen global generation params and system prompt, in
/// memory. It exists so a turn sent while the server cannot be reached is still
/// admitted with the defaults that account was using, instead of with none.
/// Keyed by server and user: another account on the same server, or the same
/// account on another server, never reads it.
final class OpenWebUiUserSettingsCache {
  final Map<String, OpenWebUiGlobalSettings> _entries =
      <String, OpenWebUiGlobalSettings>{};

  OpenWebUiGlobalSettings? recall(String ownerKey) => _entries[ownerKey];

  void remember(String ownerKey, Map<String, dynamic>? settings) {
    if (settings == null) return;
    _entries[ownerKey] = (
      params: Map<String, dynamic>.unmodifiable(
        openWebUiGlobalParamsFromSettings(settings) ??
            const <String, dynamic>{},
      ),
      systemPrompt: _extractSystemPromptFromSettings(settings),
    );
  }
}

final openWebUiUserSettingsCacheProvider = Provider<OpenWebUiUserSettingsCache>(
  (ref) => OpenWebUiUserSettingsCache(),
);

/// How long admission waits for the account's current settings before it uses
/// what it last saw. A reachable server answers well inside this; an
/// unreachable one must not hold up the send.
const Duration _kAdmissionSettingsTimeout = Duration(seconds: 3);

/// The cache key for the signed-in account on [api]'s server, or null when
/// either is unknown (an account that cannot be named is never cached).
String? _openWebUiSettingsOwnerKey(dynamic ref, Object? api) {
  if (api is! ApiService) return null;
  String? userId;
  try {
    userId = (ref.read(currentUserProvider2) as User?)?.id;
  } catch (_) {
    return null;
  }
  if (userId == null || userId.isEmpty) return null;
  return '${api.serverConfig.id}\u0000$userId';
}

void _rememberOpenWebUiUserSettings(
  dynamic ref,
  String? ownerKey,
  Map<String, dynamic>? settings,
) {
  if (ownerKey == null) return;
  try {
    (ref.read(openWebUiUserSettingsCacheProvider)
            as OpenWebUiUserSettingsCache)
        .remember(ownerKey, settings);
  } catch (_) {
    // The cache is an offline convenience; never fail a send over it.
  }
}

/// The account's global defaults to freeze into a turn being admitted.
///
/// Online, the account's current settings are read through the credentials
/// captured with [owner] (never whoever is signed in by the time the answer
/// arrives) and remembered. When they cannot be read promptly, or the device is
/// offline, the account's last-seen copy is used; with neither, the turn is
/// admitted with no global defaults, and that is what replay sends.
Future<OpenWebUiGlobalSettings> _captureAdmissionGlobalSettings(
  dynamic ref, {
  required ChatMutationOwnerToken owner,
  required String? ownerKey,
}) async {
  const unknown = (
    params: <String, dynamic>{},
    systemPrompt: null,
  );
  final api = owner.openWebUiApi;
  if (api is! ApiService || ownerKey == null) return unknown;
  OpenWebUiUserSettingsCache? cache;
  try {
    cache = ref.read(openWebUiUserSettingsCacheProvider)
        as OpenWebUiUserSettingsCache;
  } catch (_) {}
  var online = true;
  try {
    online = ref.read(isOnlineProvider) as bool;
  } catch (_) {
    // Connectivity is unresolved: try the server, fall back on failure.
  }
  if (online) {
    try {
      final settings = await api
          .getUserSettings(authSnapshot: owner.openWebUiAuthSnapshot)
          .timeout(_kAdmissionSettingsTimeout);
      cache?.remember(ownerKey, settings);
      return (
        params: openWebUiGlobalParamsFromSettings(settings) ??
            const <String, dynamic>{},
        systemPrompt: _extractSystemPromptFromSettings(settings),
      );
    } catch (_) {
      // Fall through to the last-seen copy.
    }
  }
  return cache?.recall(ownerKey) ?? unknown;
}

/// The settings one Open WebUI turn is sent with, captured under its owner.
final class _OpenWebUiTurnSettings {
  const _OpenWebUiTurnSettings({
    required this.chatParams,
    required this.reasoningEffort,
    this.baseline,
  });

  /// The chat's own `params`, verbatim.
  final Map<String, dynamic> chatParams;

  /// The reasoning picker's value for the turn's model; only used when
  /// [chatParams] has no `reasoning_effort` of its own.
  final String? reasoningEffort;

  /// The global defaults and system message the turn was admitted with, when it
  /// is a replay of one. Null for a send that reads the globals live.
  final OpenWebUiAdmittedBaseline? baseline;
}

/// Resolves the chat-level settings for one turn.
///
/// A queued turn carries the [snapshot] it was admitted with and replays it
/// exactly. Otherwise the chat's stored params are read through [owner]'s own
/// database (never whichever chat happens to be on screen), falling back to
/// [conversation] only when that database has no row for the chat, as with a
/// temporary chat or a chat created moments ago whose pull has not landed.
Future<_OpenWebUiTurnSettings> _resolveOpenWebUiTurnSettings(
  OpenWebUiCompletionOwner owner, {
  required Conversation? conversation,
  required String? pickerReasoningEffort,
  OpenWebUiChatSettingsSnapshot? snapshot,
}) async {
  if (snapshot != null) {
    return _OpenWebUiTurnSettings(
      chatParams: snapshot.params,
      reasoningEffort: snapshot.reasoningEffort,
      baseline: snapshot.baseline,
    );
  }
  Map<String, dynamic>? stored;
  final database = owner.database;
  if (database != null) {
    try {
      stored = await database.chatsDao.getChatParams(owner.chatId);
    } catch (_) {
      // An unreadable row falls back to the in-memory copy below.
    }
  }
  return _OpenWebUiTurnSettings(
    chatParams: stored ?? conversation?.chatParams ?? const <String, dynamic>{},
    reasoningEffort: pickerReasoningEffort,
  );
}

/// Puts the system message this turn is sent with at the front of
/// [conversationMessages], unless one is already there. Chat `params.system`
/// (an explicit empty string included), then legacy `chat.system`, then the
/// user's global prompt; folder context is the server's to apply. A replayed
/// turn carries that result in [baseline] and sends it as admitted.
void _insertOpenWebUiSystemMessage(
  List<Map<String, dynamic>> conversationMessages, {
  required Map<String, dynamic> chatParams,
  required String? legacyChatSystem,
  required String? globalSystem,
  OpenWebUiAdmittedBaseline? baseline,
}) {
  final content = baseline != null
      ? baseline.systemMessage
      : resolveOpenWebUiSystemMessage(
          chatParams: chatParams,
          legacyChatSystem: legacyChatSystem,
          globalSystem: globalSystem,
        );
  if (content == null) return;
  final hasSystemMessage = conversationMessages.any(
    (m) => (m['role']?.toString().toLowerCase() ?? '') == 'system',
  );
  if (hasSystemMessage) return;
  conversationMessages.insert(0, <String, dynamic>{
    'role': 'system',
    'content': content,
  });
}

/// The snapshot a durable completion is admitted with: the chat's own params,
/// the picker's value, and the account's global defaults with the system
/// message they resolve to. Nothing in it is read again at replay.
OpenWebUiChatSettingsSnapshot _admissionSettingsSnapshot(
  Map<String, dynamic> chatParams, {
  required String? pickerReasoningEffort,
  required OpenWebUiGlobalSettings globals,
  required String? legacyChatSystem,
}) => OpenWebUiChatSettingsSnapshot(
  params: chatParams,
  reasoningEffort: pickerReasoningEffort,
  baseline: OpenWebUiAdmittedBaseline(
    globalParams: globals.params,
    systemMessage: resolveOpenWebUiSystemMessage(
      chatParams: chatParams,
      legacyChatSystem: legacyChatSystem,
      globalSystem: globals.systemPrompt,
    ),
  ),
);

enum OpenWebUiChatSettingsFailure {
  /// Not an Open WebUI chat (Direct, Apple, Hermes) or no longer addressable.
  notEditable,

  /// The account may not change what was asked for.
  permissionDenied,

  /// The server, account or sign-in session changed while saving.
  ownerChanged,

  /// The chat has no stored copy to edit.
  unavailable,
}

final class OpenWebUiChatSettingsException implements Exception {
  const OpenWebUiChatSettingsException(this.reason);

  final OpenWebUiChatSettingsFailure reason;

  @override
  String toString() => 'OpenWebUiChatSettingsException(${reason.name})';
}

/// Applies one edit to a chat's own params and returns the params now saved.
///
/// [set] writes keys (a null value is an explicit "default"), [remove] makes a
/// key inherit again; every other saved key is left alone. With no
/// [conversation] the edit goes to the draft that seeds the next new chat. For
/// a stored chat it is one transaction that marks the chat dirty and queues
/// the sync, under the chat lock and the database captured when the edit began;
/// a server, account or session change in between aborts without writing.
///
/// A UI that stays open while the user edits passes the [owner] it captured
/// when it opened, so a change made while the form was open is caught too,
/// not only one made while the write was in flight.
Future<Map<String, dynamic>> saveOpenWebUiChatSettings(
  dynamic ref, {
  required Conversation? conversation,
  Map<String, dynamic> set = const <String, dynamic>{},
  Iterable<String> remove = const <String>[],
  ChatMutationOwnerToken? owner,
}) async {
  final token = owner ?? captureChatMutationOwner(ref, conversation);
  if (!token.usesOpenWebUiContext) {
    throw const OpenWebUiChatSettingsException(
      OpenWebUiChatSettingsFailure.notEditable,
    );
  }
  // Another user's shared chat is read-only no matter which UI asked: the
  // overflow menu hides the editor for it, but the reasoning picker and any
  // future caller reach this function directly.
  if (conversation != null &&
      isReadOnlySharedConversation(
        conversation,
        (ref.read(currentUserProvider2) as User?)?.id,
      )) {
    throw const OpenWebUiChatSettingsException(
      OpenWebUiChatSettingsFailure.notEditable,
    );
  }
  final access = await ref.read(
    openWebUiChatSettingsAccessProvider.future,
  ) as OpenWebUiChatSettingsAccess;
  for (final key in <String>{...set.keys, ...remove}) {
    final allowed = key == kChatParamSystem
        ? access.canEditSystemPrompt
        : access.canEditParameters;
    if (!allowed) {
      throw const OpenWebUiChatSettingsException(
        OpenWebUiChatSettingsFailure.permissionDenied,
      );
    }
  }

  bool contextIsCurrent() =>
      identical(_readAppDatabaseOrNull(ref), token.openWebUiDatabase) &&
      identical(_readApiServiceOrNull(ref), token.openWebUiApi) &&
      identical(
        _readOpenWebUiAuthSessionEpoch(ref),
        token.openWebUiAuthSessionEpoch,
      );

  Map<String, dynamic> apply(Map<String, dynamic> base) {
    final next = <String, dynamic>{...base, ...set};
    for (final key in remove) {
      next.remove(key);
    }
    return next;
  }

  if (!contextIsCurrent()) {
    throw const OpenWebUiChatSettingsException(
      OpenWebUiChatSettingsFailure.ownerChanged,
    );
  }

  if (conversation == null) {
    if (!chatMutationTokenStillActive(ref, token)) {
      throw const OpenWebUiChatSettingsException(
        OpenWebUiChatSettingsFailure.ownerChanged,
      );
    }
    final draft = apply(
      ref.read(pendingOpenWebUiChatSettingsProvider) as Map<String, dynamic>,
    );
    (ref.read(
      pendingOpenWebUiChatSettingsProvider.notifier,
    ) as PendingOpenWebUiChatSettings).replace(draft);
    return draft;
  }

  final chatId = conversation.id;
  final database = token.openWebUiDatabase;
  Map<String, dynamic>? saved;
  if (database != null) {
    final ChatLocks locks = ref.read(chatLocksProvider);
    final now = ref.read(syncClockProvider).nowEpochSeconds() as int;
    saved = await locks.runExclusive(chatId, () async {
      if (!contextIsCurrent()) {
        throw const OpenWebUiChatSettingsException(
          OpenWebUiChatSettingsFailure.ownerChanged,
        );
      }
      return database.chatsDao.patchChatParamsWithOutbox(
        chatId,
        set: set,
        remove: remove,
        updatedAt: now,
      );
    });
  }
  if (saved == null) {
    // No stored copy: only a temporary chat (kept in memory) may be edited.
    if (!isTemporaryChat(chatId)) {
      throw const OpenWebUiChatSettingsException(
        OpenWebUiChatSettingsFailure.unavailable,
      );
    }
    saved = apply(conversation.chatParams);
  } else if (database != null && contextIsCurrent()) {
    try {
      unawaited(
        (ref.read(syncEngineProvider.notifier) as SyncEngine)
            .drainNowForDatabase(database)
            .catchError((Object _) {}),
      );
    } catch (_) {
      // The op is durable; the next drain trigger sends it.
    }
  }

  final active = ref.read(activeConversationProvider) as Conversation?;
  if (active != null &&
      contextIsCurrent() &&
      chatMutationOwnerScopeForConversation(active) ==
          token.ownerConversationId) {
    final savedParams = saved;
    (ref.read(activeConversationProvider.notifier)
            as ActiveConversationNotifier)
        .set(active.copyWith(chatParams: savedParams));
  }
  return saved;
}

/// The chat (or the draft for the next chat) and the account a reasoning pick
/// was made for. Captured when the picker opens, so a pick that finishes after
/// the user moved to another chat or account is saved on the one it was made
/// for, or not at all.
final class OpenWebUiReasoningPickTarget {
  const OpenWebUiReasoningPickTarget._(this._conversation, this._owner);

  final Conversation? _conversation;
  final ChatMutationOwnerToken _owner;
}

/// Captures the pick target now. A picker UI calls this when it opens and
/// passes the result to [selectReasoningEffortForModel].
OpenWebUiReasoningPickTarget captureOpenWebUiReasoningPickTarget(dynamic ref) {
  final conversation = ref.read(activeConversationProvider) as Conversation?;
  return OpenWebUiReasoningPickTarget._(
    conversation,
    captureChatMutationOwner(ref, conversation),
  );
}

/// Whether a pick on [model] is also saved on the chat: only Open WebUI server
/// models are. Direct, Apple and Hermes keep their device-local pick.
bool _reasoningPickIsSavedOnChat(dynamic ref, Model model) =>
    !isHermesModel(model) &&
    (ref.read(directModelRegistryProvider)).resolve(model) == null;

/// The reasoning picker's selection: records the per-model pick, then, for an
/// Open WebUI model, saves it on the chat too (see
/// [persistOpenWebUiReasoningPick]). The one entry point every picker UI uses.
///
/// Recording the pick awaits local storage; the chat it is saved on is decided
/// before that await, from [target] when the picker captured one when it
/// opened, otherwise from the chat and account active right now.
Future<void> selectReasoningEffortForModel(
  dynamic ref,
  Model model,
  String effort, {
  OpenWebUiReasoningPickTarget? target,
}) async {
  final pickTarget = target ?? captureOpenWebUiReasoningPickTarget(ref);
  final savedOnChat = _reasoningPickIsSavedOnChat(ref, model);
  await setReasoningEffortForModel(ref.read, model, effort);
  if (savedOnChat) {
    await persistOpenWebUiReasoningPick(ref, model, effort, target: pickTarget);
  }
}

/// An explicit reasoning pick on an Open WebUI model also becomes the target
/// chat's (or the next new chat's) saved override, so it outranks whatever the
/// picker held before and travels to other Open WebUI clients. Direct, Apple
/// and Hermes models keep their device-local pick only. "Automatic" saves an
/// explicit default (null), which the server skips. A failure here never
/// undoes the pick itself.
///
/// [target] is the chat and account the pick was made for; without one it is
/// the chat and account active when this is called.
Future<void> persistOpenWebUiReasoningPick(
  dynamic ref,
  Model model,
  String effort, {
  OpenWebUiReasoningPickTarget? target,
}) async {
  if (!_reasoningPickIsSavedOnChat(ref, model)) return;
  final pickTarget = target ?? captureOpenWebUiReasoningPickTarget(ref);
  final String? value;
  try {
    final normalized = normalizeReasoningEffort(effort);
    value = normalized == kAutomaticReasoningEffort ? null : normalized;
  } on FormatException {
    return;
  }
  try {
    await saveOpenWebUiChatSettings(
      ref,
      conversation: pickTarget._conversation,
      owner: pickTarget._owner,
      set: <String, dynamic>{kChatParamReasoningEffort: value},
    );
  } on OpenWebUiChatSettingsException {
    // Denied or not stored: the device-local pick still applies.
  } catch (error) {
    DebugLogger.warning(
      'reasoning-pick-not-saved',
      scope: 'chat/settings',
      data: {'error': error.runtimeType.toString()},
    );
  }
}
