import 'dart:async';

import 'package:meta/meta.dart';
import 'package:riverpod/riverpod.dart';

import 'package:conduit_core/auth/api_auth_interceptor.dart';
import 'package:conduit_core/database/account_storage_isolation.dart';
import 'package:conduit_core/database/database_provider.dart';
import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit_core/features/direct_connections/services/direct_model_registry.dart';
import 'package:conduit_core/features/hermes/models/hermes_model.dart';
import 'package:conduit_core/features/chat/providers/chat_providers.dart'
    show
        ChatMutationOwnerToken,
        captureChatMutationOwner,
        chatMessagesProvider,
        chatMutationTokenStillActive,
        isChatStreamingProvider;
import 'package:conduit_core/models/chat_message.dart';
import 'package:conduit_core/models/model.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/sync/chat_locks.dart';
import 'package:conduit_core/sync/sync_engine.dart';
import 'package:conduit_core/utils/debug_logger.dart';

/// The model the user last picked in an open chat, with the ids of the
/// prompts the chat held then. Open WebUI 0.12.5 regenerates an answer with
/// the model picked now; Conduit's comparisons are per turn, so an answer of
/// a multi-model turn keeps its own model unless a model was picked after
/// that turn was sent. Prompts are named rather than answers, which
/// regenerating replaces, or counted, which deleting a turn changes.
typedef ChatModelPick = ({
  String chatId,
  String modelId,
  Set<String> promptIds,
});

final chatModelPickProvider =
    NotifierProvider<ChatModelPickNotifier, ChatModelPick?>(
      ChatModelPickNotifier.new,
    );

class ChatModelPickNotifier extends Notifier<ChatModelPick?> {
  /// A pick belongs to the account that made it: another account, or the
  /// same one signed in again, starts without one.
  @override
  ChatModelPick? build() {
    ref
      ..watch(currentUserProvider2.select((user) => user?.id))
      ..watch(openWebUiAuthSessionEpochProvider);
    return null;
  }

  void record({
    required String chatId,
    required String modelId,
    required Set<String> promptIds,
  }) {
    state = (chatId: chatId, modelId: modelId, promptIds: promptIds);
  }

  /// Forgets the pick made in chat [chatId], once the chat shows another
  /// branch: the turns it counted are that branch's no more.
  void forget(String chatId) {
    if (state?.chatId == chatId) state = null;
  }
}

/// The chat and account a model picker opened for, captured as it opens and
/// handed to [applyChatModelPick] with the pick.
ChatMutationOwnerToken captureChatModelPickTarget(dynamic ref) =>
    captureChatMutationOwner(ref, ref.read(activeConversationProvider));

/// Makes [model], picked in a picker that opened for [target], the open
/// chat's model and saves it (see [saveChatModelChoice]). Returns whether it
/// was applied.
///
/// A picker can stay open while another chat opens under it, say from a
/// notification, or while the account changes. Its pick is for the chat it
/// opened for, so it is then dropped: it neither changes the chat now open
/// nor is saved on it.
bool applyChatModelPick(
  dynamic ref,
  Model model, {
  required ChatMutationOwnerToken target,
}) {
  if (!chatMutationTokenStillActive(ref, target)) return false;
  ref.read(selectedModelProvider.notifier).set(model);
  unawaited(saveChatModelChoice(ref, model));
  return true;
}

/// Saves [model], which the user just picked (from the model picker or with
/// an @-mention), as the open chat's model.
///
/// Open WebUI 0.12.5's web client saves the chat's model list as soon as the
/// model is changed, so the chat reopens on it even when nothing was sent
/// since. Conduit does the same, through [chatModelSaveQueueProvider]: the
/// list is stored with the local chat and sent as the chat's only changed
/// key, which every supported server merges without touching the chat's
/// date. Only a saved Open WebUI chat this account owns is changed, and only
/// to a model of that server; a new or temporary chat, someone else's chat,
/// and a Direct or Hermes model are left alone.
///
/// [ref] is a `Ref` or `WidgetRef`, read only before the first await.
/// Failures are logged and otherwise ignored: the pick still applies to what
/// is sent next.
Future<void> saveChatModelChoice(dynamic ref, Model model) async {
  final conversation = ref.read(activeConversationProvider);
  if (conversation == null ||
      isTemporaryChat(conversation.id) ||
      !conversationUsesOpenWebUiStorage(conversation)) {
    return;
  }
  if (isLocallyMintedDirectModel(model) || isHermesModel(model)) return;
  final String? userId = ref.read(currentUserProvider2)?.id;
  final String? owner = conversation.userId;
  // Someone else's chat, or one whose owner is known while this account is
  // not yet: nothing is saved.
  if (owner != null && owner != userId) return;
  final String chatId = conversation.id;
  final models = <String>[model.id];

  // Regenerating an answer of a turn sent before now uses this model.
  final List<ChatMessage> messages = ref.read(chatMessagesProvider);
  ref
      .read(chatModelPickProvider.notifier)
      .record(
        chatId: chatId,
        modelId: model.id,
        promptIds: <String>{
          for (final message in messages)
            if (message.role == 'user') message.id,
        },
      );

  // The queue outlives [ref], which may belong to a sheet closing now.
  return ref.read(chatModelSaveQueueProvider.notifier).save(chatId, models);
}

/// Saves chats' model lists, one save at a time.
///
/// Only the newest list asked for each chat is saved, so an earlier pick can
/// never land after a later one. The list is stored with the local chat at
/// once. It is sent to the server once no reply is streaming in the chat: a
/// server before 0.12 merges the change by rewriting the whole chat without
/// a lock, which could overwrite the reply. After the server takes it, the
/// list is stored again, since a pull read before the pick may have put the
/// old one back, and the server's copy keeps its date, so no later pull
/// would correct it. It is sent under the chat's lock, as a push of the
/// whole chat is, so a push begun with the old list cannot land after it. A list belongs to the account that picked it: once
/// another account is signed in, or the same one again, it is neither sent
/// nor stored.
final chatModelSaveQueueProvider = NotifierProvider<ChatModelSaveQueue, void>(
  ChatModelSaveQueue.new,
);

/// A model list waiting to be saved: by the account that picked it, sent
/// with that account's credentials; after a failed send, again once
/// [retryAt] has come, [tries] sends made.
typedef _PendingModels = ({
  List<String> models,
  Object account,
  ApiAuthSnapshot? auth,
  int tries,
  DateTime? retryAt,
});

class ChatModelSaveQueue extends Notifier<void> {
  /// How long a model list waits after each failed send before the next; it
  /// is sent at most once more than there are waits.
  @visibleForTesting
  static List<Duration> modelSaveRetryWaits = const <Duration>[
    Duration(seconds: 1),
    Duration(seconds: 4),
  ];

  /// How long a list waits on a chat that is only listed as running a task,
  /// with no reply streaming on screen, before the server is asked whether
  /// the task still runs.
  @visibleForTesting
  static Duration listedTaskCheckAfter = const Duration(seconds: 30);

  final Map<String, _PendingModels> _pending = <String, _PendingModels>{};

  /// Since when each chat has been waited on only for its task listing.
  final Map<String, DateTime> _listedSince = <String, DateTime>{};

  /// Chats the server ran no task of this account's in, by the listing's
  /// activation token when it said so: while that listing stands, the chat
  /// does not hold its list back.
  final Map<String, int?> _noTaskOfOurs = <String, int?>{};
  Future<void>? _running;

  @override
  void build() {}

  /// The account signed in now. Read, not watched: this queue is only ever
  /// read, so it would not rebuild while a save is under way.
  Object _account() => (
    ref.read(currentUserProvider2)?.id,
    ref.read(openWebUiAuthSessionEpochProvider),
  );

  /// Saves [models] as chat [chatId]'s list; completes once the queue has
  /// nothing left to send.
  Future<void> save(String chatId, List<String> models) {
    final account = _account();
    _pending[chatId] = (
      models: models,
      account: account,
      auth: ref.read(apiServiceProvider)?.captureAuthSnapshot(),
      tries: 0,
      retryAt: null,
    );
    unawaited(_store(chatId, models, account));
    return _running ??= _drain().whenComplete(() => _running = null);
  }

  /// Stores [models] as chat [chatId]'s list, unless an account other than
  /// [account] signed in while the chat was held.
  Future<void> _store(
    String chatId,
    List<String> models,
    Object account, {
    bool confirmed = false,
  }) async {
    final db = ref.read(appDatabaseProvider);
    if (db == null) return;
    try {
      await ref.read(chatLocksProvider).runExclusive(chatId, () async {
        if (!ref.mounted || _account() != account) return;
        await db.chatsDao.setChatModels(chatId, models, confirmed: confirmed);
      });
    } catch (error) {
      _logFailure(chatId, error);
    }
  }

  Future<void> _drain() async {
    while (_pending.isNotEmpty) {
      // A list another account picked is dropped.
      final account = _account();
      _pending.removeWhere((_, pending) => pending.account != account);
      // A chat whose reply still runs waits, as does a list waiting to be
      // sent again; the others' lists go first.
      final now = DateTime.now();
      final chatId = _pending.entries
          .where(
            (entry) =>
                !_streamingIn(entry.key) &&
                !(entry.value.retryAt?.isAfter(now) ?? false),
          )
          .map((entry) => entry.key)
          .firstOrNull;
      if (chatId == null) {
        if (_pending.isEmpty) return;
        // Not waited for: a slow answer must not hold up another chat's list.
        _confirmListedTasks();
        // The state is read again every moment: this queue is only ever
        // read, and Riverpod pauses the listeners of a provider nothing
        // listens to.
        await Future<void>.delayed(const Duration(milliseconds: 250));
        if (!ref.mounted) return;
        continue; // A newer list may have come in meanwhile.
      }
      final queued = _pending.remove(chatId)!;
      final (:models, account: _, :auth, :tries, retryAt: _) = queued;
      final api = ref.read(apiServiceProvider);
      if (api == null) continue;
      var sent = false;
      var replyStarted = false;
      try {
        await ref.read(chatLocksProvider).runExclusive(chatId, () async {
          // Another account may have signed in while the chat was held.
          if (!ref.mounted || _account() != account) return;
          // A reply may have started meanwhile, which the update must not
          // overwrite: the list waits for it again.
          if (_streamingIn(chatId)) {
            replyStarted = true;
            return;
          }
          await api.updateConversation(
            chatId,
            models: models,
            authSnapshot: auth,
          );
          sent = true;
        });
      } catch (error) {
        _logFailure(chatId, error);
        // A pull may put the old list back before a later push of the chat
        // sends this one: it is sent again after a wait, a few times, unless
        // a newer list for the chat came in meanwhile.
        if (tries < modelSaveRetryWaits.length) {
          _pending.putIfAbsent(
            chatId,
            () => (
              models: models,
              account: account,
              auth: auth,
              tries: tries + 1,
              retryAt: DateTime.now().add(modelSaveRetryWaits[tries]),
            ),
          );
        } else if (!_pending.containsKey(chatId)) {
          // Given up: the pick no longer holds over the server's list, so
          // a change made elsewhere shows again.
          ref
              .read(appDatabaseProvider)
              ?.chatsDao
              .releaseUnconfirmedModelList(chatId);
          // A pull while the pick held may have kept it over a list chosen
          // elsewhere, and pulls skip a chat the server has not changed
          // since: the server's copy is read again now.
          _refetchChat(chatId, account);
        }
        continue;
      }
      if (replyStarted) {
        _pending.putIfAbsent(chatId, () => queued);
        continue;
      }
      // A newer list for the chat is stored and sent in its own turn.
      if (sent &&
          ref.mounted &&
          account == _account() &&
          !_pending.containsKey(chatId)) {
        // The server has the list now; copies it sends from here on hold it.
        await _store(chatId, models, account, confirmed: true);
      }
    }
  }

  /// Asks the server about each waiting chat that has long been listed as
  /// running a task with no reply streaming on screen: a listing that an
  /// event missed while offline left behind would hold its list back for
  /// good. The server lists only this account's tasks, while a shared chat
  /// is listed for another person's too, so the listing itself stays; the
  /// list is sent once the server runs none of this account's there, which
  /// is safe: servers before 0.12, whose update rewrites the chat, have no
  /// shared replies, and later ones merge the change.
  void _confirmListedTasks() {
    final now = DateTime.now();
    final listed = ref.read(activeChatIdsProvider);
    for (final chatId in _pending.keys.toList()) {
      final onScreen =
          ref.read(activeConversationProvider)?.id == chatId &&
          ref.read(isChatStreamingProvider);
      if (onScreen || !listed.contains(chatId)) {
        _listedSince.remove(chatId);
        continue;
      }
      if (_askingTasksOf.contains(chatId)) continue;
      final since = _listedSince.putIfAbsent(chatId, () => now);
      if (now.difference(since) < listedTaskCheckAfter) continue;
      _listedSince[chatId] = now;
      final api = ref.read(apiServiceProvider);
      if (api == null) continue;
      final token = ref
          .read(activeChatIdsProvider.notifier)
          .activationToken(chatId);
      // Each chat is asked on its own: a slow answer holds up neither
      // another chat's ask nor the queue.
      _askingTasksOf.add(chatId);
      unawaited(
        _confirmNoTaskOfOurs(
          chatId,
          api.getTaskIdsByChat(chatId),
          token,
        ),
      );
    }
  }

  /// Chats whose tasks are being asked for: one ask at a time each.
  final Set<String> _askingTasksOf = <String>{};

  Future<void> _confirmNoTaskOfOurs(
    String chatId,
    Future<List<String>> taskIds,
    int? token,
  ) async {
    try {
      final tasks = await taskIds;
      if (!ref.mounted) return;
      if (tasks.isEmpty) _noTaskOfOurs[chatId] = token;
    } catch (_) {
      // Asked again after another wait.
    } finally {
      _askingTasksOf.remove(chatId);
    }
  }

  /// Whether a reply runs in chat [chatId]: one streaming on screen, or a
  /// task the server runs for it while another chat is open.
  bool _streamingIn(String chatId) {
    if (ref.read(activeConversationProvider)?.id == chatId &&
        ref.read(isChatStreamingProvider)) {
      return true;
    }
    if (!ref.read(activeChatIdsProvider).contains(chatId)) return false;
    // Listed again since the server ran none of ours: it holds again.
    final token = ref
        .read(activeChatIdsProvider.notifier)
        .activationToken(chatId);
    return !(_noTaskOfOurs.containsKey(chatId) &&
        _noTaskOfOurs[chatId] == token);
  }


  /// Reads chat [chatId] from the server, for [account]. A read that fails,
  /// or reads nothing, is tried again after the waits a save is, until one succeeds, a newer
  /// list for the chat comes in, or another account signs in; after the last
  /// wait the chat is left to the next change the server lists.
  void _refetchChat(String chatId, Object? account, {int tries = 0}) {
    void retryLater(Object error) {
      _logFailure(chatId, error);
      if (tries >= modelSaveRetryWaits.length) return;
      unawaited(
        Future<void>.delayed(modelSaveRetryWaits[tries], () {
          if (!ref.mounted ||
              _account() != account ||
              _pending.containsKey(chatId)) {
            return;
          }
          _refetchChat(chatId, account, tries: tries + 1);
        }),
      );
    }

    final Future<Object?> read;
    try {
      read = ref.read(syncEngineProvider.notifier).pullChatNow(chatId);
    } catch (error) {
      retryLater(error);
      return;
    }
    unawaited(
      read.then<void>(
        (Object? conversation) {
          // Nothing read: the engine was not ready, or a bulk change outdated
          // the read.
          if (conversation == null) retryLater(StateError('chat not read'));
        },
        onError: retryLater,
      ),
    );
  }

  void _logFailure(String chatId, Object error) {
    DebugLogger.warning(
      'chat-model-choice-not-saved',
      scope: 'chat/model',
      data: {'chatId': chatId, 'error': error.runtimeType.toString()},
    );
  }
}
