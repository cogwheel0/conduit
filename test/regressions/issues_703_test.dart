// Regression coverage for issue #703: full-chat saves persisted Conduit's
// display-rendered `<details type="tool_calls">` HTML into server-side
// content (up to 99% of stored chars; broke shares/exports; inflated model
// context ~13x on continuations). The persisted content must be the plain
// text projection; the rendered wrappers are local display state only.
import 'package:checks/checks.dart';
import 'package:conduit/core/database/mappers/chat_blob_mapper.dart';
import 'package:conduit/core/utils/semantic_details.dart';
import 'package:flutter_test/flutter_test.dart';

/// The shape the issue measured on a polluted chat: an answer with full
/// tool-call wrappers (escaped JSON arguments/results) embedded in content.
const _pollutedAssistantContent = '''<details type="tool_calls" done="true" id="call_abc123" name="mcp_tool_call" arguments="&quot;{&quot;query&quot;: &quot;open webui tools&quot;, &quot;limit&quot;: 10}&quot;" result="[{&quot;type&quot;:&quot;input_text&quot;,&quot;text&quot;:&quot;scraped page body&quot;}]">
<summary>Tool Executed</summary>
</details>

This is the actual answer text that should survive the save.''';

void main() {
  group('issue 703 - projectContentForServerPersistence', () {
    test('leaves plain text (including markdown) unchanged', () {
      const content =
          'Plain answer\n\n```dart\nprint("<details type=tool_calls>");\n```';
      check(projectContentForServerPersistence(content)).equals(content);
    });

    test('leaves ordinary <details> without a semantic type unchanged', () {
      const content =
          '<details><summary>Model output block</summary>body</details>';
      check(projectContentForServerPersistence(content)).equals(content);
    });

    test('projects a polluted tool-call message to its plain answer', () {
      check(
        projectContentForServerPersistence(_pollutedAssistantContent),
      ).equals('This is the actual answer text that should survive the save.');
    });

    test('projects multiple tool-call blocks (worst-case message shape)', () {
      final content = [
        '<details type="tool_calls" done="true" id="call_1" name="search" arguments="&quot;{&quot;q&quot;:&quot;a&quot;}&quot;" result="&quot;[10KB result 1]&quot;">'
            '<summary>Tool Executed</summary>\n</details>',
        '<details type="tool_calls" done="true" id="call_2" name="fetch" arguments="&quot;{&quot;url&quot;:&quot;https://x&quot;}&quot;" result="&quot;[15KB result 2]&quot;">'
            '<summary>Tool Executed</summary>\n</details>',
        'Final synthesized answer.',
      ].join('\n\n');
      check(projectContentForServerPersistence(content))
          .equals('Final synthesized answer.');
    });

    test('projects reasoning and code_interpreter wrappers too', () {
      const content = '''<details type="reasoning" done="true" duration="12">
<summary>Thought for 12 seconds</summary>
> inner thought
</details>

<details type="code_interpreter" done="true">
<summary>Analyzed</summary>
body
</details>

The answer.''';
      check(projectContentForServerPersistence(content)).equals('The answer.');
    });

    test('a message that is only tool-call markup projects to empty', () {
      const content =
          '''<details type="tool_calls" done="true" id="call_1" name="t">
<summary>Tool Executed</summary>
</details>''';
      check(projectContentForServerPersistence(content)).equals('');
    });

    test('keeps answer text around the block with paragraph spacing', () {
      const content = '''Intro paragraph.

<details type="tool_calls" done="true" id="call_1" name="t">
<summary>Tool Executed</summary>
</details>

Closing paragraph.''';
      check(projectContentForServerPersistence(content))
          .equals('Intro paragraph.\n\nClosing paragraph.');
    });

    test('withholds a trailing unterminated wrapper (partial stream tail)', () {
      const content =
          'Partial answer.\n\n<details type="tool_calls" done="false" id="c1" name="t">';
      check(projectContentForServerPersistence(content))
          .equals('Partial answer.');
    });

    test('upper-case semantic wrappers are projected as well', () {
      const content =
          'Answer.\n\n<DETAILS TYPE="TOOL_CALLS" DONE="true"><SUMMARY>x</SUMMARY>\n</DETAILS>';
      check(projectContentForServerPersistence(content)).equals('Answer.');
    });
  });

  group('issue 703 - ChatBlobMapper.projectChatBlobForServerPush', () {
    Map<String, dynamic> pollutedBlob() => {
      'title': 'Polluted chat',
      'models': ['llama3'],
      'history': {
        'messages': <String, dynamic>{
          'm-user': <String, dynamic>{
            'id': 'm-user',
            'parentId': null,
            'role': 'user',
            'content': 'run the tool',
          },
          'm-asst': <String, dynamic>{
            'id': 'm-asst',
            'parentId': 'm-user',
            'role': 'assistant',
            'content': _pollutedAssistantContent,
            'model': 'llama3',
          },
        },
        'currentId': 'm-asst',
      },
      'messages': <Map<String, dynamic>>[
        <String, dynamic>{
          'id': 'm-user',
          'parentId': null,
          'role': 'user',
          'content': 'run the tool',
        },
        <String, dynamic>{
          'id': 'm-asst',
          'parentId': 'm-user',
          'role': 'assistant',
          'content': _pollutedAssistantContent,
        },
      ],
    };

    const plainAnswer =
        'This is the actual answer text that should survive the save.';

    test('projects history.messages and the linear messages list', () {
      final projected = ChatBlobMapper.projectChatBlobForServerPush(
        pollutedBlob(),
      );

      final history = (projected['history'] as Map)['messages'] as Map;
      check((history['m-asst'] as Map)['content']).equals(plainAnswer);
      check((history['m-user'] as Map)['content']).equals('run the tool');
      // Envelope and metadata survive untouched.
      check(projected['title']).equals('Polluted chat');
      check(projected['models'] as List).deepEquals(['llama3']);
      check((projected['history'] as Map)['currentId']).equals('m-asst');

      final linear = projected['messages'] as List;
      check((linear[0] as Map)['content']).equals('run the tool');
      check((linear[1] as Map)['content']).equals(plainAnswer);
    });

    test('projects nested versions of a message', () {
      final blob = pollutedBlob();
      final historyMessages = (blob['history'] as Map)['messages'] as Map;
      (historyMessages['m-asst'] as Map<String, dynamic>)['versions'] = [
        <String, dynamic>{
          'id': 'm-asst-v1',
          'parentId': 'm-user',
          'role': 'assistant',
          'content': _pollutedAssistantContent,
        },
      ];

      final projected = ChatBlobMapper.projectChatBlobForServerPush(blob);
      final asst =
          ((projected['history'] as Map)['messages'] as Map)['m-asst'] as Map;
      final versions = asst['versions'] as List;
      check((versions[0] as Map)['content']).equals(plainAnswer);
    });

    test('projects string elements of list (multimodal) content', () {
      final blob = pollutedBlob();
      final historyMessages = (blob['history'] as Map)['messages'] as Map;
      (historyMessages['m-asst'] as Map<String, dynamic>)['content'] = [
        _pollutedAssistantContent,
        <String, dynamic>{'type': 'image', 'url': 'https://x/y.png'},
      ];

      final projected = ChatBlobMapper.projectChatBlobForServerPush(blob);
      final asst =
          ((projected['history'] as Map)['messages'] as Map)['m-asst'] as Map;
      final content = asst['content'] as List;
      check(content[0]).equals(plainAnswer);
      check(content[1] as Map<String, dynamic>)
          .deepEquals({'type': 'image', 'url': 'https://x/y.png'});
    });

    test('never mutates the input blob or its payload maps', () {
      final blob = pollutedBlob();
      final historyMessages = (blob['history'] as Map)['messages'] as Map;
      final originalAsst = (historyMessages['m-asst'] as Map)
          .cast<String, dynamic>();
      final originalContent = originalAsst['content'];
      final originalLinear = (blob['messages'] as List)[1];

      final projected = ChatBlobMapper.projectChatBlobForServerPush(blob);

      // The caller's maps are untouched (rowsToBlob reuses them by reference).
      check(originalAsst['content']).equals(originalContent);
      check((originalLinear as Map)['content'])
          .equals(_pollutedAssistantContent);
      // ...while the projected copy carries the plain text.
      final projectedAsst =
          ((projected['history'] as Map)['messages'] as Map)['m-asst'] as Map;
      expect(identical(projectedAsst, originalAsst), isFalse);
      check(projectedAsst['content']).equals(plainAnswer);
    });

    test('clean blobs pass through value-equal with no semantic change', () {
      final blob = {
        'title': 'Clean',
        'history': {
          'messages': {
            'm1': {'id': 'm1', 'role': 'user', 'content': 'no wrappers here'},
          },
          'currentId': 'm1',
        },
      };
      final projected = ChatBlobMapper.projectChatBlobForServerPush(blob);
      check(projected).deepEquals(blob);
    });

    test('non-map history entries pass through verbatim', () {
      final blob = {
        'history': {
          'messages': {
            'ghost': null,
            'm1': {
              'id': 'm1',
              'role': 'user',
              'content': _pollutedAssistantContent,
            },
          },
        },
      };
      final projected = ChatBlobMapper.projectChatBlobForServerPush(blob);
      final messages = (projected['history'] as Map)['messages'] as Map;
      check(messages['ghost']).isNull();
      check((messages['m1'] as Map)['content']).equals(plainAnswer);
    });
  });
}
