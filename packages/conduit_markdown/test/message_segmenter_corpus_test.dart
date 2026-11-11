@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:conduit_markdown/conduit_markdown.dart';
import 'package:test/test.dart';

import 'corpus/assistant_message_cases.dart';

/// The block goldens for [assistantMessageCases]. The mobile app's
/// equivalence test reads the same file, and later the Rust protocol crate
/// can use it as a cross-language fixture.
final _goldenFile = File('test/corpus/assistant_message_blocks.json');

List<Map<String, Object?>> _render() => [
  for (final testCase in assistantMessageCases)
    {
      'name': testCase.name,
      'streaming': testCase.streaming,
      'content': testCase.content,
      'blocks': [
        for (final block in segmentAssistantMessage(
          testCase.content,
          streaming: testCase.streaming,
        ))
          block.toJson(),
      ],
    },
];

void main() {
  if (Platform.environment['UPDATE_GOLDENS'] == '1') {
    test('writes the corpus goldens', () {
      _goldenFile.writeAsStringSync(
        '${const JsonEncoder.withIndent('  ').convert(_render())}\n',
      );
    });
    return;
  }

  final golden = (jsonDecode(_goldenFile.readAsStringSync()) as List)
      .cast<Map<String, Object?>>();

  test('the golden file lists every case, in order, with its input', () {
    expect(
      [for (final entry in golden) (entry['name'], entry['content'])],
      [for (final c in assistantMessageCases) (c.name, c.content)],
    );
  });

  final rendered = _render();
  for (var index = 0; index < assistantMessageCases.length; index++) {
    final testCase = assistantMessageCases[index];
    test('segments: ${testCase.name}', () {
      expect(rendered[index], golden[index]);
    });
  }

  test('segmenting is stable: same input, equal blocks', () {
    for (final testCase in assistantMessageCases) {
      expect(
        segmentAssistantMessage(
          testCase.content,
          streaming: testCase.streaming,
        ),
        segmentAssistantMessage(
          testCase.content,
          streaming: testCase.streaming,
        ),
      );
    }
  });
}
