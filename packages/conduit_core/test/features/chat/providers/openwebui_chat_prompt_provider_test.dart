import 'package:checks/checks.dart';
import 'package:conduit_core/features/chat/providers/openwebui_chat_prompt_provider.dart';
import 'package:conduit_core/models/openwebui_chat_prompt.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

void main() {
  tearDown(() => debugOpenWebUiPromptTimeoutOverride = null);

  test('live ask-user acknowledges one exact answer', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final responses = <dynamic>[];
    final notifier = container.read(openWebUiLivePromptProvider.notifier);
    notifier.handleSocketRequest(
      conversationId: 'chat-1',
      type: 'request:user_input',
      data: _questionData(),
      acknowledge: responses.add,
    );
    final prompt = container.read(openWebUiLivePromptProvider)!.prompt;

    notifier.answer(prompt.identity, const {
      'scope': {
        'type': 'option',
        'option_index': 0,
        'label': 'This chat',
        'description': 'Use this chat only',
      },
    });
    notifier.answer(prompt.identity, const {});

    check(responses).deepEquals([
      {
        'status': 'answered',
        'answers': {
          'scope': {
            'type': 'option',
            'option_index': 0,
            'label': 'This chat',
            'description': 'Use this chat only',
          },
        },
      },
    ]);
  });

  test('replacement and ownership changes cancel each request once', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final first = <dynamic>[];
    final second = <dynamic>[];
    final notifier = container.read(openWebUiLivePromptProvider.notifier);
    notifier.handleSocketRequest(
      conversationId: 'chat-1',
      type: 'request:user_input',
      data: _questionData(),
      acknowledge: first.add,
    );
    notifier.handleSocketRequest(
      conversationId: 'chat-2',
      type: 'request:user_input',
      data: _questionData(),
      acknowledge: second.add,
    );
    notifier.cancelForConversation('chat-1');
    notifier.cancelForConversation('chat-2');

    check(first).deepEquals([
      {'status': 'cancelled', 'answers': {}},
    ]);
    check(second).deepEquals([
      {'status': 'cancelled', 'answers': {}},
    ]);
  });

  test(
    'invalid requests fail immediately and timeout cancels valid input',
    () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final invalid = <dynamic>[];
      final timedOut = <dynamic>[];
      final notifier = container.read(openWebUiLivePromptProvider.notifier);
      notifier.handleSocketRequest(
        conversationId: 'chat-1',
        type: 'request:user_input',
        data: const {'questions': []},
        acknowledge: invalid.add,
      );
      check(invalid).deepEquals([
        {'error': 'Invalid user input request.'},
      ]);

      debugOpenWebUiPromptTimeoutOverride = const Duration(milliseconds: 5);
      notifier.handleSocketRequest(
        conversationId: 'chat-1',
        type: 'request:user_input',
        data: _questionData(),
        acknowledge: timedOut.add,
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
      check(timedOut).deepEquals([
        {'status': 'cancelled', 'answers': {}},
      ]);
    },
  );

  test('legacy confirmation acknowledges a boolean', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final responses = <dynamic>[];
    final notifier = container.read(openWebUiLivePromptProvider.notifier);
    notifier.handleSocketRequest(
      conversationId: 'chat-1',
      type: 'confirmation',
      data: const {'title': 'Continue?', 'message': 'Run the tool?'},
      acknowledge: responses.add,
    );
    final prompt = container.read(openWebUiLivePromptProvider)!.prompt;
    notifier.decide(prompt.identity, true);
    check(responses).deepEquals([true]);
  });

  test('a tool call awaiting approval shows the tool and its arguments', () {
    // Open WebUI 0.12 asks to approve a tool call in a chat that is not
    // saved with only the call itself, no title or message.
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final responses = <dynamic>[];
    final notifier = container.read(openWebUiLivePromptProvider.notifier);
    notifier.handleSocketRequest(
      conversationId: 'local:chat-1',
      type: 'confirmation',
      data: const {
        'tool_call': {
          'id': 'call-1',
          'name': 'web_search',
          'arguments': {'query': 'weather'},
        },
        'interaction_id': 'interaction-1',
      },
      acknowledge: responses.add,
    );

    final prompt = container.read(openWebUiLivePromptProvider)!.prompt;
    check(prompt.kind).equals(OpenWebUiComposerPromptKind.confirmation);
    check(prompt.title).equals('web_search');
    check(prompt.message).equals('{\n  "query": "weather"\n}');
    notifier.decide(prompt.identity, true);
    check(responses).deepEquals([true]);
  });

  test('legacy confirmation bounds text and times out to false', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final responses = <dynamic>[];
    final notifier = container.read(openWebUiLivePromptProvider.notifier);
    debugOpenWebUiPromptTimeoutOverride = const Duration(milliseconds: 5);
    notifier.handleSocketRequest(
      conversationId: 'chat-1',
      type: 'confirmation',
      data: {
        'title': '${List.filled(119, 'T').join()}😀',
        'message': 'Run the tool?',
      },
      acknowledge: responses.add,
    );

    final prompt = container.read(openWebUiLivePromptProvider)!.prompt;
    check(prompt.title).equals(List.filled(119, 'T').join());
    await Future<void>.delayed(const Duration(milliseconds: 20));
    check(responses).deepEquals([false]);
  });
}

Map<String, dynamic> _questionData() => {
  'questions': [
    {
      'id': 'scope',
      'header': 'Scope',
      'question': 'Which scope?',
      'options': [
        {'label': 'This chat', 'description': 'Use this chat only'},
        {'label': 'All chats', 'description': 'Use every chat'},
      ],
    },
  ],
  'timeout_ms': 60000,
};
