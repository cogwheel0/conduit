import 'package:checks/checks.dart';
import 'package:conduit/features/chat/providers/openwebui_chat_prompt_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

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
