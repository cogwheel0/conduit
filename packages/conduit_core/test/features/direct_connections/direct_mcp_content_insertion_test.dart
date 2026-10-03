import 'package:checks/checks.dart';
import 'package:conduit_core/features/direct_connections/controllers/direct_mcp_content_insertion.dart';
import 'package:conduit_core/features/direct_connections/services/direct_mcp_client.dart';
import 'package:test/test.dart';

void main() {
  group('insertContentAtSelection', () {
    test('puts the content at a collapsed caret and moves past it', () {
      final result = insertContentAtSelection(
        'Hello world',
        selectionStart: 5,
        selectionEnd: 5,
        content: ',',
      );

      check(result.text).equals('Hello, world');
      check(result.caret).equals(6);
    });

    test('replaces the selected range', () {
      final result = insertContentAtSelection(
        'Hello world',
        selectionStart: 6,
        selectionEnd: 11,
        content: 'MCP',
      );

      check(result.text).equals('Hello MCP');
      check(result.caret).equals(9);
    });

    test('appends when the field has no valid selection', () {
      for (final selection in [(null, null), (-1, -1)]) {
        final result = insertContentAtSelection(
          'abc',
          selectionStart: selection.$1,
          selectionEnd: selection.$2,
          content: 'X',
        );
        check(because: '$selection', result.text).equals('abcX');
        check(result.caret).equals(4);
      }
    });

    test('clamps offsets past the end of the text', () {
      final result = insertContentAtSelection(
        'abc',
        selectionStart: 9,
        selectionEnd: 12,
        content: 'X',
      );

      check(result.text).equals('abcX');
      check(result.caret).equals(4);
    });

    test('never lets the end fall before the start', () {
      final result = insertContentAtSelection(
        'abcdef',
        selectionStart: 4,
        selectionEnd: 2,
        content: 'X',
      );

      check(result.text).equals('abcdXef');
    });

    test('handles an empty field', () {
      final result = insertContentAtSelection(
        '',
        selectionStart: 0,
        selectionEnd: 0,
        content: 'hi',
      );

      check(result.text).equals('hi');
      check(result.caret).equals(2);
    });
  });

  group('directMcpInsertionFitsComposer', () {
    test('counts the whole text after the insertion, in bytes', () {
      final existing = 'a' * (kDirectMcpMaxInsertionBytes - 4);

      check(
        directMcpInsertionFitsComposer(
          existing,
          selectionStart: existing.length,
          selectionEnd: existing.length,
          content: 'abcd',
        ),
      ).isTrue();
      check(
        directMcpInsertionFitsComposer(
          existing,
          selectionStart: existing.length,
          selectionEnd: existing.length,
          content: 'abcde',
        ),
      ).isFalse();
    });

    test('a replaced selection frees its space', () {
      final existing = 'a' * kDirectMcpMaxInsertionBytes;

      check(
        directMcpInsertionFitsComposer(
          existing,
          selectionStart: 0,
          selectionEnd: 10,
          content: 'b' * 10,
        ),
      ).isTrue();
    });

    test('multi-byte characters count their UTF-8 bytes', () {
      check(
        directMcpInsertionFitsComposer(
          '',
          selectionStart: 0,
          selectionEnd: 0,
          content: 'あ' * (kDirectMcpMaxInsertionBytes ~/ 3 + 1),
        ),
      ).isFalse();
    });
  });
}
