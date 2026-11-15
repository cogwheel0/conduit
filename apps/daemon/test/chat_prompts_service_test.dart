@TestOn('vm')
library;

import 'dart:async';

import 'package:conduit_core/models/openwebui_chat_prompt.dart';
import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:conduitd/conduitd.dart';
import 'package:conduitd/src/chat_prompts_service.dart';
import 'package:conduitd/src/queued_completions_service.dart';
import 'package:conduit_core/features/chat/providers/queued_completion_provider.dart';
import 'package:test/test.dart';

/// Open WebUI's questions and approvals, one per chat, docked above that
/// chat's composer: how each kind is offered, answered and taken away.
void main() {
  late EventBus events;
  late List<EventEnvelope> seen;
  late ChatPromptsService prompts;

  const chatId = 'chat-harbour';

  const askUser = OpenWebUiComposerPrompt(
    identity: 'live:1',
    kind: OpenWebUiComposerPromptKind.askUser,
    questions: <OpenWebUiPromptQuestion>[
      OpenWebUiPromptQuestion(
        id: 'when',
        header: 'Departure',
        question: 'When should the boat leave?',
        options: <OpenWebUiPromptOption>[
          OpenWebUiPromptOption(label: 'Morning', description: 'Calm water'),
          OpenWebUiPromptOption(label: 'Evening', description: 'After work'),
        ],
        allowOther: true,
      ),
      OpenWebUiPromptQuestion(
        id: 'crew',
        header: 'Crew',
        question: 'Who sails?',
        options: <OpenWebUiPromptOption>[
          OpenWebUiPromptOption(label: 'Two', description: 'A small crew'),
          OpenWebUiPromptOption(label: 'Four', description: 'A full crew'),
        ],
        allowOther: false,
      ),
    ],
  );

  setUp(() {
    events = EventBus();
    seen = <EventEnvelope>[];
    events.attach('w1', seen.add);
    events.subscribe('w1', const EventSubscription(scopes: <String>[chatId]));
    prompts = ChatPromptsService(events);
  });

  List<ChatPromptState> changes() => <ChatPromptState>[
    for (final e in seen)
      if (e.event == ConduitEvents.chatPromptsChanged)
        ChatPromptState.fromJson(e.payload),
  ];

  test('a live question is offered to the chat, then answered', () async {
    Map<String, dynamic>? answered;
    prompts.offerLive(
      chatId,
      askUser,
      onAnswer: (answers) => answered = answers,
      onDecide: (_) => fail('not declined'),
    );
    final offered = changes().single.prompt!;
    expect(offered.kind, ChatPromptKind.askUser);
    expect(offered.questions.map((q) => q.id), ['when', 'crew']);
    expect(offered.questions.last.allowOther, isFalse);
    expect(offered.expiresAtMs, isNotNull);
    expect(
      (await prompts.get(const ChatPromptRef(chatId: chatId))).prompt,
      offered,
    );

    final accepted = await prompts.answer(
      const ChatPromptAnswer(
        chatId: chatId,
        promptId: 'live:1',
        answers: <ChatPromptAnswerItem>[
          ChatPromptAnswerItem(questionId: 'when', text: ' At noon '),
          ChatPromptAnswerItem(questionId: 'crew', optionIndex: 1),
        ],
      ),
    );
    expect(accepted.accepted, isTrue);
    expect(answered, {
      'when': {'type': 'other', 'text': 'At noon'},
      'crew': {
        'type': 'option',
        'option_index': 1,
        'label': 'Four',
        'description': 'A full crew',
      },
    });
    expect(changes().last.prompt, isNull);
  });

  test('every question needs an answer, in a form it accepts', () async {
    prompts.offerLive(
      chatId,
      askUser,
      onAnswer: (_) => fail('incomplete'),
      onDecide: (_) {},
    );
    // The crew question takes no words of the user's own.
    expect(
      () => prompts.answer(
        const ChatPromptAnswer(
          chatId: chatId,
          promptId: 'live:1',
          answers: <ChatPromptAnswerItem>[
            ChatPromptAnswerItem(questionId: 'when', optionIndex: 0),
            ChatPromptAnswerItem(questionId: 'crew', text: 'Six'),
          ],
        ),
      ),
      throwsA(isA<RpcError>()),
    );
  });

  test('an answer to a prompt that has gone does not count', () async {
    prompts.offerLive(
      chatId,
      askUser,
      onAnswer: (_) => fail('stale'),
      onDecide: (_) => fail('stale'),
    );
    prompts.withdraw(chatId, 'live:1');
    expect(changes().last.prompt, isNull);
    final late = await prompts.decide(
      const ChatPromptDecision(
        chatId: chatId,
        promptId: 'live:1',
        approved: false,
      ),
    );
    expect(late.accepted, isFalse);
  });

  test('a saved approval is found in the stored chat and resumes it', () async {
    const pending = OpenWebUiPendingToolPrompt(
      messageId: 'msg-a',
      callId: 'call_1',
      toolName: 'tide_table',
      prompt: OpenWebUiComposerPrompt(
        identity: 'saved:msg-a:call_1',
        kind: OpenWebUiComposerPromptKind.toolApproval,
        title: 'tide_table',
        message: '{}',
      ),
    );
    var stored = true;
    final resolved = <OpenWebUiToolCallAction>[];
    prompts.storedPrompt = (id) async =>
        stored && id == chatId ? pending : null;
    prompts.resolveStored = (id, p, action, answers) async {
      resolved.add(action);
      stored = false;
    };

    final state = await prompts.get(const ChatPromptRef(chatId: chatId));
    expect(state.prompt!.kind, ChatPromptKind.toolApproval);
    expect(state.prompt!.title, 'tide_table');
    expect(state.prompt!.expiresAtMs, isNull);

    final accepted = await prompts.decide(
      const ChatPromptDecision(
        chatId: chatId,
        promptId: 'saved:msg-a:call_1',
        approved: true,
      ),
    );
    expect(accepted.accepted, isTrue);
    expect(resolved, [OpenWebUiToolCallAction.approve]);
    expect(changes().last.prompt, isNull);
    // Answered: the stored chat no longer has it.
    expect(
      (await prompts.get(const ChatPromptRef(chatId: chatId))).prompt,
      isNull,
    );
  });

  test(
    'a saved prompt answered elsewhere goes when the chat is read',
    () async {
      const pending = OpenWebUiPendingToolPrompt(
        messageId: 'msg-a',
        callId: 'call_2',
        toolName: 'ask_user',
        prompt: askUser,
      );
      var stored = true;
      prompts.storedPrompt = (_) async => stored ? pending : null;
      prompts.offerStored(chatId, pending);
      expect(changes().last.prompt, isNotNull);
      stored = false;
      expect(
        (await prompts.get(const ChatPromptRef(chatId: chatId))).prompt,
        isNull,
      );
      expect(changes().last.prompt, isNull);
    },
  );

  test('a saved prompt found after the account changed is dropped', () async {
    const pending = OpenWebUiPendingToolPrompt(
      messageId: 'msg-a',
      callId: 'call_3',
      toolName: 'tide_table',
      prompt: OpenWebUiComposerPrompt(
        identity: 'saved:msg-a:call_3',
        kind: OpenWebUiComposerPromptKind.toolApproval,
        title: 'tide_table',
        message: '{}',
      ),
    );
    final found = Completer<OpenWebUiPendingToolPrompt?>();
    prompts.storedPrompt = (_) => found.future;
    final reading = prompts.get(const ChatPromptRef(chatId: chatId));
    // The account changes while the stored chat is read.
    prompts.clear();
    found.complete(pending);
    expect((await reading).prompt, isNull);
    expect(prompts.current(chatId), isNull);
  });

  test('a chat that changes id keeps its prompt', () {
    prompts.offerLive('local:1', askUser, onAnswer: (_) {}, onDecide: (_) {});
    prompts.remap('local:1', chatId);
    expect(prompts.current(chatId)?.chatId, chatId);
    expect(prompts.current('local:1'), isNull);
  });

  test('a queued answer says what it waits for', () {
    expect(
      queuedCompletionDto(
        const QueuedCompletionDisplay(
          assistantMessageId: 'a',
          phase: QueuedCompletionPhase.pending,
          isOffline: true,
          lastError: 'offline',
        ),
      ),
      const QueuedCompletionDto(offline: true),
    );
    expect(
      queuedCompletionDto(
        const QueuedCompletionDisplay(
          assistantMessageId: 'a',
          phase: QueuedCompletionPhase.failed,
          isOffline: false,
          lastError: 'Unsupported parameter: reasoning_effort',
          frozenReasoningEffort: 'high',
        ),
      ),
      const QueuedCompletionDto(
        failed: true,
        error: 'Unsupported parameter: reasoning_effort',
        reasoningEffortRejected: true,
      ),
    );
  });
}
