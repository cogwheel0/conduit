import 'package:checks/checks.dart';
import 'package:conduit/core/utils/semantic_details.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('dropUnterminatedSemanticDetails', () {
    test('drops the tail from an unterminated reasoning opener', () {
      final result = dropUnterminatedSemanticDetails(
        'Checking that now. '
        '<details type="reasoning" done="false"><summary>Thinking…</summary>'
        '> internal notes',
      );

      check(result).equals('Checking that now.');
    });

    test('drops the tail from an unterminated tool call opener', () {
      final result = dropUnterminatedSemanticDetails(
        'One moment. '
        '<details type="tool_calls" done="false" name="get_entities">'
        '{"entities": []}',
      );

      check(result).equals('One moment.');
    });

    test('leaves content without semantic details untouched', () {
      const content = 'Plain answer with no wrappers at all.';

      check(dropUnterminatedSemanticDetails(content)).equals(content);
    });

    test('leaves a non-semantic details opener untouched', () {
      const content = 'Answer. <details><summary>Extra</summary>notes';

      check(dropUnterminatedSemanticDetails(content)).equals(content);
    });

    test('drops only the unterminated opener after complete blocks are '
        'stripped', () {
      const content =
          'Answer body. '
          '<details type="reasoning" done="true"><summary>Thought</summary>'
          'first pass</details>'
          'More answer. '
          '<details type="reasoning" done="false"><summary>Thinking…</summary>'
          'second pass';

      final result = dropUnterminatedSemanticDetails(
        stripRenderedSemanticDetails(content),
      );

      check(result).equals('Answer body. More answer.');
    });
  });
}
