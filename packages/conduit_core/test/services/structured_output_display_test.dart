import 'dart:convert';

import 'package:checks/checks.dart';
import 'package:conduit_core/services/structured_output.dart';
import 'package:conduit_core/services/structured_output_renderer.dart';
import 'package:test/test.dart';

Map<String, dynamic> call(String id, String name) => {
  'type': 'function_call',
  'call_id': id,
  'name': name,
  'arguments': '{"path": "f1"}',
  'status': 'completed',
};

Map<String, dynamic> result(String id, Object payload) => {
  'type': 'function_call_output',
  'call_id': id,
  'output': [
    {'type': 'input_text', 'text': jsonEncode(payload)},
  ],
};

Map<String, dynamic> shown({
  String path = '/api/v1/files/f1/content',
  String source = 'open_webui',
  bool exists = true,
  String contentType = 'application/pdf',
}) => {
  'type': 'file',
  'source': source,
  'exists': exists,
  'displayed': true,
  'path': path,
  'name': 'Report.pdf',
  'content_type': contentType,
};

void main() {
  group('displayedChatFiles', () {
    test('a file the model showed with display_file', () {
      check(
        displayedChatFiles([call('c1', 'display_file'), result('c1', shown())]),
      ).deepEquals([
        {
          'type': 'file',
          'id': 'f1',
          'url': '/api/v1/files/f1/content',
          'name': 'Report.pdf',
          'content_type': 'application/pdf',
        },
      ]);
    });

    test('an image shows as an image, even with its result encoded twice', () {
      final files = displayedChatFiles([
        call('c1', 'display_file'),
        {
          'type': 'function_call_output',
          'call_id': 'c1',
          'output': jsonEncode(jsonEncode(shown(contentType: 'image/png'))),
        },
      ]);
      check(files.single['type']).equals('image');
    });

    test('nothing for other tools, missing files, terminal files or a call '
        'without a result', () {
      check(
        displayedChatFiles([
          call('c1', 'view_file'),
          result('c1', shown()),
          call('c2', 'display_file'),
          result('c2', shown(exists: false)),
          call('c3', 'display_file'),
          // A file the server can serve, kept out by its source alone.
          result('c3', shown(source: 'open_terminal')),
          call('c4', 'display_file'),
        ]),
      ).isEmpty();
    });

    test('each file once', () {
      check(
        displayedChatFiles([
          call('c1', 'display_file'),
          result('c1', shown()),
          call('c2', 'display_file'),
          result('c2', shown()),
        ]),
      ).length.equals(1);
    });
  });

  group('hidden tool calls (Open WebUI 0.13.1)', () {
    // The context the server keeps as tool history for itself, as
    // `hidden_tool_result` writes it, ahead of the reply.
    Map<String, dynamic> hidden(String id, String name, {String? status}) => {
      ...call(id, name),
      'hidden': true,
      'arguments': '{}',
      'status': status ?? 'completed',
    };

    test('memory recall and the skills list are not shown, nor their '
        'results', () {
      final blocks = parseOpenWebUIStructuredOutput([
        hidden('m1', 'recall_memories'),
        result('m1', 'Prefers short answers'),
        hidden('s1', 'list_available_skills'),
        result('s1', '<available_skills></available_skills>'),
        {
          'type': 'message',
          'id': 'msg1',
          'status': 'completed',
          'content': [
            {'type': 'output_text', 'text': 'Hello'},
          ],
        },
      ]);
      check(blocks).length.equals(1);
      check(blocks.single)
          .isA<StructuredOutputTextBlock>()
          .has((b) => b.text, 'text')
          .equals('Hello');
    });

    test('a reply with only hidden context so far shows nothing yet', () {
      check(
        parseOpenWebUIStructuredOutput([
          hidden('k1', 'list_attached_knowledge'),
          result('k1', 'Handbook'),
        ]),
      ).isEmpty();
    });

    test('a hidden call that waits on the user stays visible', () {
      for (final status in ['pending', 'queued', 'requires_approval']) {
        final blocks = parseOpenWebUIStructuredOutput([
          hidden('t1', 'call_tool', status: status),
        ]);
        check(blocks.single)
            .isA<StructuredOutputToolCallBlock>()
            .has((b) => b.status, 'status')
            .equals(status);
      }
    });
  });

  group('tool call labels (Open WebUI 0.13.1)', () {
    test('a call carries the labels the model wrote for it', () {
      final block =
          parseOpenWebUIStructuredOutput([
                {
                  ...call('c1', 'search'),
                  'display_labels': {
                    'running': 'Searching for flights',
                    'completed': 'Searched for flights',
                  },
                },
              ]).single
              as StructuredOutputToolCallBlock;
      check(block.runningLabel).equals('Searching for flights');
      check(block.completedLabel).equals('Searched for flights');
      final rendered = renderStructuredOutputBlocks([block]);
      check(rendered).contains('running_label="Searching for flights"');
      check(rendered).contains('display_label="Searched for flights"');
    });

    test('an older single label is the completed one; none without '
        'either', () {
      final blocks = parseOpenWebUIStructuredOutput([
        {...call('c1', 'search'), 'display_label': 'Searched the web'},
        {
          ...call('c2', 'fetch'),
          'display_labels': {'running': '', 'completed': 7},
        },
      ]).cast<StructuredOutputToolCallBlock>();
      check(blocks.first.runningLabel).isNull();
      check(blocks.first.completedLabel).equals('Searched the web');
      check(blocks.last.runningLabel).isNull();
      check(blocks.last.completedLabel).isNull();
    });

    test('the arguments the server adds for itself are not shown once '
        'complete', () {
      final blocks = parseOpenWebUIStructuredOutput([
        {
          ...call('c1', 'search'),
          'status': 'in_progress',
          'arguments': jsonEncode({
            '__labels__': {'running': 'Searching', 'completed': 'Searched'},
            '__approval__': {'required': false},
            'q': 'cats',
          }),
        },
        {
          ...call('c2', 'fetch'),
          'arguments': {
            '__approval__': {'required': true},
            'url': 'https://example.com',
          },
        },
        // Still streaming: left alone until it parses.
        {
          ...call('c3', 'find'),
          'status': 'in_progress',
          'arguments': '{"__labels__": {"running": "Find',
        },
      ]).cast<StructuredOutputToolCallBlock>().toList();
      check(blocks[0].arguments).equals('{"q":"cats"}');
      check(blocks[1].arguments)
          .isA<Map<Object?, Object?>>()
          .deepEquals({'url': 'https://example.com'});
      check(blocks[2].arguments).equals('{"__labels__": {"running": "Find');
    });
  });

  group('image_generation_call', () {
    test('an image the model made shows as an image', () {
      final blocks = parseOpenWebUIStructuredOutput([
        {
          'type': 'image_generation_call',
          'id': 'ig1',
          'result': 'AAAA',
          'output_format': 'webp',
          'revised_prompt': 'A red [ripe]\napple',
        },
        {
          'type': 'image_generation_call',
          'id': 'ig2',
          'result': 'data:image/jpeg;base64,BBBB',
        },
        {'type': 'image_generation_call', 'id': 'ig3', 'result': ''},
      ]);
      check(
        blocks.whereType<StructuredOutputImageBlock>().map((b) => b.url),
      ).deepEquals([
        'data:image/webp;base64,AAAA',
        'data:image/jpeg;base64,BBBB',
      ]);
      final rendered = renderStructuredOutputBlocks(blocks);
      // Described by the prompt it was made from, on one line, with its
      // brackets kept from ending the description.
      check(rendered).contains(
        r'![A red \[ripe\] apple](data:image/webp;base64,AAAA)',
      );
      check(rendered).contains('![](data:image/jpeg;base64,BBBB)');
    });
  });
}
