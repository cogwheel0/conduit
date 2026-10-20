import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/message_rating.dart';
import 'package:mocktail/mocktail.dart';
import 'package:test/test.dart';

class _Api extends Mock implements ApiService {}

/// A chat in Open WebUI's shape: one question with two answers.
Map<String, dynamic> _chat({Map<String, dynamic>? answerExtra}) => {
  'id': 'c1',
  'title': 'T',
  'chat': {
    'history': {
      'currentId': 'a2',
      'messages': {
        'q': {
          'id': 'q',
          'role': 'user',
          'parentId': null,
          'childrenIds': ['a1', 'a2'],
        },
        'a1': {'id': 'a1', 'role': 'assistant', 'parentId': 'q', 'model': 'm1'},
        'a2': {
          'id': 'a2',
          'role': 'assistant',
          'parentId': 'q',
          'model': 'm2',
          ...?answerExtra,
        },
      },
    },
    'messages': [
      {'id': 'q', 'role': 'user'},
      {'id': 'a2', 'role': 'assistant'},
    ],
  },
};

void main() {
  late _Api api;
  late Map<String, dynamic> savedChat;

  setUp(() {
    api = _Api();
    when(() => api.updateChatRaw(any(), any())).thenAnswer((call) async {
      savedChat = call.positionalArguments[1] as Map<String, dynamic>;
      return <String, dynamic>{};
    });
  });

  test('files an evaluation and records it on the message', () async {
    when(() => api.getChatRaw('c1')).thenAnswer((_) async => _chat());
    Map<String, dynamic>? filed;
    when(() => api.createFeedback(any())).thenAnswer((call) async {
      filed = call.positionalArguments.single as Map<String, dynamic>;
      return <String, dynamic>{'id': 'fb1'};
    });

    await MessageRating(api).rate(chatId: 'c1', messageId: 'a2', rating: 1);

    expect(filed!['type'], 'rating');
    final data = filed!['data'] as Map<String, dynamic>;
    expect(data['rating'], 1);
    expect(data['model_id'], 'm2');
    expect(data['sibling_model_ids'], ['m1']);
    final meta = filed!['meta'] as Map<String, dynamic>;
    expect(meta['message_index'], 2);
    expect(meta['chat_id'], 'c1');

    final message =
        ((savedChat['history'] as Map)['messages'] as Map)['a2'] as Map;
    expect((message['annotation'] as Map)['rating'], 1);
    expect(message['feedbackId'], 'fb1');
    // The flat list too.
    final flat = (savedChat['messages'] as List).last as Map;
    expect(flat['feedbackId'], 'fb1');
  });

  test('a second rating updates the same evaluation', () async {
    when(() => api.getChatRaw('c1')).thenAnswer(
      (_) async => _chat(
        answerExtra: {
          'feedbackId': 'fb1',
          'annotation': {'rating': 1, 'reason': 'accurate'},
        },
      ),
    );
    when(() => api.updateFeedback('fb1', any()))
        .thenAnswer((_) async => <String, dynamic>{'id': 'fb1'});

    await MessageRating(api).rate(chatId: 'c1', messageId: 'a2', rating: -1);

    verifyNever(() => api.createFeedback(any()));
    final message =
        ((savedChat['history'] as Map)['messages'] as Map)['a2'] as Map;
    final annotation = message['annotation'] as Map;
    expect(annotation['rating'], -1);
    // A changed verdict drops the reason given for the old one.
    expect(annotation['reason'], isNull);
  });

  test('a vanished evaluation is filed again', () async {
    when(() => api.getChatRaw('c1'))
        .thenAnswer((_) async => _chat(answerExtra: {'feedbackId': 'gone'}));
    when(() => api.updateFeedback('gone', any())).thenAnswer((_) async => null);
    when(() => api.createFeedback(any()))
        .thenAnswer((_) async => <String, dynamic>{'id': 'fb2'});

    await MessageRating(api).rate(chatId: 'c1', messageId: 'a2', rating: 1);

    final message =
        ((savedChat['history'] as Map)['messages'] as Map)['a2'] as Map;
    expect(message['feedbackId'], 'fb2');
  });

  test('the thumb is kept even when the evaluation is refused', () async {
    when(() => api.getChatRaw('c1')).thenAnswer((_) async => _chat());
    when(() => api.createFeedback(any())).thenThrow(StateError('refused'));

    await expectLater(
      MessageRating(api).rate(chatId: 'c1', messageId: 'a2', rating: 1),
      throwsStateError,
    );
    final message =
        ((savedChat['history'] as Map)['messages'] as Map)['a2'] as Map;
    expect((message['annotation'] as Map)['rating'], 1);
  });

  test('only up or down', () {
    expect(
      MessageRating(api).rate(chatId: 'c1', messageId: 'a2', rating: 5),
      throwsArgumentError,
    );
  });
}
