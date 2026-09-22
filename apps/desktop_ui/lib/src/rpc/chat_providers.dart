import 'dart:async';

import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:jaspr_riverpod/jaspr_riverpod.dart';

import 'rpc_client.dart';
import 'rpc_providers.dart';

/// The sidebar's conversation list.
final chatListProvider = FutureProvider<ChatList>((ref) async {
  ref.watch(coreConnectionProvider);
  // Refetched whenever the daemon says the set changed, rather than polled.
  // The daemon is the only thing that knows when a sync landed.
  ref.watch(_chatsChangedProvider);
  return ref
      .read(rpcClientProvider)
      .call(ConduitMethods.chatsList, decode: ChatList.fromJson);
});

/// Ticks whenever the daemon publishes `chats.changed`.
final _chatsChangedProvider = StreamProvider<int>((ref) {
  var tick = 0;
  return ref
      .watch(rpcClientProvider)
      .events
      .where((envelope) => envelope.event == ConduitEvents.chatsChanged)
      .map((_) => ++tick);
});

/// The models the active server offers, and which is selected.
final modelListProvider = FutureProvider<ModelList>((ref) async {
  ref.watch(coreConnectionProvider);
  return ref
      .watch(rpcClientProvider)
      .call(ConduitMethods.modelsList, decode: ModelList.fromJson);
});

/// Which conversation the transcript is showing. Null is the empty state.
final selectedChatIdProvider = NotifierProvider<SelectedChatId, String?>(
  SelectedChatId.new,
);

class SelectedChatId extends Notifier<String?> {
  @override
  String? build() => null;

  void select(String? chatId) => state = chatId;
}

/// The selected conversation's transcript, as the daemon has it stored.
///
/// Deliberately separate from [liveTranscriptProvider]: this is what was
/// persisted, and it is replaced wholesale when the selection changes. The
/// live overlay is what moves while a turn streams.
final chatDetailProvider = FutureProvider<ChatDetail?>((ref) async {
  final chatId = ref.watch(selectedChatIdProvider);
  if (chatId == null) return null;
  ref.watch(coreConnectionProvider);

  final raw = await ref
      .read(rpcClientProvider)
      .call(
        ConduitMethods.chatsGet,
        params: ChatRef(id: chatId).toJson(),
        decode: (json) => json,
      );
  final chat = raw['chat'];
  return chat == null
      ? null
      : ChatDetail.fromJson(chat as Map<String, dynamic>);
});

/// The turn currently streaming, if any.
class LiveTurn {
  const LiveTurn({
    required this.chatId,
    required this.messageId,
    required this.text,
    this.failedCode,
  });

  final String chatId;
  final String messageId;
  final String text;
  final String? failedCode;

  bool get failed => failedCode != null;
}

/// Applies `turn.*` events to a single in-flight answer.
///
/// Holds only the active turn, not the transcript. When the turn completes
/// the daemon publishes `chats.changed`, [chatDetailProvider] refetches, and
/// the finished message arrives through the same path as every other
/// persisted message -- so there is exactly one place that decides what the
/// transcript is.
final liveTurnProvider = StreamProvider<LiveTurn?>((ref) {
  final client = ref.watch(rpcClientProvider);
  final controller = StreamController<LiveTurn?>();
  LiveTurn? current;

  final subscription = client.events.listen((envelope) {
    switch (envelope.event) {
      case ConduitEvents.turnStarted:
        final started = TurnStarted.fromJson(envelope.payload);
        current = LiveTurn(
          chatId: started.chatId,
          messageId: started.messageId,
          text: '',
        );
      case ConduitEvents.turnDelta:
        final delta = TurnDelta.fromJson(envelope.payload);
        current = LiveTurn(
          chatId: delta.chatId,
          messageId: delta.messageId,
          text: delta.text,
        );
      case ConduitEvents.turnCompleted:
        // Cleared rather than kept: the persisted transcript now has this
        // message, and leaving the overlay up would render it twice.
        current = null;
      case ConduitEvents.turnFailed:
        final failed = TurnFailed.fromJson(envelope.payload);
        current = LiveTurn(
          chatId: failed.chatId,
          messageId: failed.messageId,
          text: failed.partialText,
          failedCode: failed.code,
        );
      default:
        return;
    }
    controller.add(current);
  });

  ref.onDispose(() {
    subscription.cancel();
    controller.close();
  });
  return controller.stream;
});

final chatActionsProvider = Provider<ChatActions>((ref) => ChatActions(ref));

class ChatActions {
  ChatActions(this._ref);

  final Ref _ref;

  RpcClient get _client => _ref.read(rpcClientProvider);

  /// Sends [text], letting the daemon pick the model.
  ///
  /// WP-3.4's picker will pass one explicitly. Until then the daemon resolves
  /// it from the account's selection, which is better than the renderer
  /// fetching a model list purely so it can name what the daemon already
  /// knows.
  Future<SendTurnAccepted> send({required String text, String? model}) async {
    final accepted = await _client.call(
      ConduitMethods.turnsSend,
      params: SendTurn(
        chatId: _ref.read(selectedChatIdProvider),
        model: model,
        text: text,
      ).toJson(),
      decode: SendTurnAccepted.fromJson,
    );
    // A new conversation gets its id from the server, so select it here --
    // otherwise the first answer streams into a transcript the user is not
    // looking at.
    _ref.read(selectedChatIdProvider.notifier).select(accepted.chatId);
    _ref.invalidate(chatDetailProvider);
    return accepted;
  }

  Future<void> stop(String chatId) => _client.call(
    ConduitMethods.turnsStop,
    params: StopTurn(chatId: chatId).toJson(),
    decode: (json) => json,
  );

  Future<ChatList> loadMore() =>
      _client.call(ConduitMethods.chatsLoadMore, decode: ChatList.fromJson);

  void select(String? chatId) =>
      _ref.read(selectedChatIdProvider.notifier).select(chatId);

  /// Chooses the model new turns use.
  ///
  /// Persisted daemon-side with the account rather than held in the window,
  /// so a second window and the next launch agree with this one.
  Future<void> selectModel(String id) async {
    await _client.call(
      ConduitMethods.modelsSelect,
      params: SelectModel(id: id).toJson(),
      decode: ModelList.fromJson,
    );
    _ref.invalidate(modelListProvider);
  }
}
