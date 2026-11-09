import 'package:checks/checks.dart';
import 'package:conduit_core/database/mappers/chat_blob_mapper.dart';
import 'package:conduit_core/features/librechat/models/librechat_message.dart';
import 'package:conduit_core/features/librechat/services/librechat_message_mapper.dart';
import 'package:conduit_core/services/conversation_parsing.dart';
import 'package:conduit_core/services/structured_output.dart';
import 'package:test/test.dart';

LibreChatMessage _message(Map<String, dynamic> raw) =>
    LibreChatMessage.fromJson(raw)!;

/// A conversation with a regenerated reply: the user asked, the first reply
/// was regenerated, and the user followed up on the newer one.
final conversation = LibreChatConversation.fromJson({
  'conversationId': 'c1',
  'title': 'Paris weather',
  'endpoint': 'agents',
  'agent_id': 'agent_weather',
  'model': 'llama3.2',
  'pinned': true,
  'createdAt': '2026-10-18T10:00:00.000Z',
  'updatedAt': '2026-10-18T10:05:00.000Z',
})!;

final messages = [
  _message({
    'messageId': 'u1',
    'parentMessageId': kLibreChatRootParentId,
    'conversationId': 'c1',
    'isCreatedByUser': true,
    'text': 'Weather in Paris?',
    'createdAt': '2026-10-18T10:00:00.000Z',
    'files': [
      {
        'file_id': 'f1',
        'filename': 'map.png',
        'filepath': '/images/user1/map.png',
        'type': 'image/png',
        'width': 640,
        'height': 480,
      },
    ],
  }),
  _message({
    'messageId': 'a1',
    'parentMessageId': 'u1',
    'conversationId': 'c1',
    'isCreatedByUser': false,
    'sender': 'Weather',
    'model': 'llama3.2',
    'text': 'Rain.',
    'content': [
      {'type': 'text', 'text': 'Rain.'},
    ],
    'createdAt': '2026-10-18T10:00:05.000Z',
  }),
  _message({
    'messageId': 'a2',
    'parentMessageId': 'u1',
    'conversationId': 'c1',
    'isCreatedByUser': false,
    'sender': 'Weather',
    'model': 'llama3.2',
    'text': 'It is sunny in Paris.',
    'content': [
      {'type': 'think', 'think': 'Check the tool.'},
      {
        'type': 'tool_call',
        'tool_call': {
          'id': 'call_1',
          'name': 'get_weather_mcp_weather',
          'args': '{"city":"Paris"}',
          'output': 'Sunny, 21C',
          'progress': 1,
        },
      },
      {'type': 'text', 'text': 'It is sunny in Paristurn0search0.'},
    ],
    'attachments': [
      {
        'type': 'web_search',
        'messageId': 'a2',
        'toolCallId': 'call_0',
        'web_search': {
          'turn': 0,
          'organic': [
            {
              'title': 'Paris forecast',
              'link': 'https://weather.example/paris',
              'snippet': 'Sunny all day',
            },
          ],
        },
      },
    ],
    'createdAt': '2026-10-18T10:01:00.000Z',
  }),
  _message({
    'messageId': 'u2',
    'parentMessageId': 'a2',
    'conversationId': 'c1',
    'isCreatedByUser': true,
    'text': 'And tomorrow?',
    'createdAt': '2026-10-18T10:02:00.000Z',
  }),
  _message({
    'messageId': 'a3',
    'parentMessageId': 'u2',
    'conversationId': 'c1',
    'isCreatedByUser': false,
    'text': 'Something went wrong.',
    'error': true,
    'createdAt': '2026-10-18T10:02:05.000Z',
  }),
];

void main() {
  test('the newest branch is current', () {
    check(LibreChatMessageMapper.currentLeaf(messages)).equals('a3');
    check(
      LibreChatMessageMapper.currentLeaf(messages.take(3).toList()),
    ).equals('a2');
  });

  test('siblings with the same time: the later one in the list is current',
      () {
    LibreChatMessage at(String id, String? parent) => _message({
      'messageId': id,
      'parentMessageId': parent ?? '00000000-0000-0000-0000-000000000000',
      'conversationId': 'c1',
      'isCreatedByUser': parent == null,
      'text': id,
      'createdAt': '2026-10-18T10:00:00.000Z',
    });
    check(
      LibreChatMessageMapper.currentLeaf([
        at('u1', null),
        at('a-old', 'u1'),
        at('a-new', 'u1'),
      ]),
    ).equals('a-new');
  });

  test('rows hold plain text for search and the full record', () {
    final rows = LibreChatMessageMapper.chatRows(conversation, messages);
    check(rows.chat.id).equals('c1');
    check(rows.chat.pinned).isTrue();
    check(rows.chat.currentMessageId).equals('a3');
    final a2 = rows.messages.singleWhere((row) => row.id == 'a2');
    // Reasoning and tool JSON stay out of the searchable text.
    check(a2.content).equals('It is sunny in Paris [1].');
    check(a2.parentId).equals('u1');
    check(a2.payload['libreChat']).isA<Map<String, dynamic>>();
    final u1 = rows.messages.singleWhere((row) => row.id == 'u1');
    check(u1.parentId).isNull();
    check(
      (rows.messages.singleWhere((row) => row.id == 'u1').payload['childrenIds']
          as List),
    ).deepEquals(['a1', 'a2']);
    // The rows rebuild the same blob, as every stored chat must.
    check(
      ChatBlobMapper.rowsToBlob(rows),
    ).deepEquals(LibreChatMessageMapper.chatBlob(conversation, messages));
  });

  test('parses into the conversation Conduit shows', () {
    final rows = LibreChatMessageMapper.chatRows(conversation, messages);
    final parsed = parseFullConversationModel({
      'id': 'c1',
      'title': 'Paris weather',
      'chat': ChatBlobMapper.rowsToBlob(rows),
      'created_at': rows.chat.createdAt,
      'updated_at': rows.chat.updatedAt,
      'pinned': true,
      'archived': false,
    });
    check(
      parsed.messages.map((message) => message.id),
    ).deepEquals(['u1', 'a2', 'u2', 'a3']);

    final user = parsed.messages.first;
    check(user.role).equals('user');
    check(user.files!.single['type']).equals('image');
    check(user.files!.single['url']).equals('/images/user1/map.png');

    final reply = parsed.messages[1];
    check(reply.content)
      ..contains('type="reasoning"')
      ..contains('Check the tool.')
      ..contains('type="tool_calls"')
      ..contains('get_weather_mcp_weather')
      ..contains('It is sunny in Paris [1].');
    check(reply.sources.single.url).equals('https://weather.example/paris');
    check(reply.sources.single.title).equals('Paris forecast');
    // The regenerated-over reply is a version of the shown one.
    check(reply.versions.map((version) => version.content)).contains('Rain.');

    final failed = parsed.messages.last;
    check(failed.error).isNotNull();
  });

  test('a provider\'s error shows as its message, not its JSON', () {
    const lead = 'The model provider could not complete this request.';
    const raw =
        '$lead\n{"type":"upstream_model_error","status":400,'
        '"message":"400 Multimodal data provided, but model does not '
        'support multimodal requests."}';
    const readable =
        '$lead\n400 Multimodal data provided, but model does not support '
        'multimodal requests.';
    check(libreChatReadableError(raw)).equals(readable);
    // Anything else is left as it is.
    check(libreChatReadableError('Something went wrong.'))
        .equals('Something went wrong.');
    check(libreChatReadableError('Bad {json')).equals('Bad {json');

    final rows = LibreChatMessageMapper.chatRows(conversation, [
      _message({
        'messageId': 'a1',
        'parentMessageId': '00000000-0000-0000-0000-000000000000',
        'conversationId': 'c1',
        'isCreatedByUser': false,
        'text': '',
        'content': [
          {'type': 'error', 'error': raw},
        ],
        'createdAt': '2026-10-18T10:00:05.000Z',
      }),
    ]);
    final parsed = parseFullConversationModel({
      'id': 'c1',
      'title': 'Paris weather',
      'chat': ChatBlobMapper.rowsToBlob(rows),
      'created_at': rows.chat.createdAt,
      'updated_at': rows.chat.updatedAt,
    });
    check(parsed.messages.single.error?.content).equals(readable);
  });

  test('a running reply keeps its last step open', () {
    final items = LibreChatMessageMapper.outputItems([
      {'type': 'think', 'think': 'Thinking'},
    ], inProgress: true);
    check(items.single['status']).equals('in_progress');

    final tool = LibreChatMessageMapper.outputItems([
      {
        'type': 'tool_call',
        'tool_call': {
          'id': 'c',
          'name': 'echo',
          'args': {'message': 'hi'},
          'approval': {'actionId': 'a', 'allowed_decisions': ['approve']},
        },
      },
    ]);
    check(tool.single)
      ..has((it) => it['status'], 'status').equals('pending')
      ..has((it) => it['arguments'], 'arguments').equals('{"message":"hi"}');
  });

  test('calls a finished reply never answered stop spinning', () {
    final parts = [
      {
        'type': 'tool_call',
        'tool_call': {'id': 'c', 'name': 'echo', 'args': '{}'},
      },
      {
        'type': 'tool_call',
        'tool_call': {
          'id': 'code1',
          'name': 'execute_code',
          'args': '{"code":"print(1)"}',
        },
      },
      {
        'type': 'tool_call',
        'tool_call': {
          'type': 'code_interpreter',
          'id': 'ci',
          'code_interpreter': {'input': 'print(2)', 'outputs': <Object>[]},
        },
      },
    ];
    final live = LibreChatMessageMapper.outputItems(parts, inProgress: true);
    check(
      live.map((it) => it['status']),
    ).deepEquals(['in_progress', 'in_progress', 'in_progress']);

    final ended = LibreChatMessageMapper.outputItems(parts);
    check(
      ended.map((it) => it['status']),
    ).deepEquals(['incomplete', 'incomplete', 'incomplete']);
    final blocks = parseOpenWebUIStructuredOutput(ended);
    check(
      blocks.whereType<StructuredOutputToolCallBlock>().single.done,
    ).isTrue();
    check(
      blocks
          .whereType<StructuredOutputCodeInterpreterBlock>()
          .map((block) => block.done),
    ).deepEquals([true, true]);
  });

  test('code runs render as code', () {
    final items = LibreChatMessageMapper.outputItems([
      {
        'type': 'tool_call',
        'tool_call': {
          'id': 'code1',
          'name': 'execute_code',
          'args': '{"lang":"py","code":"print(1)"}',
          'output': 'stdout:\n1',
        },
      },
    ]);
    check(items.single)
      ..has((it) => it['type'], 'type').equals('code_interpreter')
      ..has((it) => it['code'], 'code').equals('print(1)')
      ..has((it) => it['lang'], 'lang').equals('py')
      ..has((it) => it['status'], 'status').equals('completed');
  });

  test('two calls that share an id keep their own results', () {
    final items = LibreChatMessageMapper.outputItems([
      for (final (agent, output) in [('a', 'sunny'), ('b', 'rainy')])
        {
          'type': 'tool_call',
          'tool_call': {
            'id': 'call_0',
            'name': 'weather_$agent',
            'args': '',
            'output': output,
          },
        },
    ]);
    final calls = items.where((it) => it['type'] == 'function_call').toList();
    final outputs = items
        .where((it) => it['type'] == 'function_call_output')
        .toList();
    check(calls.map((it) => it['call_id']).toSet()).length.equals(2);
    for (var i = 0; i < 2; i++) {
      check(outputs[i]['call_id']).equals(calls[i]['call_id']);
    }
    check(outputs.map((it) => it['output'])).deepEquals(['sunny', 'rainy']);
    // The first keeps the provider's id; a call without arguments sends {}.
    check(calls.first['call_id']).equals('call_0');
    check(calls.map((it) => it['arguments'])).deepEquals(['{}', '{}']);
  });

  test('a call with null arguments sends {}', () {
    final items = LibreChatMessageMapper.outputItems([
      {
        'type': 'tool_call',
        'tool_call': {'id': 'c', 'name': 'now', 'args': null},
      },
    ]);
    check(items.single['arguments']).equals('{}');
  });

  test('Assistants history: nested calls, prompts and uploads', () {
    final reply = _message({
      'messageId': 'a1',
      'parentMessageId': 'u1',
      'conversationId': 'c1',
      'isCreatedByUser': false,
      'content': [
        {
          'type': 'tool_call',
          'tool_call': {
            'id': 'call_f',
            'type': 'function',
            'function': {
              'name': 'lookup',
              'arguments': '{"q":"x"}',
              'output': 'found',
            },
            'progress': 1,
          },
        },
        {
          'type': 'tool_call',
          'tool_call': {
            'id': 'call_c',
            'type': 'code_interpreter',
            'code_interpreter': {
              'input': 'print(2)',
              'outputs': [
                {'type': 'logs', 'logs': '2'},
              ],
            },
            'progress': 1,
          },
        },
      ],
    });
    final items = LibreChatMessageMapper.outputItems(reply.content);
    check(items[0])
      ..has((it) => it['name'], 'name').equals('lookup')
      ..has((it) => it['arguments'], 'arguments').equals('{"q":"x"}');
    check(items[1]['output']).equals('found');
    check(items[2])
      ..has((it) => it['type'], 'type').equals('code_interpreter')
      ..has((it) => it['code'], 'code').equals('print(2)')
      ..has((it) => it['output'], 'output').equals('2')
      ..has((it) => it['status'], 'status').equals('completed');

    // syncMessages saves a prompt's text only in its content parts, and
    // its uploads only by id.
    final prompt = _message({
      'messageId': 'u1',
      'parentMessageId': kLibreChatRootParentId,
      'conversationId': 'c1',
      'isCreatedByUser': true,
      'content': [
        {
          'type': 'text',
          'text': {'value': 'Summarise the report', 'annotations': []},
        },
      ],
      'files': [
        {'file_id': 'file-abc'},
      ],
    });
    check(
      LibreChatMessageMapper.plainText(prompt),
    ).equals('Summarise the report');
    final payload = LibreChatMessageMapper.messagePayload(prompt);
    check(payload['content']).equals('Summarise the report');
    check(payload['files'] as List).deepEquals([
      {'type': 'file', 'libreChatFileId': 'file-abc'},
    ]);
  });

  group('citations', () {
    test('web and file results of one turn are both kept', () {
      final citations = LibreChatCitations.fromAttachments([
        {
          'type': 'web_search',
          'web_search': {
            'turn': 0,
            'organic': [
              {'title': 'A', 'link': 'https://a.example'},
            ],
          },
        },
        {
          'type': 'file_search',
          'file_search': {
            'sources': [
              {'fileId': 'f1', 'fileName': 'report.pdf'},
            ],
          },
        },
      ]);
      check(
        citations.rewrite('Web\ue202turn0search0, file\ue202turn0file0.'),
      ).equals('Web [1], file [2].');
      check(
        citations.sources.map((source) => source['title']),
      ).deepEquals(['A', 'report.pdf']);
    });

    test('a web reference and a file of one turn stay apart', () {
      final citations = LibreChatCitations.fromAttachments([
        {
          'type': 'web_search',
          'web_search': {
            'turn': 0,
            'references': [
              {'title': 'Linked page', 'link': 'https://r.example'},
            ],
          },
        },
        {
          'type': 'file_search',
          'file_search': {
            'sources': [
              {'fileId': 'f1', 'fileName': 'report.pdf'},
            ],
          },
        },
      ]);
      check(
        citations.rewrite('Pageturn0ref0, fileturn0file0.'),
      ).equals('Page [1], file [2].');
      check(
        citations.sources.map((source) => (source['title'], source['type'])),
      ).deepEquals([('Linked page', 'web'), ('report.pdf', 'file')]);
    });

    test('a reference in a turn of files only cites a file', () {
      final citations = LibreChatCitations.fromAttachments([
        {
          'type': 'file_search',
          'file_search': {
            'sources': [
              {'fileId': 'f1', 'fileName': 'report.pdf'},
            ],
          },
        },
      ]);
      check(citations.rewrite('Fileturn0ref0.')).equals('File [1].');
      check(citations.sources.single['type']).equals('file');
    });

    final citations = LibreChatCitations.fromAttachments([
      {
        'type': 'web_search',
        'web_search': {
          'turn': 0,
          'organic': [
            {'title': 'A', 'link': 'https://a.example'},
            {'title': 'B', 'link': 'https://b.example'},
          ],
          'topStories': [
            {'title': 'N', 'link': 'https://n.example'},
          ],
        },
      },
    ]);

    test('number sources in citation order, written either way', () {
      final text = citations.rewrite(
        'Oneturn0search1. Two\\ue202turn0news0. '
        'turn0search1turn0search0',
      );
      check(text).equals('One [1]. Two [2].  [1] [3]');
      check(
        citations.sources.map((source) => source['url']),
      ).deepEquals([
        'https://b.example',
        'https://n.example',
        'https://a.example',
      ]);
    });

    test('drop anchors to sources that do not exist', () {
      check(
        LibreChatCitations.none().rewrite('Hiturn3search9 there'),
      ).equals('Hi there');
    });
  });
}
