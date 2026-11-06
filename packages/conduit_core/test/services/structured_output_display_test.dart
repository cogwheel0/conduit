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
