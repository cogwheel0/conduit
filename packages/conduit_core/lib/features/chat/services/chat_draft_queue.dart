/// Drafts queued behind a running Open WebUI response.
///
/// Like Open WebUI's own queue, every draft waiting when the response finishes
/// is combined into one next message (text joined by a blank line, attachments
/// in order) and sent once. Drafts live in session memory only: a restart loses
/// them, which the composer says when it queues one.
///
/// A queue belongs to one conversation of one signed-in account on one server.
/// It follows a local-to-server id remap, drains only while that conversation
/// is the one on screen under the same account, and hands its batch to the
/// same durable send every ordinary message uses. Failed or offline completion
/// retries stay with the outbox; this queue never feeds them.
library;

import 'dart:async';

import 'package:meta/meta.dart';
import 'package:riverpod/riverpod.dart';
import 'package:uuid/uuid.dart';

import 'package:conduit_core/features/chat/models/chat_context_attachment.dart';
import 'package:conduit_core/features/chat/providers/attached_files_provider.dart';
import 'package:conduit_core/features/chat/providers/chat_providers.dart';
import 'package:conduit_core/features/chat/providers/context_attachments_provider.dart';
import 'package:conduit_core/features/direct_connections/direct_connections.dart';
import 'package:conduit_core/features/hermes/models/hermes_model.dart';
import 'package:conduit_core/features/tools/providers/tools_providers.dart';
import 'package:conduit_core/database/database_provider.dart';
import 'package:conduit_core/models/conversation.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/sync/id_remapper.dart' show RemapEvent;
import 'package:conduit_core/sync/sync_engine.dart';
import 'package:conduit_core/utils/debug_logger.dart';

/// Whether the visible Open WebUI conversation is still producing its main
/// answer. A queue drains only once this is false.
///
/// This is the single owner of what "finished" means for the queue, so a
/// change to it reaches queued drafts too. An answer is finished when its own
/// `done` signal has been handled. Title, tag and follow-up work arrives as
/// separate events after that and never holds a draft back.
///
/// A model comparison has one main answer per model, and all of them end the
/// transcript. [isChatStreamingProvider] stays true while any one of them
/// streams, so the queue waits for the last slot whichever finishes first.
final chatMainAnswerActiveProvider = Provider<bool>(
  (ref) => ref.watch(isChatStreamingProvider),
);

/// Whether a draft's files are ready to send.
enum ChatDraftReadiness {
  ready,

  /// A file is still uploading, so the whole queue waits.
  uploading,

  /// A file failed or is gone. The draft stays editable; nothing is dropped.
  failed,
}

/// One queued message: what the composer held when it was queued.
@immutable
final class QueuedChatDraft {
  const QueuedChatDraft({
    required this.id,
    required this.text,
    this.attachmentIds = const <String>[],
    this.contextAttachments = const <ChatContextAttachment>[],
  });

  final String id;
  final String text;

  /// The draft's files, in the order they were attached. Each names the
  /// [QueuedDraftAttachment] this draft's queue captured for it, where its
  /// upload keeps reporting. A pathname never identifies one.
  final List<String> attachmentIds;
  final List<ChatContextAttachment> contextAttachments;

  QueuedChatDraft copyWith({String? text, List<String>? attachmentIds}) =>
      QueuedChatDraft(
        id: id,
        text: text ?? this.text,
        attachmentIds: attachmentIds ?? this.attachmentIds,
        contextAttachments: contextAttachments,
      );
}

/// Where a queue is in handing its drafts over.
enum ChatDraftQueuePhase {
  idle,

  /// Send-now is stopping the running response before it admits one draft.
  stopping,

  /// A frozen batch is being admitted to the outbox.
  admitting,
}

/// The drafts waiting on one conversation, with the owner they were queued
/// under.
@immutable
final class ChatDraftQueue {
  const ChatDraftQueue._({
    required this.id,
    required this.chatId,
    required this.database,
    required this.api,
    required this.authSessionEpoch,
    required this.drafts,
    this.phase = ChatDraftQueuePhase.idle,
    this.frozenDraftIds = const <String>[],
    this.admissionFailed = false,
  });

  final String id;

  /// The conversation's id, following a local-to-server remap.
  final String chatId;
  final Object? database;
  final Object? api;
  final Object? authSessionEpoch;
  final List<QueuedChatDraft> drafts;
  final ChatDraftQueuePhase phase;

  /// The drafts a stop or an admission is working on right now. They cannot be
  /// edited or removed; any others can.
  final List<String> frozenDraftIds;

  /// The last batch was refused before it was committed. The drafts are still
  /// here; nothing sends them again until the user retries.
  final bool admissionFailed;

  ChatDraftQueue _copyWith({
    String? chatId,
    List<QueuedChatDraft>? drafts,
    ChatDraftQueuePhase? phase,
    List<String>? frozenDraftIds,
    bool? admissionFailed,
  }) => ChatDraftQueue._(
    id: id,
    chatId: chatId ?? this.chatId,
    database: database,
    api: api,
    authSessionEpoch: authSessionEpoch,
    drafts: drafts ?? this.drafts,
    phase: phase ?? this.phase,
    frozenDraftIds: frozenDraftIds ?? this.frozenDraftIds,
    admissionFailed: admissionFailed ?? this.admissionFailed,
  );

  QueuedChatDraft? draftById(String draftId) =>
      drafts.where((draft) => draft.id == draftId).firstOrNull;

  bool isFrozen(String draftId) => frozenDraftIds.contains(draftId);
}

/// What became of a send-now request.
enum ChatDraftSendNowOutcome {
  /// The draft was committed as the next turn.
  admitted,

  /// There is no such draft, or the conversation cannot take a queued turn.
  unavailable,

  /// The draft has a file that is not ready.
  blockedByUpload,

  /// The server did not accept the stop, so nothing was sent.
  stopFailed,

  /// The conversation or account changed while the response was stopping.
  changed,

  /// The turn was refused before it was committed. The draft is still queued.
  admissionFailed,
}

/// Where [draftId] goes back among [ids], given [seenOrder], the ids in the
/// order the user saw when it was removed (the draft included).
///
/// It goes right after the nearest draft that preceded it there and is still
/// in [ids], else right before the nearest one that followed it. Neighbours
/// that left meanwhile, or were removed and are not back yet, are skipped, so
/// drafts removed one after another and put back in any order end up in the
/// order they started in. With no neighbour left, or no [seenOrder], it goes
/// to [fallback], clamped to [ids].
int chatDraftRestoreIndex(
  List<String> ids, {
  required List<String> seenOrder,
  required String draftId,
  required int fallback,
}) {
  final at = seenOrder.indexOf(draftId);
  if (at >= 0) {
    for (var i = at - 1; i >= 0; i--) {
      final found = ids.indexOf(seenOrder[i]);
      if (found >= 0) return found + 1;
    }
    for (var i = at + 1; i < seenOrder.length; i++) {
      final found = ids.indexOf(seenOrder[i]);
      if (found >= 0) return found;
    }
  }
  return fallback.clamp(0, ids.length);
}

/// [draft]'s files in order, found among the files [queue] itself captured. A
/// file another queue holds, under another account or on another chat, is never
/// one of them, even at the same pathname. A file that is no longer held is
/// null.
List<QueuedDraftAttachment?> chatDraftFiles(
  ChatDraftQueue queue,
  QueuedChatDraft draft,
  List<QueuedDraftAttachment> held,
) => [
  for (final id in draft.attachmentIds)
    held
        .where((entry) => entry.queueId == queue.id && entry.id == id)
        .firstOrNull,
];

/// Whether [draft]'s files are all uploaded, judged against [held].
ChatDraftReadiness chatDraftReadiness(
  ChatDraftQueue queue,
  QueuedChatDraft draft,
  List<QueuedDraftAttachment> held,
) {
  var uploading = false;
  for (final entry in chatDraftFiles(queue, draft, held)) {
    final file = entry?.upload;
    if (file == null) return ChatDraftReadiness.failed;
    switch (file.status) {
      case FileUploadStatus.failed:
        return ChatDraftReadiness.failed;
      case FileUploadStatus.pending:
      case FileUploadStatus.uploading:
        uploading = true;
      case FileUploadStatus.completed:
        if (file.fileId == null) return ChatDraftReadiness.failed;
    }
  }
  return uploading ? ChatDraftReadiness.uploading : ChatDraftReadiness.ready;
}

/// Whether the conversation on screen is an Open WebUI chat that takes queued
/// turns: stored, on an Open WebUI model, with a database to commit to.
///
/// A chat that is still being created has a `local:` id. It may hold drafts,
/// but its own sends take the inline path, which has no committed receipt, so
/// nothing drains until the remap gives it its server id (see
/// [_canDrainRoute]).
bool _queueableRoute(dynamic read) {
  final active = read(activeConversationProvider) as Conversation?;
  if (active == null ||
      chatMutationOwnerScopeForConversation(active) !=
          openWebUiChatMutationOwnerScope(active.id)) {
    return false;
  }
  final model = read(selectedModelProvider);
  if (model == null ||
      isHermesModel(model) ||
      hasReservedDirectIdentity(model) ||
      read(directModelRegistryProvider).resolve(model) != null) {
    return false;
  }
  return read(appDatabaseProvider) != null &&
      read(apiServiceProvider) != null &&
      read(reviewerModeProvider) != true &&
      read(temporaryChatEnabledProvider) != true;
}

/// Whether the visible queue's batch could be committed now: its conversation
/// has its server id, so the send takes the durable path with a receipt.
bool _canDrainRoute(dynamic read) {
  final active = read(activeConversationProvider) as Conversation?;
  return active != null && !isTemporaryChat(active.id) && _queueableRoute(read);
}

/// Whether a draft may be queued now: a response is running on a conversation
/// that takes queued turns. Existing drafts stay visible and manageable
/// whatever this says.
final chatDraftQueueOfferProvider = Provider<bool>((ref) {
  if (!ref.watch(chatMainAnswerActiveProvider)) return false;
  return _queueableRoute(ref.watch);
});

ChatDraftQueue? _queueForActive(dynamic read, List<ChatDraftQueue> queues) {
  final active = read(activeConversationProvider) as Conversation?;
  if (active == null ||
      chatMutationOwnerScopeForConversation(active) !=
          openWebUiChatMutationOwnerScope(active.id)) {
    return null;
  }
  final database = read(appDatabaseProvider);
  final api = read(apiServiceProvider);
  final epoch = read(openWebUiAuthSessionEpochProvider);
  return queues
      .where(
        (queue) =>
            queue.chatId == active.id &&
            identical(queue.database, database) &&
            identical(queue.api, api) &&
            identical(queue.authSessionEpoch, epoch),
      )
      .firstOrNull;
}

/// The queue of the conversation on screen under the account that is signed
/// in, or null. A queue of another conversation or account never shows here.
final activeChatDraftQueueProvider = Provider<ChatDraftQueue?>(
  (ref) => _queueForActive(ref.watch, ref.watch(chatDraftQueueProvider)),
);

final chatDraftQueueProvider =
    NotifierProvider<ChatDraftQueueController, List<ChatDraftQueue>>(
      ChatDraftQueueController.new,
    );

class ChatDraftQueueController extends Notifier<List<ChatDraftQueue>> {
  bool _drainScheduled = false;
  bool _lifetimeNoticeShown = false;

  /// True the first time it is asked in a session. Queued drafts do not survive
  /// a restart, and the composer says so once, when the first one is queued.
  bool takeLifetimeNotice() {
    final first = !_lifetimeNoticeShown;
    _lifetimeNoticeShown = true;
    return first;
  }

  @override
  List<ChatDraftQueue> build() {
    void reevaluate(dynamic previous, dynamic next) => _scheduleDrain();
    ref.listen(chatMainAnswerActiveProvider, reevaluate);
    ref.listen(activeConversationProvider, reevaluate);
    ref.listen(isLoadingConversationProvider, reevaluate);
    ref.listen(queuedDraftAttachmentsProvider, reevaluate);
    ref.listen(selectedModelProvider, reevaluate);
    ref.listen(appDatabaseProvider, reevaluate);
    ref.listen(apiServiceProvider, reevaluate);
    ref.listen(openWebUiAuthSessionEpochProvider, reevaluate);
    final remaps = ref
        .read(syncEngineProvider.notifier)
        .remapEvents
        .listen(_followRemap);
    ref.onDispose(remaps.cancel);
    return const <ChatDraftQueue>[];
  }

  ChatDraftQueue? get _active => _queueForActive(ref.read, state);

  int _indexOf(String queueId) =>
      state.indexWhere((queue) => queue.id == queueId);

  void _replace(String queueId, ChatDraftQueue Function(ChatDraftQueue) edit) {
    final index = _indexOf(queueId);
    if (index < 0 || !ref.mounted) return;
    final next = edit(state[index]);
    state = [
      for (var i = 0; i < state.length; i++)
        if (i != index)
          state[i]
        else if (next.drafts.isNotEmpty ||
            next.phase != ChatDraftQueuePhase.idle)
          next,
    ];
  }

  /// Queues what the composer holds behind the running response and clears it.
  /// Returns null when nothing can be queued now. The composer's files leave
  /// the tray but keep uploading, and a file that has not finished delays the
  /// whole queue rather than being dropped.
  QueuedChatDraft? enqueue(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty ||
        !ref.read(chatMainAnswerActiveProvider) ||
        !_queueableRoute(ref.read)) {
      return null;
    }
    final active = ref.read(activeConversationProvider)!;
    final owner = captureChatMutationOwner(ref, active);

    final tray = ref.read(attachedFilesProvider);
    final context = ref.read(contextAttachmentsProvider);
    final existing = _active;
    final queueId = existing?.id ?? const Uuid().v4();
    // Each file is captured for this queue under an id of its own, so it stays
    // this draft's file however its upload is later replaced.
    final held = [
      for (final file in tray)
        QueuedDraftAttachment(
          id: const Uuid().v4(),
          queueId: queueId,
          upload: file,
        ),
    ];
    final draft = QueuedChatDraft(
      id: const Uuid().v4(),
      text: trimmed,
      attachmentIds: [for (final file in held) file.id],
      contextAttachments: List<ChatContextAttachment>.unmodifiable(context),
    );

    if (existing == null) {
      state = [
        ...state,
        ChatDraftQueue._(
          id: queueId,
          chatId: active.id,
          database: owner.openWebUiDatabase,
          api: owner.openWebUiApi,
          authSessionEpoch: owner.openWebUiAuthSessionEpoch,
          drafts: [draft],
        ),
      ];
    } else {
      _replace(
        existing.id,
        (queue) => queue._copyWith(drafts: [...queue.drafts, draft]),
      );
    }
    // Only what was captured above moves, and only once the draft is stored, so
    // a composer edit made meanwhile is never lost.
    ref.read(queuedDraftAttachmentsProvider.notifier).adopt(held);
    ref.read(attachedFilesProvider.notifier).releaseIdentical(tray);
    ref.read(contextAttachmentsProvider.notifier).clear();
    return draft;
  }

  /// Replaces a draft's text. A draft being sent cannot change.
  bool editDraft(String draftId, String text) {
    final queue = _active;
    final trimmed = text.trim();
    if (queue == null ||
        trimmed.isEmpty ||
        queue.draftById(draftId) == null ||
        queue.isFrozen(draftId)) {
      return false;
    }
    _replace(
      queue.id,
      (queue) => queue._copyWith(
        drafts: [
          for (final draft in queue.drafts)
            if (draft.id == draftId) draft.copyWith(text: trimmed) else draft,
        ],
        admissionFailed: false,
      ),
    );
    // The failure that held the queue is cleared, so nothing else will look at
    // it again: a ready queue must be reevaluated here. Admission itself still
    // asks a refused Stop again before it sends anything.
    _scheduleDrain();
    return true;
  }

  /// Removes a draft and its files. A draft being sent cannot be removed.
  bool removeDraft(String draftId) {
    final queue = _active;
    final draft = queue?.draftById(draftId);
    if (queue == null || draft == null || queue.isFrozen(draftId)) {
      return false;
    }
    _replace(
      queue.id,
      (queue) => queue._copyWith(
        drafts: [
          for (final other in queue.drafts)
            if (other.id != draftId) other,
        ],
        admissionFailed: false,
      ),
    );
    _releaseAttachments(queue.id, draft.attachmentIds);
    _scheduleDrain();
    return true;
  }

  /// Puts back a draft the user just removed, at [index] of the queue it left
  /// (or of the queue the chat has now). [from] is that queue as it was when
  /// the draft was removed; it names the chat and account the draft belongs
  /// to, and nothing is restored under any other.
  ///
  /// [seenOrder], when given, is the order of draft ids the user saw when they
  /// removed it, the draft included. The draft then goes back next to the
  /// neighbours it had there (see [chatDraftRestoreIndex]), so drafts removed
  /// one after another and put back in any order keep their original order;
  /// [index] only applies when none of those neighbours is queued.
  ///
  /// [attachments] are the draft's files as they were held then, in order. An
  /// upload is never resumed, so a draft comes back only when every one of its
  /// files had finished uploading. Returns whether the draft is queued again.
  bool restoreDraft(
    ChatDraftQueue from,
    QueuedChatDraft draft,
    int index, {
    List<QueuedDraftAttachment> attachments = const <QueuedDraftAttachment>[],
    List<String> seenOrder = const <String>[],
  }) {
    if (attachments.length != draft.attachmentIds.length) return false;
    for (final (i, held) in attachments.indexed) {
      if (held.id != draft.attachmentIds[i] ||
          held.queueId != from.id ||
          held.upload.status != FileUploadStatus.completed ||
          held.upload.fileId == null) {
        return false;
      }
    }
    final active = ref.read(activeConversationProvider);
    if (active == null ||
        active.id != from.chatId ||
        !_queueableRoute(ref.read) ||
        !identical(ref.read(appDatabaseProvider), from.database) ||
        !identical(ref.read(apiServiceProvider), from.api) ||
        !identical(
          ref.read(openWebUiAuthSessionEpochProvider),
          from.authSessionEpoch,
        )) {
      return false;
    }
    final current = _active;
    if (current != null &&
        current.drafts.any((other) => other.id == draft.id)) {
      return false;
    }

    // Removing the last draft dropped its queue. The draft then comes back in
    // a queue of the same identity, so its files keep their owner.
    final queueId = current?.id ?? from.id;
    if (current == null) {
      state = [
        ...state,
        ChatDraftQueue._(
          id: from.id,
          chatId: from.chatId,
          database: from.database,
          api: from.api,
          authSessionEpoch: from.authSessionEpoch,
          drafts: [draft],
        ),
      ];
    } else {
      _replace(
        current.id,
        (queue) => queue._copyWith(
          drafts: [...queue.drafts]
            ..insert(
              chatDraftRestoreIndex(
                [for (final other in queue.drafts) other.id],
                seenOrder: seenOrder,
                draftId: draft.id,
                fallback: index,
              ),
              draft,
            ),
        ),
      );
    }
    ref.read(queuedDraftAttachmentsProvider.notifier).adopt([
      for (final held in attachments)
        QueuedDraftAttachment(
          id: held.id,
          queueId: queueId,
          upload: held.upload,
        ),
    ]);
    _scheduleDrain();
    return true;
  }

  /// Removes one file from a draft, typically one that failed to upload.
  bool removeDraftAttachment(String draftId, String attachmentId) {
    final queue = _active;
    final draft = queue?.draftById(draftId);
    if (queue == null ||
        draft == null ||
        queue.isFrozen(draftId) ||
        !draft.attachmentIds.contains(attachmentId)) {
      return false;
    }
    _replace(
      queue.id,
      (queue) => queue._copyWith(
        drafts: [
          for (final other in queue.drafts)
            if (other.id == draftId)
              other.copyWith(
                attachmentIds: [
                  for (final owned in other.attachmentIds)
                    if (owned != attachmentId) owned,
                ],
              )
            else
              other,
        ],
        admissionFailed: false,
      ),
    );
    _releaseAttachments(queue.id, [attachmentId]);
    // A file the queue no longer holds releases nothing, and so wakes nothing.
    _scheduleDrain();
    return true;
  }

  /// Lets a queue whose last batch was refused try again.
  void retryAdmission() {
    final queue = _active;
    if (queue == null || !queue.admissionFailed) return;
    _replace(queue.id, (queue) => queue._copyWith(admissionFailed: false));
    _scheduleDrain();
  }

  /// Stops the running response and sends one draft as the next turn. The other
  /// drafts stay queued and go out together when that turn finishes.
  Future<ChatDraftSendNowOutcome> sendNow(String draftId) async {
    final queue = _active;
    final draft = queue?.draftById(draftId);
    if (queue == null ||
        draft == null ||
        queue.phase != ChatDraftQueuePhase.idle ||
        !_canDrainRoute(ref.read)) {
      return ChatDraftSendNowOutcome.unavailable;
    }
    final held = ref.read(queuedDraftAttachmentsProvider);
    if (chatDraftReadiness(queue, draft, held) != ChatDraftReadiness.ready) {
      return ChatDraftSendNowOutcome.blockedByUpload;
    }

    // The cancellation is certified for the conversation and account that were
    // on screen when the user asked, however long the server takes to answer.
    final owner = captureChatMutationOwner(
      ref,
      ref.read(activeConversationProvider),
    );
    final queueId = queue.id;
    _replace(
      queueId,
      (queue) => queue._copyWith(
        phase: ChatDraftQueuePhase.stopping,
        frozenDraftIds: [draftId],
      ),
    );
    try {
      final stopped = await stopOpenWebUiMainResponse(ref);
      if (!ref.mounted) return ChatDraftSendNowOutcome.changed;
      if (!stopped) {
        // The response has stopped on screen, so the queue would otherwise send
        // the draft on its own as soon as it is idle, with the server's task
        // possibly still running. It waits for the user to retry instead.
        _replace(queueId, (queue) => queue._copyWith(admissionFailed: true));
        return ChatDraftSendNowOutcome.stopFailed;
      }
      if (!chatMutationTokenStillActive(ref, owner) ||
          _active?.id != queueId ||
          _active?.draftById(draftId) == null) {
        return ChatDraftSendNowOutcome.changed;
      }
      return await _admit(queueId, [draftId]);
    } finally {
      if (ref.mounted) {
        _replace(queueId, (queue) {
          return queue.phase == ChatDraftQueuePhase.stopping
              ? queue._copyWith(
                  phase: ChatDraftQueuePhase.idle,
                  frozenDraftIds: const <String>[],
                )
              : queue;
        });
        _scheduleDrain();
      }
    }
  }

  /// Releases the files this queue captured for the given [attachmentIds].
  /// Each belongs to one draft of this queue alone, so a file another draft or
  /// queue holds at the same pathname is never touched.
  void _releaseAttachments(String queueId, List<String> attachmentIds) {
    ref
        .read(queuedDraftAttachmentsProvider.notifier)
        .release(queueId, attachmentIds);
  }

  /// Several signals can announce the same finished response. They are folded
  /// into one evaluation, and the admission itself is single-flight.
  void _scheduleDrain() {
    if (_drainScheduled) return;
    _drainScheduled = true;
    scheduleMicrotask(() {
      _drainScheduled = false;
      if (!ref.mounted) return;
      unawaited(_drainActive());
    });
  }

  Future<void> _drainActive() async {
    final queue = _active;
    if (queue == null ||
        queue.drafts.isEmpty ||
        queue.phase != ChatDraftQueuePhase.idle ||
        queue.admissionFailed ||
        ref.read(chatMainAnswerActiveProvider) ||
        ref.read(isLoadingConversationProvider) ||
        !_canDrainRoute(ref.read)) {
      return;
    }
    // One file that is still uploading, or failed, holds the whole queue.
    final held = ref.read(queuedDraftAttachmentsProvider);
    if (queue.drafts.any(
      (draft) =>
          chatDraftReadiness(queue, draft, held) != ChatDraftReadiness.ready,
    )) {
      return;
    }
    await _admit(queue.id, [for (final draft in queue.drafts) draft.id]);
  }

  /// Commits the drafts [draftIds] of one queue as a single turn.
  ///
  /// The batch is frozen: the drafts named now, in queue order, are the whole
  /// turn, and anything queued while it is admitted waits for the next one.
  /// Nothing leaves the queue until the send is committed, so a send refused
  /// before that keeps every draft. After that the turn belongs to the outbox,
  /// whatever happens next, and the drafts are never put back.
  Future<ChatDraftSendNowOutcome> _admit(
    String queueId,
    List<String> draftIds,
  ) async {
    // A Stop settles the visible answer before the server has answered, so the
    // response being idle says nothing about its cancellation: a turn is not
    // admitted over one the server has not accepted, and a refused one is asked
    // again here.
    final cancelling = _owedCancellation(queueId);
    if (cancelling != null) {
      final refused = await _settleOwedWork(queueId, draftIds, cancelling);
      if (refused != null) return refused;
    }
    final owed = _owedStoppedAnswers(queueId);
    if (owed != null) {
      final refused = await _settleOwedWork(queueId, draftIds, owed);
      if (refused != null) return refused;
    }
    // Waiting on the server leaves the composer free, so another answer may have
    // started meanwhile. A turn is not sent over it: the drafts stay whole, and
    // the queue drains when that answer is done, as it does after any other.
    if (!ref.mounted) return ChatDraftSendNowOutcome.changed;
    if (ref.read(chatMainAnswerActiveProvider)) {
      _replace(
        queueId,
        (queue) => queue.phase == ChatDraftQueuePhase.admitting
            ? queue._copyWith(
                phase: ChatDraftQueuePhase.idle,
                frozenDraftIds: const <String>[],
              )
            : queue,
      );
      return ChatDraftSendNowOutcome.changed;
    }
    final queue = state.where((queue) => queue.id == queueId).firstOrNull;
    if (queue == null) return ChatDraftSendNowOutcome.unavailable;
    final batch = [
      for (final draft in queue.drafts)
        if (draftIds.contains(draft.id)) draft,
    ];
    if (batch.isEmpty) return ChatDraftSendNowOutcome.unavailable;

    final held = ref.read(queuedDraftAttachmentsProvider);
    final fileIds = <String>[];
    for (final draft in batch) {
      if (chatDraftReadiness(queue, draft, held) != ChatDraftReadiness.ready) {
        return ChatDraftSendNowOutcome.blockedByUpload;
      }
      for (final file in chatDraftFiles(queue, draft, held)) {
        fileIds.add(file!.upload.fileId!);
      }
    }
    final frozenIds = [for (final draft in batch) draft.id];
    final text = batch.map((draft) => draft.text).join('\n\n');
    final contextAttachments = [
      for (final draft in batch) ...draft.contextAttachments,
    ];
    final toolIds = ref.read(selectedToolIdsProvider);

    _replace(
      queueId,
      (queue) => queue._copyWith(
        phase: ChatDraftQueuePhase.admitting,
        frozenDraftIds: frozenIds,
      ),
    );

    ChatSendPlaceholderHandle? placeholder;
    var committed = false;
    try {
      await durableSend(
        ref,
        text,
        fileIds.isEmpty ? null : fileIds,
        toolIds: toolIds.isEmpty ? null : toolIds,
        contextAttachments: contextAttachments,
        onAssistantPlaceholderCreated: (handle) => placeholder = handle,
        onAdmissionCommitted: (receipt) {
          committed = true;
          _commit(queueId, frozenIds);
        },
      );
      return ChatDraftSendNowOutcome.admitted;
    } catch (error, stackTrace) {
      if (committed) {
        // The outbox owns this turn now and replays it; the drafts stay sent.
        DebugLogger.error(
          'queued-drain-after-commit-failed',
          scope: 'chat/draft-queue',
          error: error,
          stackTrace: stackTrace,
        );
        return ChatDraftSendNowOutcome.admitted;
      }
      DebugLogger.error(
        'queued-admission-failed',
        scope: 'chat/draft-queue',
        error: error,
        stackTrace: stackTrace,
      );
      if (ref.mounted) {
        discardUncommittedChatSend(ref, placeholder);
        _replace(
          queueId,
          (queue) => queue._copyWith(
            phase: ChatDraftQueuePhase.idle,
            frozenDraftIds: const <String>[],
            admissionFailed: true,
          ),
        );
      }
      return ChatDraftSendNowOutcome.admissionFailed;
    }
  }

  /// The write of stopped answers the queue's owner still owes its chat, if any.
  /// A stop whose answers could not be stored leaves them owed, and a turn
  /// admitted over them would leave the server holding them as running.
  Future<bool>? _owedStoppedAnswers(String queueId) {
    final queue = state.where((queue) => queue.id == queueId).firstOrNull;
    if (queue == null) return null;
    return ref
        .read(chatMessagesProvider.notifier)
        .settlePendingStoppedAnswers(
          chatId: queue.chatId,
          database: queue.database,
          api: queue.api,
          authSessionEpoch: queue.authSessionEpoch,
        );
  }

  /// The server-side cancellation of a Stop the queue's owner still owes its
  /// chat, if any: one the server has not accepted yet, or refused.
  Future<bool>? _owedCancellation(String queueId) {
    final queue = state.where((queue) => queue.id == queueId).firstOrNull;
    if (queue == null) return null;
    return ref
        .read(chatMessagesProvider.notifier)
        .settlePendingCancellation(
          chatId: queue.chatId,
          database: queue.database,
          api: queue.api,
          authSessionEpoch: queue.authSessionEpoch,
        );
  }

  /// Waits for [owed] (a cancellation or the write of stopped answers) while the
  /// drafts of the batch are frozen. Null when the batch may go on. It belongs
  /// to the store, chat and sign-in it was captured under; if the conversation
  /// or account changed meanwhile, nothing is admitted and the queue is left for
  /// its own owner to drain.
  Future<ChatDraftSendNowOutcome?> _settleOwedWork(
    String queueId,
    List<String> draftIds,
    Future<bool> owed,
  ) async {
    final owner = captureChatMutationOwner(
      ref,
      ref.read(activeConversationProvider),
    );
    _replace(
      queueId,
      (queue) => queue._copyWith(
        phase: ChatDraftQueuePhase.admitting,
        frozenDraftIds: [
          for (final draft in queue.drafts)
            if (draftIds.contains(draft.id)) draft.id,
        ],
      ),
    );
    final stored = await owed;
    if (!ref.mounted) return ChatDraftSendNowOutcome.changed;
    final here =
        chatMutationTokenStillActive(ref, owner) && _active?.id == queueId;
    if (here && stored) return null;
    _replace(
      queueId,
      (queue) => queue._copyWith(
        phase: ChatDraftQueuePhase.idle,
        frozenDraftIds: const <String>[],
        admissionFailed: here ? true : queue.admissionFailed,
      ),
    );
    return here
        ? ChatDraftSendNowOutcome.admissionFailed
        : ChatDraftSendNowOutcome.changed;
  }

  /// The batch is committed: it leaves the queue, and its files with it.
  void _commit(String queueId, List<String> draftIds) {
    final queue = state.where((queue) => queue.id == queueId).firstOrNull;
    if (queue == null || !ref.mounted) return;
    final sent = [
      for (final draft in queue.drafts)
        if (draftIds.contains(draft.id)) draft,
    ];
    _replace(
      queueId,
      (queue) => queue._copyWith(
        drafts: [
          for (final draft in queue.drafts)
            if (!draftIds.contains(draft.id)) draft,
        ],
        phase: ChatDraftQueuePhase.idle,
        frozenDraftIds: const <String>[],
        admissionFailed: false,
      ),
    );
    _releaseAttachments(queueId, [
      for (final draft in sent) ...draft.attachmentIds,
    ]);
  }

  /// A local chat id became its server id: the queue keeps following its chat.
  void _followRemap(RemapEvent event) {
    if (event.entityKind != 'chat' || !ref.mounted) return;
    final database = ref.read(appDatabaseProvider);
    final api = ref.read(apiServiceProvider);
    final epoch = ref.read(openWebUiAuthSessionEpochProvider);
    // The Stop the chat still owes the server follows it before any queue is
    // evaluated again under its new id.
    ref
        .read(chatMessagesProvider.notifier)
        .followChatRemap(
          fromId: event.fromId,
          toId: event.toId,
          database: database,
          api: api,
          authSessionEpoch: epoch,
        );
    var moved = false;
    final next = [
      for (final queue in state)
        if (queue.chatId == event.fromId &&
            identical(queue.database, database) &&
            identical(queue.api, api) &&
            identical(queue.authSessionEpoch, epoch))
          () {
            moved = true;
            return queue._copyWith(chatId: event.toId);
          }()
        else
          queue,
    ];
    if (!moved) return;
    state = next;
    _scheduleDrain();
  }
}
