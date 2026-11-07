import 'package:checks/checks.dart';
import 'package:conduit_core/features/chat/services/chat_title_generation.dart';
import 'package:test/test.dart';

Map<String, dynamic> _chat(Map<String, dynamic> content) => {
  'id': 'chat-1',
  'chat': content,
};

void main() {
  group('chatTitleRequest', () {
    final history = <String, dynamic>{
      'currentId': 'a2',
      'messages': {
        'u1': {
          'id': 'u1',
          'parentId': null,
          'role': 'user',
          'content': 'What is a quine?',
        },
        'a1': {
          'id': 'a1',
          'parentId': 'u1',
          'role': 'assistant',
          'model': 'old-model',
          'content': 'An older answer on another branch',
        },
        'a2': {
          'id': 'a2',
          'parentId': 'u1',
          'role': 'assistant',
          'model': 'branch-model',
          'content': '<details type="reasoning">thinking</details>A program',
          'output': [
            {'type': 'reasoning', 'summary': []},
            {
              'type': 'message',
              'content': [
                {'type': 'output_text', 'text': 'A program that prints itself.'},
              ],
            },
          ],
        },
      },
    };

    test('asks with the current branch, as output text', () {
      final request = chatTitleRequest(
        _chat({
          'history': history,
          'models': ['chat-model'],
        }),
      );

      check(request).isNotNull();
      check(request!.messages).deepEquals([
        {'role': 'user', 'content': 'What is a quine?'},
        {'role': 'assistant', 'content': 'A program that prints itself.'},
      ]);
      // The newest answer's model on the branch, not the chat's first.
      check(request.model).equals('branch-model');
    });

    test("a model that is not the server's is passed over", () {
      // The newest answer came from a Hermes or Direct model.
      final request = chatTitleRequest(
        _chat({
          'history': history,
          'models': ['chat-model'],
        }),
        selectedModelId: 'direct-model',
        isServerModel: (id) => id == 'chat-model',
      );

      check(request!.model).equals('chat-model');
      check(
        chatTitleRequest(
          _chat({'history': history}),
          isServerModel: (_) => false,
        ),
      ).isNull();
    });

    test('the model picked in the open chat comes first', () {
      final request = chatTitleRequest(
        _chat({'history': history}),
        selectedModelId: 'picked-model',
      );

      check(request!.model).equals('picked-model');
    });

    test("falls back to the chat's models and its flat message list", () {
      final request = chatTitleRequest(
        _chat({
          'models': ['', 'chat-model'],
          'messages': [
            {'role': 'user', 'content': 'Hello'},
            {'role': 'assistant', 'content': 'Hi there'},
          ],
        }),
      );

      check(request!.model).equals('chat-model');
      check(request.messages).length.equals(2);
    });

    test('is null for a chat with no messages or no model', () {
      check(chatTitleRequest(_chat({'models': ['m']}))).isNull();
      check(
        chatTitleRequest(
          _chat({
            'messages': [
              {'role': 'user', 'content': 'Hello'},
            ],
          }),
        ),
      ).isNull();
      check(chatTitleRequest(const {'id': 'chat-1'})).isNull();
    });

    test('a history whose current message is missing reads the flat list', () {
      final request = chatTitleRequest(
        _chat({
          'history': {'currentId': 'gone', 'messages': <String, dynamic>{}},
          'messages': [
            {'role': 'user', 'content': 'Hello'},
          ],
          'models': ['m'],
        }),
      );

      check(request!.messages).deepEquals([
        {'role': 'user', 'content': 'Hello'},
      ]);
    });

    test('a turn saved as parts is read from its text parts', () {
      final request = chatTitleRequest(
        _chat({
          'messages': [
            {
              'role': 'user',
              'content': [
                {'type': 'text', 'text': 'What is in '},
                {
                  'type': 'image_url',
                  'image_url': {'url': 'data:image/png;base64,AA=='},
                },
                {'type': 'text', 'text': 'this photo?'},
              ],
            },
          ],
          'models': ['m'],
        }),
      );

      check(request!.messages).deepEquals([
        {'role': 'user', 'content': 'What is in this photo?'},
      ]);
    });

    test('a cycle in the history does not loop', () {
      final request = chatTitleRequest(
        _chat({
          'history': {
            'currentId': 'x',
            'messages': {
              'x': {'role': 'user', 'content': 'x', 'parentId': 'y'},
              'y': {'role': 'user', 'content': 'y', 'parentId': 'x'},
            },
          },
          'models': ['m'],
        }),
      );

      check(request!.messages).length.equals(2);
    });
  });
}
