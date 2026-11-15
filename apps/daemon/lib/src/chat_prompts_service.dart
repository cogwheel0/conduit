import 'dart:async';

import 'package:conduit_core/features/chat/composer/openwebui_prompt_answers.dart';
import 'package:conduit_core/features/chat/providers/openwebui_prompt_resolution.dart';
import 'package:conduit_core/models/openwebui_chat_prompt.dart';
import 'package:conduit_core/utils/debug_logger.dart';
import 'package:conduit_protocol/conduit_protocol.dart';

import 'event_bus.dart';

/// Finds the prompt Open WebUI saved in [chatId]'s stored transcript (a
/// tool approval or `ask_user` waiting on its call), or null.
typedef StoredPromptLookup =
    Future<OpenWebUiPendingToolPrompt?> Function(String chatId);

/// Resolves a saved prompt on the server and resumes the turn it paused.
typedef StoredPromptResolver =
    Future<void> Function(
      String chatId,
      OpenWebUiPendingToolPrompt pending,
      OpenWebUiToolCallAction action,
      Map<String, dynamic>? answers,
    );

/// Open WebUI's questions and approvals, one at most per chat, as the
/// mobile app's composer overlay shows them (`OpenWebUiPromptOverlay`): the
/// card a window docks above that chat's composer.
///
/// Two sources, answered differently:
///
/// * **Live** prompts Open WebUI raised over the socket during a turn
///   (`request:user_input`, `confirmation`), which the core holds in the
///   chat's scope; [offerLive] hands over how to answer them.
/// * **Saved** prompts: a tool call the server paused on (a tool needing
///   approval, `ask_user` in a saved chat, a coding agent's request), kept in
///   the answer itself. They wait until answered, from this app or another,
///   so a chat opened later still finds one ([get] looks it up), and
///   answering it resolves the call on the server and resumes the answer
///   ([StoredPromptResolver]).
///
/// A change goes out as `chatPrompts.changed`, scoped to the chat.
final class ChatPromptsService {
  ChatPromptsService(this._events);

  final EventBus _events;

  /// Set by the turns service, which owns the chats' scopes.
  StoredPromptLookup? storedPrompt;
  StoredPromptResolver? resolveStored;

  final Map<String, _Held> _held = <String, _Held>{};

  /// Counts [clear]s: a stored chat read before one is another account's.
  int _clears = 0;

  /// The prompt [chatId] has now, if any.
  ChatPromptDto? current(String chatId) => _held[chatId]?.dto;

  /// A prompt raised over the socket in [chatId]: [onAnswer] takes an
  /// `askUser` prompt's answers in Open WebUI's shape, [onDecide] the
  /// decision on the others (or that the questions were declined).
  void offerLive(
    String chatId,
    OpenWebUiComposerPrompt prompt, {
    required void Function(Map<String, dynamic> answers) onAnswer,
    required void Function(bool approved) onDecide,
  }) {
    _hold(
      chatId,
      _Held(
        prompt: prompt,
        dto: _dto(
          chatId,
          prompt,
          expiresAt: DateTime.now().add(prompt.timeout),
        ),
        onAnswer: onAnswer,
        onDecide: onDecide,
      ),
    );
  }

  /// A prompt the server saved in [chatId]'s answer.
  void offerStored(String chatId, OpenWebUiPendingToolPrompt pending) {
    final held = _held[chatId];
    if (held != null && held.prompt.identity == pending.prompt.identity) {
      return;
    }
    _hold(
      chatId,
      _Held(
        prompt: pending.prompt,
        dto: _dto(chatId, pending.prompt),
        stored: pending,
      ),
    );
  }

  /// [chatId]'s prompt [identity] is settled (answered, timed out,
  /// cancelled by the server): its card goes.
  void withdraw(String chatId, String identity) {
    final held = _held[chatId];
    if (held == null || held.prompt.identity != identity) return;
    _held.remove(chatId);
    _publish(chatId);
  }

  /// A chat's id changed under its prompt (a new chat saved by the server).
  void remap(String fromId, String toId) {
    final held = _held.remove(fromId);
    if (held == null) return;
    _held[toId] = held.copyWith(dto: held.dto.copyWith(chatId: toId));
    _publish(fromId);
    _publish(toId);
  }

  /// Every prompt goes: the account changed.
  void clear() {
    _clears++;
    final chats = _held.keys.toList();
    _held.clear();
    for (final chatId in chats) {
      _publish(chatId);
    }
  }

  /// `chatPrompts.get`: the live prompt, else the one saved in the stored
  /// transcript (looked up again each time, as another device may have
  /// answered it).
  Future<ChatPromptState> get(ChatPromptRef ref) async {
    final chatId = ref.chatId;
    final held = _held[chatId];
    if (held != null && held.stored == null) {
      return ChatPromptState(chatId: chatId, prompt: held.dto);
    }
    if (held?.resolving ?? false) {
      return ChatPromptState(chatId: chatId, prompt: held!.dto);
    }
    final clears = _clears;
    OpenWebUiPendingToolPrompt? stored;
    try {
      stored = await storedPrompt?.call(chatId);
    } on Object catch (error, stackTrace) {
      DebugLogger.error(
        'stored-prompt-lookup-failed',
        scope: 'daemon/chat-prompts',
        error: error,
        stackTrace: stackTrace,
      );
      return ChatPromptState(chatId: chatId, prompt: held?.dto);
    }
    // The account changed while the stored chat was read: what it found is
    // the last account's, and is neither shown nor held.
    if (clears != _clears) return ChatPromptState(chatId: chatId);
    final now = _held[chatId];
    if (now != null && now.stored == null) {
      // A live prompt arrived meanwhile.
      return ChatPromptState(chatId: chatId, prompt: now.dto);
    }
    if (stored == null) {
      if (now != null) {
        _held.remove(chatId);
        _publish(chatId);
      }
      return ChatPromptState(chatId: chatId);
    }
    offerStored(chatId, stored);
    return ChatPromptState(chatId: chatId, prompt: _held[chatId]?.dto);
  }

  /// `chatPrompts.answer`: an `askUser` prompt's questions answered.
  Future<AcceptedResult> answer(ChatPromptAnswer request) async {
    final held = _held[request.chatId];
    if (held == null ||
        held.prompt.identity != request.promptId ||
        held.prompt.kind != OpenWebUiComposerPromptKind.askUser) {
      return const AcceptedResult(accepted: false);
    }
    final answers = OpenWebUiPromptAnswers(held.prompt);
    for (final item in request.answers) {
      final question = held.prompt.questions
          .where((q) => q.id == item.questionId)
          .firstOrNull;
      if (question == null) continue;
      final index = item.optionIndex;
      final text = item.text?.trim() ?? '';
      if (index != null && index >= 0 && index < question.options.length) {
        answers.selectOption(question, question.options[index], index);
      } else if (text.isNotEmpty && question.allowOther) {
        answers.updateOther(question, text);
      }
    }
    if (!answers.complete) {
      throw const RpcError(
        code: ConduitErrorCodes.invalidParams,
        debugMessage: 'every question needs an answer',
      );
    }
    final submission = answers.submission();
    if (held.stored case final pending?) {
      await _resolve(
        request.chatId,
        held,
        pending,
        OpenWebUiToolCallAction.answer,
        submission,
      );
    } else {
      _held.remove(request.chatId);
      _publish(request.chatId);
      held.onAnswer?.call(submission);
    }
    return const AcceptedResult(accepted: true);
  }

  /// `chatPrompts.decide`: an approval or confirmation answered, or the
  /// questions declined.
  Future<AcceptedResult> decide(ChatPromptDecision request) async {
    final held = _held[request.chatId];
    if (held == null || held.prompt.identity != request.promptId) {
      return const AcceptedResult(accepted: false);
    }
    if (held.stored case final pending?) {
      await _resolve(
        request.chatId,
        held,
        pending,
        openWebUiDecisionAction(held.prompt, request.approved),
        null,
      );
    } else {
      _held.remove(request.chatId);
      _publish(request.chatId);
      held.onDecide?.call(request.approved);
    }
    return const AcceptedResult(accepted: true);
  }

  Future<void> _resolve(
    String chatId,
    _Held held,
    OpenWebUiPendingToolPrompt pending,
    OpenWebUiToolCallAction action,
    Map<String, dynamic>? answers,
  ) async {
    final resolve = resolveStored;
    if (resolve == null) {
      throw const RpcError(
        code: ConduitErrorCodes.daemonUnavailable,
        debugMessage: 'the core is not up yet',
      );
    }
    if (held.resolving) {
      throw const RpcError(
        code: ConduitErrorCodes.conflict,
        debugMessage: 'that prompt is already being answered',
      );
    }
    held.resolving = true;
    try {
      await resolve(chatId, pending, action, answers);
    } on Object {
      held.resolving = false;
      rethrow;
    }
    // The server has it; the resumed answer takes the card's place.
    if (identical(_held[chatId], held)) {
      _held.remove(chatId);
      _publish(chatId);
    }
  }

  void _hold(String chatId, _Held held) {
    _held[chatId] = held;
    _publish(chatId);
  }

  void _publish(String chatId) => _events.emit(
    ConduitEventSpecs.chatPromptsChanged,
    ChatPromptState(chatId: chatId, prompt: _held[chatId]?.dto),
    scope: chatId,
  );

  static ChatPromptDto _dto(
    String chatId,
    OpenWebUiComposerPrompt prompt, {
    DateTime? expiresAt,
  }) => ChatPromptDto(
    id: prompt.identity,
    chatId: chatId,
    kind: switch (prompt.kind) {
      OpenWebUiComposerPromptKind.askUser => ChatPromptKind.askUser,
      OpenWebUiComposerPromptKind.toolApproval => ChatPromptKind.toolApproval,
      OpenWebUiComposerPromptKind.confirmation => ChatPromptKind.confirmation,
    },
    title: prompt.title,
    message: prompt.message,
    questions: <ChatPromptQuestionDto>[
      for (final question in prompt.questions)
        ChatPromptQuestionDto(
          id: question.id,
          header: question.header,
          question: question.question,
          options: <ChatPromptOptionDto>[
            for (final option in question.options)
              ChatPromptOptionDto(
                label: option.label,
                description: option.description,
              ),
          ],
          allowOther: question.allowOther,
        ),
    ],
    expiresAtMs: expiresAt?.millisecondsSinceEpoch,
  );
}

final class _Held {
  _Held({
    required this.prompt,
    required this.dto,
    this.stored,
    this.onAnswer,
    this.onDecide,
  });

  final OpenWebUiComposerPrompt prompt;
  final ChatPromptDto dto;

  /// Set for a prompt saved in the answer.
  final OpenWebUiPendingToolPrompt? stored;
  final void Function(Map<String, dynamic> answers)? onAnswer;
  final void Function(bool approved)? onDecide;

  /// Its answer is on its way to the server.
  bool resolving = false;

  _Held copyWith({required ChatPromptDto dto}) => _Held(
    prompt: prompt,
    dto: dto,
    stored: stored,
    onAnswer: onAnswer,
    onDecide: onDecide,
  )..resolving = resolving;
}
