import 'package:meta/meta.dart';

import '../utils/persisted_message_content.dart' show outputItemsMessageText;
import 'chat_message.dart';

/// Where a conversation's saved `chat.models` list lives in its metadata.
/// Present only when the chat saved more than one model.
const String kConversationModelsMetadataKey = 'openwebui_models';

/// Where an answer's model slot lives in its metadata: a non-negative int, or
/// absent when the stored message has no `modelIdx`.
const String kMessageModelIdxMetadataKey = 'modelIdx';

/// Where a multi-model turn's shown answer lists, by id, the answers of its
/// group (itself included) that the server still reports as not done. A
/// version carries no completion flag of its own, so this is how a stored
/// alternative that holds partial text is told from a finished one. Absent
/// when the server reports none unfinished.
const String kMessageUnfinishedAnswersMetadataKey = 'unfinishedAnswerIds';

/// Where an answer's saved merge lives in its metadata: the upstream
/// `{status, content}` object, or absent.
const String kMessageMergedMetadataKey = 'merged';

extension ChatMessageComparisonFields on ChatMessage {
  /// The model slot this answer belongs to; slot 0 when none was stored.
  int get modelSlot {
    final stored = metadata?[kMessageModelIdxMetadataKey];
    return stored is int && stored >= 0 ? stored : 0;
  }

  /// The merged response saved on this answer, if any.
  ChatMergedResponse? get mergedResponse =>
      ChatMergedResponse.tryFrom(metadata?[kMessageMergedMetadataKey]);
}

/// Open WebUI's `message.merged`: `{status: true, content}`. The server never
/// stores a false status; one means the merge was removed upstream.
@immutable
class ChatMergedResponse {
  const ChatMergedResponse({required this.content});

  final String content;

  static ChatMergedResponse? tryFrom(Object? raw) {
    if (raw is! Map || raw['status'] != true) return null;
    final content = raw['content'];
    return ChatMergedResponse(content: content is String ? content : '');
  }

  @override
  bool operator ==(Object other) =>
      other is ChatMergedResponse && other.content == content;

  @override
  int get hashCode => content.hashCode;
}

/// One stored answer to a prompt, whichever form it is held in: the message
/// the transcript shows, or a stored alternative of it.
@immutable
class ChatComparisonAnswer {
  const ChatComparisonAnswer({
    required this.messageId,
    required this.slot,
    required this.content,
    this.model,
    this.modelName,
    this.versionIndex,
    this.isStreaming = false,
    this.error,
    this.merged,
    this.output,
  });

  final String messageId;

  /// The model slot (`modelIdx`) that produced this answer.
  final int slot;
  final String content;
  final String? model;
  final String? modelName;

  /// Index into the displayed message's `versions`; null for the displayed
  /// message itself.
  final int? versionIndex;
  final bool isStreaming;
  final ChatMessageError? error;
  final ChatMergedResponse? merged;

  /// The structured output the server stored for the answer, when it has one.
  final List<Map<String, dynamic>>? output;

  bool get isDisplayed => versionIndex == null;

  /// The answer's own text as a merge reads it: the joined message items of its
  /// structured output when it has any, otherwise its content (Open WebUI's
  /// `getOutputText(output) || content`). Never its merged response.
  String get sourceText {
    final structured = output == null ? '' : outputItemsMessageText(output!);
    return structured.trim().isNotEmpty ? structured : content;
  }

  /// A short label for the model that answered.
  String get label {
    final name = modelName?.trim();
    if (name != null && name.isNotEmpty) return name;
    final id = model?.trim();
    return id == null || id.isEmpty ? '' : id;
  }
}

/// All answers to one user message, grouped by model slot.
///
/// Open WebUI keeps every answer of a multi-model turn as a child of the same
/// user message and tells them apart with `modelIdx`. Equal model ids in
/// different slots stay different slots; repeated generations of one slot stay
/// together inside it.
@immutable
class ChatComparisonSlot {
  const ChatComparisonSlot({required this.index, required this.answers});

  final int index;

  /// Oldest first; the displayed message, when it belongs to this slot, last.
  final List<ChatComparisonAnswer> answers;

  /// The answer the slot shows: the displayed message if it is this slot's,
  /// otherwise the most recent stored alternative.
  ChatComparisonAnswer get current => answers.last;
}

@immutable
class ChatComparisonGroup {
  const ChatComparisonGroup({required this.parentId, required this.slots});

  /// The user message every answer replies to.
  final String? parentId;
  final List<ChatComparisonSlot> slots;

  /// Whether more than one model slot answered this prompt.
  bool get isComparison => slots.length > 1;

  /// The slot that holds the displayed message.
  ChatComparisonSlot get displayedSlot =>
      slots.firstWhere((slot) => slot.answers.any((a) => a.isDisplayed));

  ChatComparisonSlot? slotAt(int index) {
    for (final slot in slots) {
      if (slot.index == index) return slot;
    }
    return null;
  }

  /// Groups [message] and its stored alternatives by slot. Always returns a
  /// group; [isComparison] says whether it spans more than one slot.
  factory ChatComparisonGroup.fromMessage(ChatMessage message) {
    // A stored copy keeps no completion flag, so the answers the server still
    // reports unfinished are projected as still being written: partial text is
    // never a finished answer.
    final unfinished = <String>{
      ...?(message.metadata?[kMessageUnfinishedAnswersMetadataKey] as List?)
          ?.whereType<String>(),
    };
    final bySlot = <int, List<ChatComparisonAnswer>>{};
    for (var i = 0; i < message.versions.length; i++) {
      final version = message.versions[i];
      final slot = version.modelIdx ?? 0;
      bySlot
          .putIfAbsent(slot, () => <ChatComparisonAnswer>[])
          .add(
            ChatComparisonAnswer(
              messageId: version.id,
              slot: slot,
              content: version.content,
              model: version.model,
              modelName: version.modelName,
              versionIndex: i,
              isStreaming: unfinished.contains(version.id),
              error: version.error,
              merged: ChatMergedResponse.tryFrom(version.merged),
              output: version.output,
            ),
          );
    }
    final displayedSlot = message.modelSlot;
    bySlot
        .putIfAbsent(displayedSlot, () => <ChatComparisonAnswer>[])
        .add(
          ChatComparisonAnswer(
            messageId: message.id,
            slot: displayedSlot,
            content: message.content,
            model: message.model,
            modelName: message.metadata?['modelName']?.toString(),
            isStreaming:
                message.isStreaming || unfinished.contains(message.id),
            error: message.error,
            merged: message.mergedResponse,
            output: message.output,
          ),
        );
    final indexes = bySlot.keys.toList()..sort();
    final parent = message.metadata?['parentId']?.toString();
    return ChatComparisonGroup(
      parentId: parent == null || parent.isEmpty ? null : parent,
      slots: [
        for (final index in indexes)
          ChatComparisonSlot(
            index: index,
            answers: List.unmodifiable(bySlot[index]!),
          ),
      ],
    );
  }
}

/// One answer a comparison turn asked for: the assistant message minted for it
/// at admission, the model that will write it, and its column.
@immutable
class ComparisonSlotSnapshot {
  const ComparisonSlotSnapshot({
    required this.assistantMessageId,
    required this.model,
    required this.modelIdx,
  });

  final String assistantMessageId;
  final String model;
  final int modelIdx;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'assistantMessageId': assistantMessageId,
    'model': model,
    'modelIdx': modelIdx,
  };

  static ComparisonSlotSnapshot? tryFromJson(Object? json) {
    if (json is! Map) return null;
    final id = json['assistantMessageId'];
    final model = json['model'];
    final idx = json['modelIdx'];
    if (id is! String || id.isEmpty || model is! String || model.isEmpty) {
      return null;
    }
    if (idx is! int || idx < 0) return null;
    return ComparisonSlotSnapshot(
      assistantMessageId: id,
      model: model,
      modelIdx: idx,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is ComparisonSlotSnapshot &&
      other.assistantMessageId == assistantMessageId &&
      other.model == model &&
      other.modelIdx == modelIdx;

  @override
  int get hashCode => Object.hash(assistantMessageId, model, modelIdx);
}

/// The answers a comparison turn was admitted with, stored in its
/// `requestCompletion` op so a replay sends the same ONE request for the same
/// assistant messages, in the same order, however many runs recover it.
///
/// An op whose payload has no `comparison` key is an ordinary single-answer
/// turn (including every op queued before comparisons existed). Any present
/// value is a deliberate group: one that cannot be used — null, a scalar, fewer
/// than two answers, a damaged slot, repeated ids — is refused at replay rather
/// than quietly sent as a single or shortened answer.
@immutable
class ComparisonGroupSnapshot {
  const ComparisonGroupSnapshot({
    required this.userMessageId,
    required this.slots,
    this.isIntact = true,
  });

  /// The one user message every slot answers.
  final String userMessageId;

  /// In `message_ids` order; the first is the primary answer.
  final List<ComparisonSlotSnapshot> slots;

  /// False when the stored value was not a well-formed snapshot. [slots] then
  /// holds only the entries that could be read; they are never a usable group,
  /// because the entries that could not be read are not guessed at.
  final bool isIntact;

  bool get isUsable {
    if (!isIntact || userMessageId.isEmpty || slots.length < 2) return false;
    final ids = slots.map((slot) => slot.assistantMessageId).toSet();
    final columns = slots.map((slot) => slot.modelIdx).toSet();
    return ids.length == slots.length && columns.length == slots.length;
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'userMessageId': userMessageId,
    'slots': [for (final slot in slots) slot.toJson()],
  };

  /// Decodes a `comparison` value that IS present in a payload, whatever it
  /// holds. The caller decides "no group" by the key being absent; a null,
  /// scalar, empty, or partly unreadable value decodes to a group that is not
  /// intact, so it stays distinguishable from "no group" and is never usable.
  static ComparisonGroupSnapshot fromJson(Object? json) {
    if (json is! Map) {
      return const ComparisonGroupSnapshot(
        userMessageId: '',
        slots: <ComparisonSlotSnapshot>[],
        isIntact: false,
      );
    }
    final rawSlots = json['slots'];
    final userMessageId = json['userMessageId'];
    final slots = <ComparisonSlotSnapshot>[];
    var intact = userMessageId is String && rawSlots is List;
    if (rawSlots is List) {
      for (final raw in rawSlots) {
        final slot = ComparisonSlotSnapshot.tryFromJson(raw);
        if (slot == null) {
          intact = false;
        } else {
          slots.add(slot);
        }
      }
    }
    return ComparisonGroupSnapshot(
      userMessageId: userMessageId is String ? userMessageId : '',
      slots: slots,
      isIntact: intact,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is ComparisonGroupSnapshot &&
      other.userMessageId == userMessageId &&
      other.isIntact == isIntact &&
      _sameSlots(other.slots, slots);

  static bool _sameSlots(
    List<ComparisonSlotSnapshot> a,
    List<ComparisonSlotSnapshot> b,
  ) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode =>
      Object.hash(userMessageId, isIntact, Object.hashAll(slots));
}
