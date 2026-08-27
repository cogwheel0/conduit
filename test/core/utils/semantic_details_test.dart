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

    test('drops an uppercase opener', () {
      // Tag and attribute names are case-insensitive in HTML, and this is
      // model output, so the wrapper does not have to arrive lowercase.
      final result = dropUnterminatedSemanticDetails(
        'Checking that now. '
        '<DETAILS TYPE="reasoning" DONE="false"><SUMMARY>Thinking…</SUMMARY>'
        '> internal notes',
      );

      check(result).equals('Checking that now.');
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

  group('stripDetailsForSpeech', () {
    test('removes a complete semantic block', () {
      final result = stripDetailsForSpeech(
        'Answer body. '
        '<details type="reasoning" done="true"><summary>Thought</summary>'
        'notes</details>'
        'More answer.',
      );

      check(result).equals('Answer body. More answer.');
    });

    test('removes a nested block whole', () {
      // A non-greedy pattern stops at the inner close tag and leaves the outer
      // block's tail behind, which is content the reader never meant to hear.
      final result = stripDetailsForSpeech(
        '<details type="reasoning" done="true">'
        '<details><summary>inner</summary>inner body</details>'
        'outer body</details>'
        'The answer.',
      );

      check(result).equals('The answer.');
    });

    test('withholds everything after an open semantic wrapper', () {
      final result = stripDetailsForSpeech(
        'Checking that now. '
        '<details type="reasoning" done="false"><summary>Thinking</summary>'
        '> internal notes',
      );

      check(result).equals('Checking that now.');
    });

    test('leaves an ordinary open details alone', () {
      // Not a wrapper, so silencing the rest of the answer would be wrong.
      const content = 'Answer. <details><summary>Extra</summary>notes';

      check(stripDetailsForSpeech(content)).equals(content);
    });

    test('withholds an open wrapper nested in an ordinary details', () {
      // The ordinary opener stays, but the reasoning body inside it is still
      // a reasoning body.
      final result = stripDetailsForSpeech(
        'Answer. <details><summary>Extra</summary>'
        '<details type="reasoning" done="false">internal notes',
      );

      check(result).equals('Answer. <details><summary>Extra</summary>');
    });

    test('strips a closed wrapper nested in an ordinary details', () {
      final result = stripDetailsForSpeech(
        'Answer. <details><summary>Extra</summary>'
        '<details type="reasoning" done="true">notes</details>'
        'visible tail',
      );

      check(result)
          .equals('Answer. <details><summary>Extra</summary>visible tail');
    });

    test('leaves content without details untouched', () {
      const content = 'Plain answer with no wrappers at all.';

      check(stripDetailsForSpeech(content)).equals(content);
    });

    test('handles an uppercase wrapper', () {
      final result = stripDetailsForSpeech(
        'Answer. <DETAILS TYPE="reasoning" DONE="true">notes</DETAILS> Rest.',
      );

      check(result).equals('Answer.  Rest.');
    });
  });
}
